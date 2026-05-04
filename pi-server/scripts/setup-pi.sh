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

echo "==> Downloading whisper.cpp tiny.en model..."
WHISPER_MODEL="$MODELS_DIR/ggml-tiny.en.bin"
if [ ! -f "$WHISPER_MODEL" ]; then
  curl -L -o "$WHISPER_MODEL" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin
fi

echo "==> Downloading Gemma 4 E2B Q4_K_M GGUF..."
# Replace this with the canonical download URL once Gemma 4 GGUFs are mirrored.
GEMMA_MODEL="$MODELS_DIR/gemma-4-E2B-it-Q4_K_M.gguf"
if [ ! -f "$GEMMA_MODEL" ]; then
  echo "Please download Gemma 4 E2B Q4_K_M from"
  echo "  https://huggingface.co/google/gemma-4-E2B-it-GGUF"
  echo "and place it at $GEMMA_MODEL"
  exit 1
fi

echo "==> Done. Run with:  source .venv/bin/activate && uvicorn app.main:app --host 0.0.0.0 --port 8080"
