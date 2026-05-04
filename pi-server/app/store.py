"""In-memory store for the live class.

For the hackathon we keep one active class in memory plus a handful of
recently-ended classes. Persistence to disk happens at end-of-class
(see bundle.py).
"""
from __future__ import annotations

import threading
from collections import defaultdict

from .models import Caption, ClassSession, ClassState, ConfusionMark, Translation


class LectureStore:
    def __init__(self):
        self._lock = threading.Lock()
        self._sessions: dict[str, ClassSession] = {}
        self._captions: dict[str, list[Caption]] = defaultdict(list)
        self._translations: dict[tuple[str, str], list[Translation]] = defaultdict(list)
        self._confusions: dict[str, list[ConfusionMark]] = defaultdict(list)
        self._active_id: str | None = None

    def start_class(self, title: str, teacher: str | None = None) -> ClassSession:
        with self._lock:
            session = ClassSession(title=title, teacher=teacher)
            self._sessions[session.id] = session
            self._active_id = session.id
            return session

    def end_class(self, class_id: str) -> ClassSession | None:
        with self._lock:
            session = self._sessions.get(class_id)
            if session is None:
                return None
            session.state = ClassState.ENDED
            from datetime import datetime, timezone
            session.ended_at = datetime.now(timezone.utc)
            if self._active_id == class_id:
                self._active_id = None
            return session

    def active(self) -> ClassSession | None:
        with self._lock:
            if self._active_id is None:
                return None
            return self._sessions.get(self._active_id)

    def get(self, class_id: str) -> ClassSession | None:
        with self._lock:
            return self._sessions.get(class_id)

    def append_caption(self, class_id: str, text: str, started_at, ended_at) -> Caption:
        with self._lock:
            captions = self._captions[class_id]
            caption = Caption(index=len(captions), text=text, started_at=started_at, ended_at=ended_at)
            captions.append(caption)
            return caption

    def captions(self, class_id: str) -> list[Caption]:
        with self._lock:
            return list(self._captions[class_id])

    def append_translation(self, class_id: str, t: Translation) -> None:
        with self._lock:
            self._translations[(class_id, t.lang)].append(t)

    def translations(self, class_id: str, lang: str) -> list[Translation]:
        with self._lock:
            return list(self._translations[(class_id, lang)])

    def add_confusion(self, class_id: str, mark: ConfusionMark) -> None:
        with self._lock:
            self._confusions[class_id].append(mark)

    def confusions(self, class_id: str) -> list[ConfusionMark]:
        with self._lock:
            return list(self._confusions[class_id])


store = LectureStore()
