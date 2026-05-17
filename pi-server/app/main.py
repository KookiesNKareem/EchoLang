"""FastAPI app for the LocalLearning Pi server.

Endpoints (v1):
  POST /api/class                   - start a new class (body: title, teacher?)
  POST /api/class/{id}/end          - end a class
  GET  /api/class/active            - currently-live class, if any
  GET  /api/class/{id}              - class metadata + caption count

  GET  /api/qr/{id}                 - QR code PNG that resolves to /join?class={id}
  GET  /join                        - student PWA entry point (serves pwa/index.html)

  GET  /api/stream/{class_id}/{lang}     - SSE stream of translated captions for a language
  POST /api/class/{id}/confusion         - body: {student_id, caption_index}

  HEAD /api/model/gemma             - phone-side Gemma LiteRT bundle metadata (size)
  GET  /api/model/gemma             - phone-side Gemma LiteRT bundle (Range supported)

  GET  /api/health                  - health check
"""
from __future__ import annotations

import asyncio
import io
import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path

import qrcode
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from .bundle import build_bundle_zip
from .config import settings
from .discovery import get_advertiser, start_advertiser, stop_advertiser
from .models import Caption, ConfusionMark, StudyPack, Translation
from .store import store
from .studypack import build_study_pack
from .translation import Translator, TranslationBus, TranslationWorker, make_translator

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


# ---- Globals wired up at startup --------------------------------------------------

bus = TranslationBus()
translator: Translator | None = None
worker: TranslationWorker | None = None
transcriber = None  # WhisperTranscriber or FakeTranscriber, lazy


@asynccontextmanager
async def lifespan(app: FastAPI):
    global translator, worker
    translator = make_translator()
    log.info("translator backend: %s", type(translator).__name__)
    # Pre-load the model so the first real translation doesn't pay cold-start.
    if hasattr(translator, "warm_up"):
        log.info("warming up translator (this can take ~90s on first boot)…")
        await asyncio.to_thread(translator.warm_up)
    worker = TranslationWorker(
        translator=translator,
        bus=bus,
        on_translation=lambda t: _persist_translation(t),
    )
    await worker.start()
    log.info("translation worker started")
    try:
        start_advertiser()
    except Exception as e:  # noqa: BLE001 — mDNS is best-effort; don't crash the server
        log.warning("mDNS advertise failed (continuing without auto-discovery): %r", e)
    yield
    if worker is not None:
        await worker.stop()
    if transcriber is not None:
        transcriber.stop()
    stop_advertiser()


def _persist_translation(t: Translation) -> None:
    active = store.active()
    if active is None:
        return
    store.append_translation(active.id, t)


def _on_caption(text: str, started_at, ended_at) -> None:
    """Called from the whisper background thread."""
    active = store.active()
    if active is None:
        return
    caption = store.append_caption(active.id, text, started_at, ended_at)
    log.info("caption #%d: %s", caption.index, caption.text)
    if worker is not None:
        worker.submit_from_thread(caption)


