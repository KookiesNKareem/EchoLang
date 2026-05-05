# LocalLearning

> A $80 Raspberry Pi turns any classroom into a multilingual, offline AI learning hub.
>
> Submission to the [Gemma 4 Good Hackathon](https://kaggle.com/competitions/gemma-4-good-hackathon).

## What it does

1. Teacher speaks in English. The Pi captures audio.
2. Students scan a QR code, open a webpage on their phones, and pick their language.
3. Live captions stream in their own language as the teacher talks — Arabic, Ukrainian, Spanish, Mandarin, all at once.
4. End of class: a study bundle (transcript + translations + audio + AI study pack) syncs to a companion Android app.
5. Student walks home, no internet on the bus, opens the app, and asks Gemma running **on their phone** any question about the lecture.

Nothing leaves the room. No accounts. No cloud.

## Architecture

```
[USB mic] -> whisper.cpp (Pi) -> Gemma 4 E2B translation (Pi) -> SSE -> student PWAs
                                              |
                                              v
                                  end-of-class study pack
                                              |
                                              v
                              Android app (Gemma 4 E2B on-device)
                                  for fully-offline Q&A
```

See [`docs/plans/2026-05-04-locallearning-design.md`](docs/plans/2026-05-04-locallearning-design.md) for the full design.

## Repository layout

- `pi-server/` — Python FastAPI server that runs on the Raspberry Pi 5
- `pwa/` — Static student-facing web app (live captions, language picker)
- `mobile-app/` — Cross-platform Flutter app (iOS + Android) using Cactus to run Gemma 4 E2B on-device for offline Q&A
- `docs/` — Design docs and demo materials

## Hardware

- **Pi-side:** Raspberry Pi 5 (8 GB), USB microphone, WiFi access point (Pi can run its own hotspot)
- **Student-side during class:** any device with a browser
- **Student-side after class:** Android phone with 6+ GB RAM (for on-device Gemma 4 E2B)

## Models

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `tiny.en` (75 MB)
- [Gemma 4 E2B](https://huggingface.co/google/gemma-4-E2B) Q4_K_M GGUF for the Pi
- [Gemma 4 E2B](https://huggingface.co/google/gemma-4-E2B) INT4 LiteRT bundle for Android via [MediaPipe LLM Inference Task](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference)

## Status

In development for the 2026-05-18 deadline.
