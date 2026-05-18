#!/usr/bin/env bash
# Setup script for the LocalLearning Pi server.
# Downloads model weights and installs system deps.
# Run on a fresh Raspberry Pi 5 (Bookworm 64-bit) with at least 16GB free disk.
set -euo pipefail

cd "$(dirname "$0")/.."

MODELS_DIR="${MODELS_DIR:-./models}"
mkdir -p "$MODELS_DIR"

echo "==> Installing system packages..."
sudo apt-get update
sudo apt-get install -y \
  python3 python3-venv python3-pip \
  build-essential cmake \
  portaudio19-dev libsndfile1 \
  libgomp1

echo "==> Setting up Python venv..."
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip wheel
pip install -r requirements.txt

echo "==> Downloading whisper.cpp base.en model (better accuracy than tiny.en)..."
WHISPER_MODEL="$MODELS_DIR/ggml-base.en.bin"
if [ ! -f "$WHISPER_MODEL" ]; then
  curl -L -o "$WHISPER_MODEL" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
fi

echo "==> Installing Ollama (if not already present)..."
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

echo "==> Ensuring Ollama service is running..."
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable --now ollama 2>/dev/null || true
fi
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> Pulling Gemma 4 E2B via Ollama (default backend in app/config.py)..."
ollama pull gemma4:e2b

echo "==> Done. Run with:  source .venv/bin/activate && uvicorn app.main:app --host 0.0.0.0 --port 8080"
