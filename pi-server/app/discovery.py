"""Bonjour/mDNS advertising via Avahi (the system mDNS daemon on Pi OS).

Why subprocess instead of the Python `zeroconf` library: Avahi already owns
mDNS on Pi OS and binds the multicast group socket. The Python `zeroconf`
library can't coexist on the same machine — it raises EventLoopBlocked
because Avahi swallows the responses to its name-conflict checks.

Easier path: shell out to `avahi-publish-service`, which is the canonical
Linux tool for this. The subprocess holds the registration alive; killing
it deregisters. To refresh TXT records (e.g. when a class starts), we kill
the old subprocess and start a new one with the new records.

Service: `_locallearning._tcp` on port 8080 with TXT records:
  title, teacher, class_id, langs, version
"""
from __future__ import annotations

import logging
import shutil
import socket
import subprocess
from typing import Optional

from .config import settings

log = logging.getLogger(__name__)

SERVICE_TYPE = "_locallearning._tcp"
INSTANCE_NAME_TMPL = "LocalLearning on {host}"

AVAHI_BIN = "avahi-publish-service"


class Advertiser:
    def __init__(self, port: int = settings.port):
        self.port = port
        self._proc: Optional[subprocess.Popen] = None
        self._instance = INSTANCE_NAME_TMPL.format(host=socket.gethostname())

    def start(self) -> None:
        if shutil.which(AVAHI_BIN) is None:
            raise FileNotFoundError(
                f"{AVAHI_BIN} not found. Install with: sudo apt-get install -y avahi-utils"
            )
        self._spawn()

    def stop(self) -> None:
        self._kill()

    def refresh(self) -> None:
        """Republish with current class metadata (TXT records change)."""
        if shutil.which(AVAHI_BIN) is None:
            return
        self._kill()
        self._spawn()

    # ---- internals ----

    def _spawn(self) -> None:
        cmd = [AVAHI_BIN, self._instance, SERVICE_TYPE, str(self.port)] + self._txt_args()
        self._proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        log.info("mDNS service registered via avahi: %r on %s:%d", self._instance, SERVICE_TYPE, self.port)

    def _kill(self) -> None:
        if self._proc is None:
            return
        try:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait(timeout=2)
        finally:
            self._proc = None

    def _txt_args(self) -> list[str]:
        # Lazy import to avoid circular
        from .store import store

        active = store.active()
        return [
            f"title={active.title if active else ''}",
            f"teacher={(active.teacher or '') if active else ''}",
            f"class_id={active.id if active else ''}",
            f"langs={','.join(settings.supported_languages)}",
            "version=1",
        ]


_advertiser: Optional[Advertiser] = None


def get_advertiser() -> Optional[Advertiser]:
    return _advertiser


def start_advertiser() -> Advertiser:
    global _advertiser
    if _advertiser is None:
        _advertiser = Advertiser()
        _advertiser.start()
    return _advertiser


def stop_advertiser() -> None:
    global _advertiser
    if _advertiser is not None:
        _advertiser.stop()
        _advertiser = None
