"""End-of-class study pack generation.

For each language a student wants, ask Gemma to produce:
  - a 3-5 sentence summary of the lecture
  - 5-10 key terms with concise definitions
  - 5-8 practice questions

The lecture transcript can be long, so we summarize against the English
transcript (Gemma's strongest direction) and then translate the resulting
pack into the target language in a second pass. This gives much better
quality than asking Gemma to summarize a Mandarin transcript directly.
"""
from __future__ import annotations

import json
import logging
import re

from .models import Caption, StudyPack
from .translation import GemmaTranslator, LANG_NAMES

log = logging.getLogger(__name__)

# How many transcript characters to feed Gemma per pass. Keeps us under the
# 4k context limit comfortably even after the prompt and the model's reply.
MAX_TRANSCRIPT_CHARS = 6000


def _flatten(captions: list[Caption], confused_indices: set[int] | None = None) -> str:
    parts = []
    for c in captions:
        marker = " [STUDENT MARKED CONFUSING]" if confused_indices and c.index in confused_indices else ""
        parts.append(f"{c.text}{marker}")
    text = " ".join(parts)
    if len(text) > MAX_TRANSCRIPT_CHARS:
        # Keep beginning and end — the head sets up the topic, the end has
        # any conclusion or summary the teacher gave.
        head = text[: MAX_TRANSCRIPT_CHARS // 2]
        tail = text[-MAX_TRANSCRIPT_CHARS // 2 :]
        text = head + "\n\n[...lecture continues...]\n\n" + tail
    return text


_PROMPT = """You are an academic tutor. Below is a transcript of a classroom
lecture. Produce a study pack with three sections, in JSON.

Transcript:
\"\"\"
{transcript}
\"\"\"

Respond with strict JSON in this exact shape (no commentary, no code fence):
{{
  "summary": "3-5 sentences summarizing what was taught",
  "key_terms": [
    {{"term": "term name", "definition": "one-sentence definition"}},
    ...
  ],
  "practice_questions": [
    "first practice question",
    "second practice question",
    ...
  ]
}}

Use 5-10 key_terms and 5-8 practice_questions. If the student marked any
parts as confusing, give those topics extra attention in the summary and
include practice questions about them.

JSON:
"""


def _extract_json(text: str) -> dict:
    # Be resilient to model adding stray characters around the JSON.
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"no JSON object in model output: {text!r}")
    return json.loads(match.group(0))


def generate_english_pack(translator: GemmaTranslator, transcript: str) -> dict:
    prompt = _PROMPT.format(transcript=transcript)
    raw = translator.generate(prompt, max_tokens=768, temperature=0.4)
    try:
        return _extract_json(raw)
    except Exception as e:
        log.warning("study-pack JSON parse failed (%s); falling back to plain summary", e)
        return {
            "summary": raw[:600],
            "key_terms": [],
            "practice_questions": [],
        }


_TRANSLATE_PACK_PROMPT = """Translate every string value in this JSON into {name}.
Keep the same JSON structure and keys. Output only the translated JSON, no
commentary or code fence.

Input JSON:
{pack}

{name} JSON:
"""


def translate_pack(translator: GemmaTranslator, pack: dict, target_lang: str) -> dict:
    if target_lang == "en":
        return pack
    name = LANG_NAMES.get(target_lang, target_lang)
    prompt = _TRANSLATE_PACK_PROMPT.format(
        name=name,
        pack=json.dumps(pack, ensure_ascii=False),
    )
    try:
        raw = translator.generate(prompt, max_tokens=1024, temperature=0.2)
        return _extract_json(raw)
    except Exception as e:
        log.warning("bulk pack translation failed (%s); returning English pack", e)
        return pack


def build_study_pack(
    translator: GemmaTranslator,
    captions: list[Caption],
    confused_indices: set[int],
    lang: str,
) -> StudyPack:
    transcript = _flatten(captions, confused_indices)
    english_pack = generate_english_pack(translator, transcript)
    localized = translate_pack(translator, english_pack, lang)
    return StudyPack(
        lang=lang,
        summary=localized["summary"],
        key_terms=localized["key_terms"],
        practice_questions=localized["practice_questions"],
    )
