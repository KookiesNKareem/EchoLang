"""Lecture bundle: ZIP file the Android app downloads after class.

A bundle contains everything the offline study companion needs:

  manifest.json    - lecture metadata, language, version, build time
  transcript.txt   - English captions, one sentence per line, with timestamps
  translation.txt  - target-language captions, one sentence per line
  study_pack.json  - {summary, key_terms, practice_questions} in target language
  confusions.json  - caption indices the student marked confusing

The bundle deliberately omits audio for v1 — a 50-minute lecture in Opus is
~15 MB and we'd rather get the text-only bundle to the phone reliably first.
"""
from __future__ import annotations

import io
import json
import logging
import zipfile
from datetime import datetime, timezone

from .models import Caption, ClassSession, ConfusionMark, StudyPack, Translation

log = logging.getLogger(__name__)

BUNDLE_VERSION = "1"


def _format_transcript(captions: list[Caption]) -> str:
    lines = []
    for c in captions:
        ts = c.started_at.strftime("%H:%M:%S")
        lines.append(f"[{ts}] (#{c.index}) {c.text}")
    return "\n".join(lines) + "\n"


def _format_translation(captions: list[Caption], translations: list[Translation]) -> str:
    by_idx = {t.caption_index: t.text for t in translations}
    lines = []
    for c in captions:
        ts = c.started_at.strftime("%H:%M:%S")
        text = by_idx.get(c.index, "")
        lines.append(f"[{ts}] (#{c.index}) {text}")
    return "\n".join(lines) + "\n"


def build_bundle_zip(
    session: ClassSession,
    lang: str,
    captions: list[Caption],
    translations: list[Translation],
    confusions: list[ConfusionMark],
    study_pack: StudyPack | None,
) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        manifest = {
            "bundle_version": BUNDLE_VERSION,
            "class_id": session.id,
            "title": session.title,
            "teacher": session.teacher,
            "lang": lang,
            "started_at": session.started_at.isoformat(),
            "ended_at": (session.ended_at or datetime.now(timezone.utc)).isoformat(),
            "caption_count": len(captions),
            "built_at": datetime.now(timezone.utc).isoformat(),
        }
        zf.writestr("manifest.json", json.dumps(manifest, indent=2))
        zf.writestr("transcript.txt", _format_transcript(captions))
        zf.writestr("translation.txt", _format_translation(captions, translations))
        if study_pack is not None:
            zf.writestr("study_pack.json", study_pack.model_dump_json(indent=2))
        # Only include this student's marks if we ever pass them; for now,
        # bundle has all marks for the class so the app can suggest "your
        # classmates also flagged these moments."
        zf.writestr(
            "confusions.json",
            json.dumps([m.model_dump(mode="json") for m in confusions], indent=2),
        )
    return buf.getvalue()
