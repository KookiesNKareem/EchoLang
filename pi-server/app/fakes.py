"""Fake transcriber + translator for laptop dev and CI smoke tests.

Lets you exercise the full PWA, SSE streaming, study pack, and bundle flow
without whisper.cpp, llama.cpp, or any model files installed.

Enable with `LL_FAKE=1` (or `fake: true` in .env).
"""
from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from datetime import datetime, timedelta, timezone

from .config import settings

log = logging.getLogger(__name__)


# A scripted "lecture" — short enough for testing, varied enough for the demo.
SCRIPTED_LECTURE = [
    "Good morning everyone, today we're going to talk about photosynthesis.",
    "Photosynthesis is the process plants use to make their own food.",
    "Plants take in carbon dioxide from the air through tiny holes in their leaves called stomata.",
    "They also pull water up from the soil through their roots.",
    "Inside the leaves are tiny green structures called chloroplasts.",
    "Chloroplasts contain a green pigment called chlorophyll.",
    "Chlorophyll captures energy from sunlight.",
    "Using that energy, the plant combines water and carbon dioxide into sugar.",
    "The sugar feeds the plant and lets it grow.",
    "As a side effect, the plant releases oxygen — which is what we breathe.",
    "So in a way, every breath you take comes from a plant somewhere.",
    "Without photosynthesis, there would be no animal life on Earth.",
    "Are there any questions about how the chlorophyll captures light?",
    "Tomorrow we'll look at how scientists measured the rate of photosynthesis for the first time.",
]


class FakeTranscriber:
    """Emits scripted captions on a timer to simulate a teacher speaking."""

    def __init__(self, on_caption: Callable[[str, datetime, datetime], None]):
        self.on_caption = on_caption
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="fake-transcriber", daemon=True)
        self._thread.start()
        log.info("FakeTranscriber started — emitting %d scripted captions every %.1fs",
                 len(SCRIPTED_LECTURE), settings.fake_caption_interval_s)

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    def _loop(self) -> None:
        i = 0
        while not self._stop.is_set():
            line = SCRIPTED_LECTURE[i % len(SCRIPTED_LECTURE)]
            now = datetime.now(timezone.utc)
            started = now - timedelta(seconds=settings.fake_caption_interval_s)
            self.on_caption(line, started, now)
            i += 1
            self._stop.wait(settings.fake_caption_interval_s)


class FakeTranslator:
    """Drop-in for GemmaTranslator. Returns the original text with a language tag.

    For demo realism we add visibly different transformations per language so
    you can tell at a glance the per-language streams are working.
    """

    _PER_LANG_PREFIX = {
        "ar": "[AR] ",
        "uk": "[UK] ",
        "es": "[ES] ",
        "zh": "[ZH] ",
        "fr": "[FR] ",
        "ps": "[PS] ",
        "fa": "[FA] ",
    }

    def translate(self, text: str, target_lang: str, max_tokens: int = 256) -> str:
        # Tiny artificial delay so the SSE stream feels real
        time.sleep(0.15)
        if target_lang == "en":
            return text
        prefix = self._PER_LANG_PREFIX.get(target_lang, f"[{target_lang.upper()}] ")
        return prefix + text

    def generate(self, prompt: str, max_tokens: int = 512, temperature: float = 0.3) -> str:
        # Hand back valid JSON so the study pack pipeline doesn't blow up.
        return (
            '{"summary": "This was a class about photosynthesis. Plants use sunlight, '
            'water, and carbon dioxide to make sugar and release oxygen.", '
            '"key_terms": ['
            '{"term": "photosynthesis", "definition": "the process plants use to make food from sunlight"}, '
            '{"term": "chlorophyll", "definition": "the green pigment in plants that captures sunlight"}, '
            '{"term": "chloroplast", "definition": "the part of a plant cell where photosynthesis happens"}'
            '], "practice_questions": ['
            '"What gas do plants take in during photosynthesis?", '
            '"What gas do plants release?", '
            '"What is chlorophyll and what does it do?"'
            ']}'
        )
