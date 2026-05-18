"""Audio capture + whisper.cpp streaming transcription.

Runs in a background thread. Captures audio from the default input device,
buffers it, and feeds rolling windows to whisper.cpp. Finalized sentences
are emitted to a callback so the rest of the system can react.

LOCAL PATCHES (kfareed's Pi, 2026-05-18):
  - clamp seg_end_s to actual buffer duration (whisper pads to 30s)
  - dropped the "skip last 500ms" filter (broken given whisper's padded ts)
  - added text-based dedup so rolling-window emits don't repeat
  - filter initial_prompt regurgitation hallucinations
Revert with: git checkout app/transcription.py
"""
from __future__ import annotations

import logging
import queue
import re
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


def _norm(s: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace — for dedup matching."""
    return " ".join(re.sub(r"[^a-z0-9 ]", " ", s.lower()).split())


def _split_with_mapping(text: str) -> tuple[list[str], list[str], list[int]]:
    """Return (orig_words, norm_words, orig_to_norm_end_count).

    Normalization can split one orig word (e.g., "don't") into multiple norm
    words ("don", "t"). orig_to_norm_end_count[i] is the cumulative count of
    norm words produced by orig_words[:i+1], so we can map a norm-index back
    to an orig-index after dedup.
    """
    orig_words = text.split()
    norm_words: list[str] = []
    orig_to_norm_end: list[int] = []
    for ow in orig_words:
        for nw in _norm(ow).split():
            norm_words.append(nw)
        orig_to_norm_end.append(len(norm_words))
    return orig_words, norm_words, orig_to_norm_end


# Don't emit suffixes shorter than this many words during streaming — wait
# for the next rolling-window pass to combine them. During the final drain
# pass (after the user presses stop) we relax this to 1 since there's no
# next pass to wait for.
MIN_NEW_SUFFIX_WORDS = 4
MIN_NEW_SUFFIX_WORDS_FINALIZING = 1


class WhisperTranscriber:
    """Wraps pywhispercpp with a rolling-window streaming loop."""

    # Hallucinated phrases we never emit, regardless of context.
    _HALLUCINATIONS = {
        "you", "thank you", "thanks for watching", "thanks", ".",
    }
    _HALLUCINATION_SUBSTRINGS = (
        "the teacher is speaking",
        "classroom lecture",
        "subtitles by",
        "subscribe to my channel",
    )

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
        self._finalize_req = threading.Event()
        self._finalize_done = threading.Event()
        self._finalizing = False
        self._thread: threading.Thread | None = None
        self._capture = AudioCapture(sample_rate=sample_rate)

        # Text-based dedup state. Holds normalized words already emitted; we
        # cap it to the last ~200 words to keep matching cheap on long lectures.
        self._emitted_norm_words: list[str] = []

        self._session_start: datetime | None = None
        self._whisper = self._load_model()
        self._extra_kwargs: dict | None = None

    def _load_model(self):
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
        self._emitted_norm_words = []
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

    def finalize(self, timeout: float = 15.0) -> None:
        """Stop audio capture immediately so silence stops flooding the
        buffer, then run one final transcription pass on the frozen audio
        before fully stopping the loop. Blocks until that final pass emits
        (or times out). Caller MUST invoke this BEFORE marking the class
        ended on the server, so trailing captions are still attributed
        to the active class.
        """
        self._capture.stop()
        self._finalize_req.set()
        self._finalize_done.wait(timeout=timeout)
        self.stop()

    def _loop(self) -> None:
        last_run = time.monotonic()
        step_s = self.step_ms / 1000.0
        while not self._stop.is_set():
            chunk = self._capture.read(timeout=0.5)
            if chunk is not None:
                self._buffer = np.concatenate([self._buffer, chunk])
                if len(self._buffer) > self._max_buffer_samples:
                    self._buffer = self._buffer[-self._max_buffer_samples:]

            # If finalize was requested, drain the buffer once with a relaxed
            # short-suffix threshold so we don't lose trailing 1-3 word
            # fragments. Then signal done and exit.
            if self._finalize_req.is_set():
                self._finalizing = True
                if len(self._buffer) >= self.sample_rate:
                    try:
                        segments = self._transcribe(self._buffer)
                        self._emit(segments)
                    except Exception as e:  # noqa: BLE001
                        log.exception("whisper finalize error: %s", e)
                self._finalize_done.set()
                return

            now = time.monotonic()
            if now - last_run < step_s:
                continue
            last_run = now

            if len(self._buffer) < self.sample_rate:
                continue

            try:
                segments = self._transcribe(self._buffer)
            except Exception as e:  # noqa: BLE001
                log.exception("whisper error: %s", e)
                continue

            self._emit(segments)

    def _transcribe(self, audio):
        if self._extra_kwargs is None:
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
                    pass
            self._extra_kwargs = candidates
            log.info("whisper kwargs supported: %s", list(self._extra_kwargs.keys()))
        return self._whisper.transcribe(audio, language="en", **self._extra_kwargs)

    def _is_hallucination(self, text: str) -> bool:
        low = text.lower().strip(".!? ")
        if low in self._HALLUCINATIONS:
            return True
        for sub in self._HALLUCINATION_SUBSTRINGS:
            if sub in low:
                return True
        return False

    def _new_suffix(self, text: str) -> str:
        """Return the portion of `text` not already covered by emitted history.

        Strategy: find the longest suffix of recent emitted history that also
        appears as a contiguous substring of the new text, then emit only the
        portion of the new text that comes AFTER that substring.

        This handles two whisper-streaming patterns:
          - Rolling window: new starts mid-history → suffix-of-history matches
            the prefix of new.
          - Revision: whisper rewrites its earlier prefix/tail when more audio
            arrives (e.g., "And I likely heard this would be" → "And all
            likelihood this will be"). The unrevised middle of the sentence
            still matches the recent history's suffix, so we still find the
            right cut point.
        """
        orig_words, norm_new_words, orig_to_norm_end = _split_with_mapping(text)
        if not norm_new_words:
            return ""

        first_pass_min = MIN_NEW_SUFFIX_WORDS_FINALIZING if self._finalizing else MIN_NEW_SUFFIX_WORDS
        if not self._emitted_norm_words:
            if len(orig_words) < first_pass_min:
                return ""
            return text.strip()

        history_words = self._emitted_norm_words[-100:]
        new_str = " " + " ".join(norm_new_words) + " "

        # Find longest k such that history_words[-k:] appears as a contiguous
        # word sequence inside new_str. Require min overlap to avoid
        # coincidental single-word matches.
        max_k = min(len(history_words), len(norm_new_words), 50)
        overlap_end_norm_idx = -1
        for k in range(max_k, 2, -1):  # require >=3-word overlap
            candidate = " " + " ".join(history_words[-k:]) + " "
            idx = new_str.rfind(candidate)  # rightmost match
            if idx < 0:
                continue
            # The match in new_str ends just before the trailing space at
            # position idx + len(candidate) - 1. Count words up to there.
            chars_before = new_str[: idx + len(candidate) - 1]
            overlap_end_norm_idx = len(chars_before.split())
            break

        if overlap_end_norm_idx < 0:
            # No useful suffix-of-history match. Check the catch-all: is the
            # entire new text already contained somewhere in history?
            history_str = " " + " ".join(history_words) + " "
            if " " + " ".join(norm_new_words) + " " in history_str:
                return ""
            if len(orig_words) < first_pass_min:
                return ""
            return text.strip()

        # Map the norm-word index back to the orig-word index after the match.
        orig_start_idx = len(orig_words)
        for i, n in enumerate(orig_to_norm_end):
            if n >= overlap_end_norm_idx:
                orig_start_idx = i + 1
                break

        remaining = orig_words[orig_start_idx:]
        min_words = MIN_NEW_SUFFIX_WORDS_FINALIZING if self._finalizing else MIN_NEW_SUFFIX_WORDS
        if len(remaining) < min_words:
            return ""
        return " ".join(remaining).strip()

    def _record_emitted(self, text: str) -> None:
        self._emitted_norm_words.extend(_norm(text).split())
        # Cap history length to keep matching cheap.
        if len(self._emitted_norm_words) > 400:
            self._emitted_norm_words = self._emitted_norm_words[-200:]

    def _emit(self, segments) -> None:
        buffer_duration_s = len(self._buffer) / self.sample_rate
        assert self._session_start is not None
        now = datetime.now(timezone.utc)
        buffer_end_s = (now - self._session_start).total_seconds()
        buffer_start_s = buffer_end_s - buffer_duration_s

        for seg in segments:
            log.info("seg t0=%.2f t1=%.2f text=%r", seg.t0 / 100, seg.t1 / 100, seg.text)
            seg_start_s = buffer_start_s + (seg.t0 / 100.0)
            seg_end_s = buffer_start_s + min(seg.t1 / 100.0, buffer_duration_s)
            text = seg.text.strip()
            if not text:
                continue
            if self._is_hallucination(text):
                continue

            new_text = self._new_suffix(text)
            if not new_text:
                continue
            # Re-check hallucination on the trimmed suffix — sometimes the
            # only "new" part is a tail-end "thank you" hallucination.
            if self._is_hallucination(new_text):
                continue

            started_at = self._session_start + timedelta(seconds=seg_start_s)
            ended_at = self._session_start + timedelta(seconds=seg_end_s)
            self.on_caption(new_text, started_at, ended_at)
            self._record_emitted(new_text)
