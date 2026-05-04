from datetime import datetime, timezone
from enum import Enum
from uuid import uuid4

from pydantic import BaseModel, Field


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _id() -> str:
    return uuid4().hex[:12]


class ClassState(str, Enum):
    LIVE = "live"
    ENDED = "ended"


class ClassSession(BaseModel):
    id: str = Field(default_factory=_id)
    title: str
    teacher: str | None = None
    started_at: datetime = Field(default_factory=_now)
    ended_at: datetime | None = None
    state: ClassState = ClassState.LIVE


class Caption(BaseModel):
    """A finalized English sentence with a stable index for ordered streaming."""

    index: int
    text: str
    started_at: datetime
    ended_at: datetime


class Translation(BaseModel):
    caption_index: int
    lang: str
    text: str


class ConfusionMark(BaseModel):
    student_id: str
    caption_index: int
    marked_at: datetime = Field(default_factory=_now)


class StudyPack(BaseModel):
    lang: str
    summary: str
    key_terms: list[dict[str, str]]  # [{term, definition}]
    practice_questions: list[str]
    generated_at: datetime = Field(default_factory=_now)