app = FastAPI(title="LocalLearning Pi Server", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---- Schemas ---------------------------------------------------------------------


class StartClassReq(BaseModel):
    title: str
    teacher: str | None = None


class ConfusionReq(BaseModel):
    student_id: str
    caption_index: int


# ---- Health --------------------------------------------------------------------


@app.get("/api/health")
def health():
    active = store.active()
    return {
        "ok": True,
        "active_class": active.id if active else None,
        "supported_languages": settings.supported_languages,
        "has_phone_model": _gemma_litertlm_path().is_file(),
    }


# ---- Phone-side model serving ---------------------------------------------------
# Lets the mobile app pull Gemma 4 E2B (LiteRT, MTP) from the Pi over LAN
# instead of Hugging Face. The Pi only needs to download the 2.6 GB bundle
# once; phones then grab it at WiFi speeds, no public internet required.
# Starlette's FileResponse honors Range requests automatically, so flaky
# connections resume from a .part file cleanly.


def _gemma_litertlm_path() -> Path:
    return settings.models_dir / settings.gemma_litertlm


@app.head("/api/model/gemma")
def head_gemma_model():
    p = _gemma_litertlm_path()
    if not p.is_file():
        raise HTTPException(404, "Phone-side Gemma bundle not present on this Pi")
    return Response(
        status_code=200,
        headers={
            "content-length": str(p.stat().st_size),
            "content-type": "application/octet-stream",
            "accept-ranges": "bytes",
        },
    )


@app.get("/api/model/gemma")
def get_gemma_model():
    p = _gemma_litertlm_path()
    if not p.is_file():
        raise HTTPException(404, "Phone-side Gemma bundle not present on this Pi")
    return FileResponse(
        p,
        media_type="application/octet-stream",
        filename=p.name,
        headers={"accept-ranges": "bytes"},
    )


# ---- Class lifecycle ------------------------------------------------------------


@app.post("/api/class")
def start_class(req: StartClassReq):
    global transcriber
    if store.active() is not None:
        raise HTTPException(409, "A class is already in progress")
    session = store.start_class(title=req.title, teacher=req.teacher)

    if settings.fake:
        from .fakes import FakeTranscriber
        transcriber = FakeTranscriber(on_caption=_on_caption)
        log.info("FAKE MODE: using FakeTranscriber (no whisper model loaded)")
    else:
        # Lazy-import so the missing audio deps don't crash the server when
        # transcription isn't available (e.g. no USB mic, fresh Pi without
        # whisper.cpp + sounddevice installed). Falling back to typed-caption
        # mode means the rest of the pipeline (translation, study pack, bundle)
        # still works.
        try:
            from .transcription import WhisperTranscriber
            transcriber = WhisperTranscriber(on_caption=_on_caption)
        except (ModuleNotFoundError, FileNotFoundError, OSError) as e:
            log.warning(
                "Audio transcription unavailable (%s). Class started in "
                "typed-caption mode — POST /api/class/{id}/caption to add lines.",
                e,
            )
            transcriber = None
            adv = get_advertiser()
            if adv is not None:
                adv.refresh()
            return session
    transcriber.start()
    adv = get_advertiser()
    if adv is not None:
        adv.refresh()
    return session


@app.post("/api/class/{class_id}/end")
def end_class(class_id: str):
    global transcriber
    session = store.end_class(class_id)
    if session is None:
        raise HTTPException(404, "Class not found")
    if transcriber is not None:
        transcriber.stop()
        transcriber = None
    adv = get_advertiser()
    if adv is not None:
        adv.refresh()
    return session


# ---- Study packs + bundle download --------------------------------------------

# Cache: (class_id, lang) -> StudyPack. Generation is expensive; once a pack
# exists we don't regenerate unless the caller asks for refresh.
_pack_cache: dict[tuple[str, str], StudyPack] = {}


def _get_or_build_pack(class_id: str, lang: str) -> StudyPack:
    key = (class_id, lang)
    if key in _pack_cache:
        return _pack_cache[key]
    if translator is None:
        raise HTTPException(503, "Translator not ready")
    captions = store.captions(class_id)
    if not captions:
        raise HTTPException(400, "No captions yet — class hasn't produced any text")
    confused = {m.caption_index for m in store.confusions(class_id)}
    pack = build_study_pack(translator, captions, confused, lang)
    _pack_cache[key] = pack
    return pack


@app.post("/api/class/{class_id}/studypack/{lang}")
def generate_pack(class_id: str, lang: str, refresh: bool = False):
    if store.get(class_id) is None:
        raise HTTPException(404, "Class not found")
    if lang not in settings.supported_languages and lang != "en":
        raise HTTPException(400, f"Unsupported language: {lang}")
    if refresh:
        _pack_cache.pop((class_id, lang), None)
    return _get_or_build_pack(class_id, lang)


@app.get("/api/lecture/{class_id}/bundle")
def download_bundle(class_id: str, lang: str = "en"):
    session = store.get(class_id)
    if session is None:
        raise HTTPException(404, "Class not found")
    if lang not in settings.supported_languages and lang != "en":
        raise HTTPException(400, f"Unsupported language: {lang}")

    captions = store.captions(class_id)
    translations = store.translations(class_id, lang) if lang != "en" else []
    confusions = store.confusions(class_id)

    pack: StudyPack | None = None
    if captions:
        try:
            pack = _get_or_build_pack(class_id, lang)
        except HTTPException:
            pack = None

    data = build_bundle_zip(
        session=session,
        lang=lang,
        captions=captions,
        translations=translations,
        confusions=confusions,
        study_pack=pack,
    )
    fname = f"{session.title.replace(' ', '_')}_{lang}.zip"
    return Response(
        content=data,
        media_type="application/zip",
        headers={"content-disposition": f'attachment; filename="{fname}"'},
    )


@app.get("/api/class/active")
def active_class():
    session = store.active()
    if session is None:
        return Response(status_code=204)
    return session


@app.get("/api/class/{class_id}")
def get_class(class_id: str):
    session = store.get(class_id)
    if session is None:
        raise HTTPException(404, "Class not found")
    return {
        "session": session,
        "caption_count": len(store.captions(class_id)),
        "confusion_count": len(store.confusions(class_id)),
    }


# ---- QR + join page -------------------------------------------------------------


@app.get("/api/qr/{class_id}")
def class_qr(class_id: str, request: Request):
    base = str(request.base_url).rstrip("/")
    join_url = f"{base}/join?class={class_id}"
    img = qrcode.make(join_url)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return Response(content=buf.getvalue(), media_type="image/png")


# ---- Live translation stream ----------------------------------------------------


@app.get("/api/stream/{class_id}/{lang}")
async def stream(class_id: str, lang: str, request: Request):
    if lang not in settings.supported_languages and lang != "en":
        raise HTTPException(400, f"Unsupported language: {lang}")
    if store.get(class_id) is None:
        raise HTTPException(404, "Class not found")

    q = await bus.subscribe(lang)

    async def event_gen():
        try:
            # Replay any captions/translations that have already been emitted
            # so a late-joining student doesn't miss what the teacher said.
            if lang == "en":
                for c in store.captions(class_id):
                    yield {"event": "caption", "data": json.dumps(c.model_dump(mode="json"))}
            else:
                for t in store.translations(class_id, lang):
                    yield {"event": "caption", "data": json.dumps(t.model_dump(mode="json"))}

            while True:
                if await request.is_disconnected():
                    break
                try:
                    item: Translation = await asyncio.wait_for(q.get(), timeout=15)
                except asyncio.TimeoutError:
                    yield {"event": "ping", "data": "1"}
                    continue
                if item.lang != lang:
                    continue
                yield {"event": "caption", "data": json.dumps(item.model_dump(mode="json"))}
        finally:
            await bus.unsubscribe(lang, q)

    return EventSourceResponse(event_gen())


# ---- Confusion marks ------------------------------------------------------------


@app.post("/api/class/{class_id}/confusion")
def add_confusion(class_id: str, req: ConfusionReq):
    if store.get(class_id) is None:
        raise HTTPException(404, "Class not found")
    mark = ConfusionMark(student_id=req.student_id, caption_index=req.caption_index)
    store.add_confusion(class_id, mark)
    return mark


# ---- Manual caption injection (for mic-less testing + teacher fallback) -------

class InjectCaptionReq(BaseModel):
    text: str


@app.post("/api/class/{class_id}/caption")
def inject_caption(class_id: str, req: InjectCaptionReq):
    """Add a caption to the active class without going through whisper.

    Two real uses:
      1. Testing the translation pipeline without a USB mic on the Pi.
      2. Teacher fallback when audio is unreliable — they can type the next
         line and students still get translated captions.
    """
    if store.active() is None or store.active().id != class_id:
        raise HTTPException(404, "Class is not active")
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "Empty caption")
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    _on_caption(text, now, now)
    return {"ok": True}


# ---- Static PWA ----------------------------------------------------------------

PWA_DIR = Path(__file__).resolve().parents[2] / "pwa"


@app.get("/")
@app.get("/join")
def serve_pwa_root():
    index = PWA_DIR / "index.html"
    if not index.exists():
        raise HTTPException(404, "PWA not built yet")
    return FileResponse(index)


if PWA_DIR.exists():
    app.mount("/static", StaticFiles(directory=PWA_DIR), name="static")
