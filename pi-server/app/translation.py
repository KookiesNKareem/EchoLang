"""Gemma-powered translation worker.

Pulls finalized English captions out of an input queue and produces
translations into each currently-subscribed language. Translations are
published to per-language broadcast queues that the SSE endpoints read.
"""
from __future__ import annotations

import asyncio
import logging
import threading
from collections import defaultdict
from collections.abc import Callable

from .config import settings
from .models import Caption, Translation

log = logging.getLogger(__name__)


LANG_NAMES = {
    "ar": "Arabic",
    "uk": "Ukrainian",
    "es": "Spanish",
    "zh": "Chinese (Simplified Mandarin)",
    "fr": "French",
    "ps": "Pashto",
    "fa": "Farsi",
    "en": "English",
}


def translation_prompt(text: str, target_lang: str) -> str:
    name = LANG_NAMES.get(target_lang, target_lang)
    return (
        f"Translate the following classroom lecture sentence into {name}. "
        f"Output only the translation, no quotes, no commentary.\n\n"
        f"Sentence: {text}\n\n"
        f"Translation in {name}:"
    )


class GemmaTranslator:
    """Loads Gemma 4 E2B once and serves translation calls.

    llama-cpp-python is not thread-safe across simultaneous generations
    on a single context, so we serialize all calls through a lock.
    On a Pi 5 this matches reality: there's one CPU and one model.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._llm = None  # lazy-loaded

    def _load(self):
        if self._llm is not None:
            return self._llm
        from llama_cpp import Llama

        model_path = settings.models_dir / settings.gemma_model
        if not model_path.exists():
            raise FileNotFoundError(
                f"Gemma model not found at {model_path}. "
                f"Run scripts/setup-pi.sh to download."
            )
        log.info("loading Gemma model from %s", model_path)
        self._llm = Llama(
            model_path=str(model_path),
            n_ctx=settings.gemma_ctx,
            n_threads=settings.gemma_threads,
            verbose=False,
        )
        return self._llm

    def translate(self, text: str, target_lang: str, max_tokens: int = 256) -> str:
        if target_lang == "en":
            return text
        with self._lock:
            llm = self._load()
            out = llm(
                prompt=translation_prompt(text, target_lang),
                max_tokens=max_tokens,
                stop=["\n\n", "Sentence:", "Translation in"],
                temperature=0.2,
            )
        return out["choices"][0]["text"].strip()

    def generate(self, prompt: str, max_tokens: int = 512, temperature: float = 0.3) -> str:
        """Generic generation, used for study pack production."""
        with self._lock:
            llm = self._load()
            out = llm(prompt=prompt, max_tokens=max_tokens, temperature=temperature)
        return out["choices"][0]["text"].strip()


class TranslationBus:
    """Per-language async broadcast bus.

    Each SSE subscriber gets its own asyncio.Queue. The bus broadcasts
    each translation to every queue subscribed to that language.
    """

    def __init__(self):
        self._subs: dict[str, set[asyncio.Queue[Translation]]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def subscribe(self, lang: str) -> asyncio.Queue[Translation]:
        q: asyncio.Queue[Translation] = asyncio.Queue(maxsize=200)
        async with self._lock:
            self._subs[lang].add(q)
        return q

    async def unsubscribe(self, lang: str, q: asyncio.Queue[Translation]) -> None:
        async with self._lock:
            self._subs[lang].discard(q)

    async def publish(self, t: Translation) -> None:
        async with self._lock:
            queues = list(self._subs.get(t.lang, ()))
        for q in queues:
            try:
                q.put_nowait(t)
            except asyncio.QueueFull:
                log.warning("dropping translation for slow subscriber on %s", t.lang)

    def active_langs(self) -> set[str]:
        return {lang for lang, subs in self._subs.items() if subs}


class TranslationWorker:
    """Consumes captions from a thread-side queue and translates them
    into every currently-subscribed language, publishing on the bus.
    """

    def __init__(
        self,
        translator: GemmaTranslator,
        bus: TranslationBus,
        on_translation: Callable[[Translation], None] | None = None,
    ):
        self.translator = translator
        self.bus = bus
        self.on_translation = on_translation
        self._loop: asyncio.AbstractEventLoop | None = None
        self._task: asyncio.Task | None = None
        self._inbox: asyncio.Queue[Caption] = asyncio.Queue()

    def submit_from_thread(self, caption: Caption) -> None:
        """Called from the whisper thread."""
        if self._loop is None:
            return
        self._loop.call_soon_threadsafe(self._inbox.put_nowait, caption)

    async def start(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    async def _run(self) -> None:
        while True:
            caption: Caption = await self._inbox.get()
            langs = self.bus.active_langs()
            if not langs:
                # No one listening — still record English so we have a transcript.
                continue
            for lang in langs:
                # Run blocking llama call in default executor so SSE keeps draining.
                text = await asyncio.to_thread(self.translator.translate, caption.text, lang)
                t = Translation(caption_index=caption.index, lang=lang, text=text)
                await self.bus.publish(t)
                if self.on_translation:
                    self.on_translation(t)
