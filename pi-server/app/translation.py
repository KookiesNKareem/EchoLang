"""Gemma-powered translation worker.

Pulls finalized English captions out of an input queue and produces
translations into each currently-subscribed language. Translations are
published to per-language broadcast queues that the SSE endpoints read.

Two interchangeable backends:

  - OllamaTranslator: hits the local Ollama daemon's HTTP API.
    Default. Easiest setup — `ollama pull gemma4:e2b` and you're done.
  - LlamaCppTranslator: uses llama-cpp-python against a raw GGUF.
    Lets us add custom samplers, thread pinning, and other low-level
    optimizations the Ollama HTTP API doesn't expose.

Pick via `LL_BACKEND=ollama` (default) or `LL_BACKEND=llamacpp`.
"""
from __future__ import annotations

import asyncio
import json
import logging
import threading
import urllib.error
import urllib.request
from collections import defaultdict
from collections.abc import Callable
from typing import Protocol

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


# ---- Translator protocol --------------------------------------------------------


class Translator(Protocol):
    """Pluggable Gemma backend.

    Implementations must be safe to call from a worker thread (the
    TranslationWorker does so via asyncio.to_thread). They do not need to be
    safe to call concurrently — callers serialize.
    """

    def translate(self, text: str, target_lang: str, max_tokens: int = 256) -> str: ...

    def generate(self, prompt: str, max_tokens: int = 512, temperature: float = 0.3) -> str: ...


# ---- Ollama backend ------------------------------------------------------------


class OllamaTranslator:
    """Talks to a local Ollama daemon over HTTP.

    No model files to manage in this codebase — Ollama owns model storage.
    User runs `ollama pull gemma4:e2b` once; we just call /api/generate.
    """

    def __init__(
        self,
        url: str = settings.ollama_url,
        model: str = settings.ollama_model,
        timeout_s: float = settings.ollama_timeout_s,
    ):
        self.url = url.rstrip("/")
        self.model = model
        self.timeout_s = timeout_s
        self._lock = threading.Lock()
        log.info("OllamaTranslator initialized (url=%s, model=%s)", self.url, self.model)

    def _post_generate(self, prompt: str, *, max_tokens: int, temperature: float, stop: list[str] | None = None) -> str:
        body = {
            "model": self.model,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": temperature,
                "num_predict": max_tokens,
            },
        }
        if stop:
            body["options"]["stop"] = stop
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            f"{self.url}/api/generate",
            data=data,
            headers={"content-type": "application/json"},
            method="POST",
        )
        with self._lock:  # serialize: Ollama queues internally but locking gives stable latency
            try:
                with urllib.request.urlopen(req, timeout=self.timeout_s) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
            except urllib.error.URLError as e:
                raise RuntimeError(f"Ollama request failed: {e}") from e
        return (payload.get("response") or "").strip()

    def translate(self, text: str, target_lang: str, max_tokens: int = 256) -> str:
        if target_lang == "en":
            return text
        return self._post_generate(
            translation_prompt(text, target_lang),
            max_tokens=max_tokens,
            temperature=0.2,
            stop=["\n\n", "Sentence:", "Translation in"],
        )

    def generate(self, prompt: str, max_tokens: int = 512, temperature: float = 0.3) -> str:
        return self._post_generate(prompt, max_tokens=max_tokens, temperature=temperature)


# ---- llama.cpp backend ---------------------------------------------------------


class LlamaCppTranslator:
    """Direct llama-cpp-python against a Gemma 4 E2B GGUF.

    Heavier setup (compile llama-cpp-python from source on Pi 5 ARM64,
    download the GGUF separately) but exposes lower-level controls — custom
    samplers, KV cache management, thread pinning — that the Ollama HTTP API
    doesn't. Used when we want to do novel inference engineering.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._llm = None  # lazy-loaded

    def _load(self):
        if self._llm is not None:
            return self._llm
        from llama_cpp import Llama  # imported lazily so ollama-only setups don't need it

        model_path = settings.models_dir / settings.gemma_model
        if not model_path.exists():
            raise FileNotFoundError(
                f"Gemma model not found at {model_path}. "
                f"Download a Gemma 4 E2B GGUF or switch to LL_BACKEND=ollama."
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
        with self._lock:
            llm = self._load()
            out = llm(prompt=prompt, max_tokens=max_tokens, temperature=temperature)
        return out["choices"][0]["text"].strip()


# Backwards-compat alias used by older imports / docs
GemmaTranslator = LlamaCppTranslator


def make_translator() -> Translator:
    """Pick a translator backend based on settings."""
    if settings.fake:
        from .fakes import FakeTranslator
        return FakeTranslator()
    backend = settings.backend.lower()
    if backend == "ollama":
        return OllamaTranslator()
    if backend in ("llamacpp", "llama_cpp", "llama-cpp"):
        return LlamaCppTranslator()
    raise ValueError(f"Unknown LL_BACKEND: {settings.backend!r} (expected 'ollama' or 'llamacpp')")


# ---- Translation bus + worker (unchanged) --------------------------------------


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
        translator: Translator,
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
                continue
            for lang in langs:
                try:
                    text = await asyncio.to_thread(self.translator.translate, caption.text, lang)
                except Exception as e:  # noqa: BLE001 - translation failures shouldn't kill the worker
                    log.exception("translation to %s failed: %s", lang, e)
                    text = f"[translation error: {e}]"
                t = Translation(caption_index=caption.index, lang=lang, text=text)
                await self.bus.publish(t)
                if self.on_translation:
                    self.on_translation(t)
