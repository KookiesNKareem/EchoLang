"""Minimal smoke test: server boots and the non-AI endpoints respond.

Run with:  pytest pi-server/tests/test_smoke.py -q

These tests deliberately avoid loading whisper or Gemma so they run on
any laptop without the model files present.
"""
from fastapi.testclient import TestClient

# Import without triggering lifespan startup that loads models
from app import main


def test_health_responds():
    with TestClient(main.app) as client:
        r = client.get("/api/health")
        assert r.status_code == 200
        body = r.json()
        assert body["ok"] is True
        assert "supported_languages" in body


def test_active_class_empty():
    with TestClient(main.app) as client:
        r = client.get("/api/class/active")
        assert r.status_code == 204


def test_qr_for_unknown_class_still_renders():
    # QR endpoint doesn't require a real class — useful for printing
    # a "join here" code before class even starts.
    with TestClient(main.app) as client:
        r = client.get("/api/qr/test-class")
        assert r.status_code == 200
        assert r.headers["content-type"] == "image/png"
