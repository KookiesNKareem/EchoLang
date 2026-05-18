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


