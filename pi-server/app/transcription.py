"""Audio capture + whisper.cpp streaming transcription.

Runs in a background thread. Captures audio from the default input device,
buffers it, and feeds rolling windows to whisper.cpp. Finalized sentences
are emitted to a callback so the rest of the system can react.

The "finalized sentence" boundary is determined by Whisper's segment output —
each segment whose end timestamp is older than `step_ms` ago is treated as
finalized and will not be re-emitted.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from collections.abc import Callable
from datetime import datetime, timedelta, timezone

import numpy as np
import sounddevice as sd

from .config import settings

log = logging.getLogger(__name__)


class AudioCapture:
    """Pulls audio from the default input device into a thread-safe queue."""

    def __init__(self, sample_rate: int = 16000, channels: int = 1, block_ms: int = 1000):
        self.sample_rate = sample_rate
        self.channels = channels
        self.block_size = int(sample_rate * block_ms / 1000)
        self._q: queue.Queue[np.ndarray] = queue.Queue()
        self._stream: sd.InputStream | None = None

    def _callback(self, indata, frames, time_info, status):
        if status:
            log.warning("audio status: %s", status)
        self._q.put(indata[:, 0].copy())

    def start(self) -> None:
        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=self.channels,
            blocksize=self.block_size,
            callback=self._callback,
            dtype="float32",
        )
        self._stream.start()
        log.info("audio capture started (sr=%d, block=%d)", self.sample_rate, self.block_size)

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def read(self, timeout: float | None = None) -> np.ndarray | None:
        try:
            return self._q.get(timeout=timeout)
        except queue.Empty:
            return None


class WhisperTranscriber:
    """Wraps pywhispercpp with a rolling-window streaming loop.

    Holds the most recent `length_ms` of audio. Every `step_ms`, runs
    transcription on the buffer and emits finalized segments via the callback.

    A segment is "finalized" once a newer segment exists after it (i.e. the model
    has moved past it) AND its end is older than `step_ms` ago.
    """

    def __init__(
        self,
        on_caption: Callable[[str, datetime, datetime], None],
        step_ms: int = settings.whisper_step_ms,
        length_ms: int = settings.whisper_length_ms,
        threads: int = settings.whisper_threads,
        sample_rate: int = settings.sample_rate,
    ):
        self.on_caption = on_caption
        self.step_ms = step_ms
        self.length_ms = length_ms
        self.threads = threads
        self.sample_rate = sample_rate

        self._buffer = np.zeros(0, dtype=np.float32)
        self._max_buffer_samples = int(length_ms * sample_rate / 1000)

        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._capture = AudioCapture(sample_rate=sample_rate)

        # Cursor: timestamp (in seconds since session start) before which all
        # text has been emitted. Subsequent transcripts are clipped to this.
        self._emitted_until_s = 0.0
        self._session_start: datetime | None = None

        self._whisper = self._load_model()
        # Probed once on the first transcription call. Different pywhispercpp
        # versions accept different kwargs; we detect what works rather than
        # crashing if the build doesn't plumb e.g. initial_prompt.
        self._extra_kwargs: dict | None = None

    def _load_model(self):
        # Lazy import so the rest of the app can be unit-tested without the
        # whisper.cpp wheel being installable on the dev machine yet.
        from pywhispercpp.model import Model

        model_path = settings.models_dir / settings.whisper_model
        if not model_path.exists():
            raise FileNotFoundError(
                f"Whisper model not found at {model_path}. "
                f"Run scripts/setup-pi.sh to download."
            )
        log.info("loading whisper model from %s", model_path)
        return Model(str(model_path), n_threads=self.threads, print_realtime=False, print_progress=False)

    def start(self) -> None:
        if self._thread is not None:
            return
        self._session_start = datetime.now(timezone.utc)
        self._capture.start()
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="whisper-loop", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._capture.stop()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None

    def _loop(self) -> None:
        last_run = time.monotonic()
        step_s = self.step_ms / 1000.0
        while not self._stop.is_set():
            chunk = self._capture.read(timeout=0.5)
            if chunk is not None:
                self._buffer = np.concatenate([self._buffer, chunk])
                if len(self._buffer) > self._max_buffer_samples:
                    self._buffer = self._buffer[-self._max_buffer_samples:]

            now = time.monotonic()
            if now - last_run < step_s:
                continue
            last_run = now

            if len(self._buffer) < self.sample_rate:  # need at least 1s
                continue

            try:
                segments = self._transcribe(self._buffer)
            except Exception as e:  # noqa: BLE001 - whisper failures shouldn't kill the loop
                log.exception("whisper error: %s", e)
                continue

            self._emit(segments)

    def _transcribe(self, audio):
        """Wrap whisper.transcribe with the best kwargs the build accepts."""
        if self._extra_kwargs is None:
            # First call: probe what kwargs work. Bias toward classroom
            # vocabulary and a tighter no-speech threshold to suppress
            # tiny.en's "you / thank you" hallucinations on silence.
            candidates = {
                "initial_prompt": (
                    "Classroom lecture. The teacher is speaking. "
                    "Topics may include math, biology, physics, history."
                ),
                "no_speech_thold": 0.6,
                "suppress_blank": True,
            }
            for k, v in list(candidates.items()):
                try:
                    self._whisper.transcribe(audio, language="en", **{k: v})
                except TypeError:
                    candidates.pop(k)
                except Exception:
                    # Non-signature error — keep the kwarg, real call will retry.
                    pass
            self._extra_kwargs = candidates
            log.info("whisper kwargs supported: %s", list(self._extra_kwargs.keys()))
        return self._whisper.transcribe(audio, language="en", **self._extra_kwargs)

    def _emit(self, segments) -> None:
        # Figure out the audio time of the start of the buffer
        buffer_duration_s = len(self._buffer) / self.sample_rate
        # Time elapsed since session_start at end of buffer ≈ now
        assert self._session_start is not None
        now = datetime.now(timezone.utc)
        buffer_end_s = (now - self._session_start).total_seconds()
        buffer_start_s = buffer_end_s - buffer_duration_s

        for seg in segments:
            # pywhispercpp segments expose .t0, .t1 (in centiseconds) and .text
            seg_start_s = buffer_start_s + (seg.t0 / 100.0)
            seg_end_s = buffer_start_s + (seg.t1 / 100.0)
            text = seg.text.strip()
            if not text:
                continue
            if seg_start_s < self._emitted_until_s:
                continue
            # Don't emit segments that touch the very last 500ms of the
            # buffer — those are most likely still being transcribed. With
            # a 30s window this only delays a single segment by one step,
            # not a meaningful share of the audio.
            if buffer_end_s - seg_end_s < 0.5:
                continue
            # Filter Whisper's classic empty-audio hallucinations.
            low = text.lower().strip(".!? ")
            if low in {"you", "thank you", "thanks for watching", "thanks", "."}:
                continue
            assert self._session_start is not None
            started_at = self._session_start + timedelta(seconds=seg_start_s)
            ended_at = self._session_start + timedelta(seconds=seg_end_s)
            self.on_caption(text, started_at, ended_at)
            self._emitted_until_s = seg_end_s
