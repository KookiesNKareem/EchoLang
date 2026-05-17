# EchoLang

> A $80 Raspberry Pi turns any classroom into a multilingual, offline AI learning hub.
>
> Submission to the [Gemma 4 Good Hackathon](https://kaggle.com/competitions/gemma-4-good-hackathon).

## What it does

1. Teacher speaks in English. The Pi captures audio.
2. Students scan a QR code, open a webpage on their phones, and pick their language.
3. Live captions stream in their own language as the teacher talks — Arabic, Ukrainian, Spanish, Mandarin, all at once.
4. End of class: a study bundle (transcript + translations + AI study pack) downloads to a companion iOS or Android app.
5. Student walks home, no internet on the bus, opens the app, and asks Gemma running **on their phone** any question about the lecture.

Nothing leaves the room. No accounts. No cloud.

## Architecture

```
[USB mic] -> whisper.cpp (Pi) -> Gemma 4 E2B via Ollama (Pi) -> SSE -> student PWAs
                                              |
                                              v
                                  end-of-class study bundle
                                              |
                                              v
                          iOS / Android app (Gemma 4 E2B LiteRT, MTP on iOS)
                                  for fully-offline Q&A
```

## Repository layout

- `pi-server/` — FastAPI server that runs on the Raspberry Pi 5
- `pwa/` — Student-facing web app for live captions
- `mobile-app/` — Cross-platform Flutter app (iOS + Android) for offline lecture Q&A

## Hardware

- **Pi-side:** Raspberry Pi 5 (8 GB), USB microphone, WiFi
- **Student-side during class:** any device with a browser
- **Student-side after class:** iOS or Android phone with ~6 GB+ RAM (for on-device Gemma 4 E2B)

## Models

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `base.en` for Pi transcription
- [Gemma 4 E2B](https://huggingface.co/google/gemma-4-E2B) on the Pi via [Ollama](https://ollama.com) (`ollama pull gemma4:e2b`)
- [Gemma 4 E2B](https://huggingface.co/google/gemma-4-E2B) `.litertlm` bundle on phones via [flutter_gemma](https://pub.dev/packages/flutter_gemma) / [MediaPipe LLM Inference](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference) — MTP-enabled variant on iOS for ~2× faster decode

## Status

In development for the 2026-05-18 deadline.
