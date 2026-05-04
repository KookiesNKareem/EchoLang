# LocalLearning — Design

**Hackathon:** Gemma 4 Good Hackathon (Kaggle, hosted by Google DeepMind)
**Deadline:** 2026-05-18, 4:59 PM PDT
**Author:** Kareem Fareed
**Date:** 2026-05-04

## Problem

In refugee learning centers and under-resourced schools, two barriers stack on top of each other: the school can't afford the AI tools the rich world has, and many of the students don't yet speak the language of instruction. A teacher in a refugee resettlement classroom may have students from four different language backgrounds in the same room. Existing translation tools require fast internet, accounts, paid subscriptions, or cloud APIs that violate privacy expectations. Existing AI tutors require devices the students don't own.

## Solution

A single Raspberry Pi 5 — a $80 computer — turns any classroom into a multilingual, offline, private learning hub.

1. The teacher speaks. The Pi captures audio.
2. Students scan a QR code on the teacher's screen, open a webpage in their phone's browser, and pick their language.
3. Live captions stream into each student's phone in their own language as the teacher talks.
4. At end of class, a "study bundle" — transcript + translations + audio + an AI-generated study pack — syncs to a companion Android app.
5. The student walks home, has no internet on the bus, opens the app, and asks Gemma running **on their phone** any question about the lecture, in their own language.

Nothing leaves the room. No accounts. No cloud. No bills. One Pi serves a whole class.

## Architecture

### System diagram

```
       [USB mic]
           |
           v
    +-------------+
    | whisper.cpp |  (English transcription, real-time)
    | tiny.en     |
    +-------------+
           |
           v  (finalized sentences)
    +-------------+        per-language SSE
    | Gemma 4 E2B | ----> [PWA: Arabic captions]
    | (llama.cpp) | ----> [PWA: Ukrainian captions]
    | translation | ----> [PWA: Spanish captions]
    +-------------+ ----> [PWA: Mandarin captions]
           |
           v  (end of class)
    +-------------+
    | Gemma 4 E2B |  generates summary + key terms
    | study pack  |  + practice Qs per language
    +-------------+
           |
           v
    [Bundle: transcript+translations+audio+pack]
           |
           v  (sync over local WiFi)
    +-------------+
    | Android app |  Gemma 4 E2B on-device (MediaPipe)
    | offline Q&A |  for fully offline Q&A on bus/home
    +-------------+
```

### Pi server stack

- **Audio capture:** USB microphone via PyAudio or sounddevice, 16kHz mono
- **Transcription:** whisper.cpp tiny.en in streaming mode (`--step 4000 --length 8000 -c 0 -t 4 -ac 512`). Benchmarked real-time on Pi 5 at ~600 MB RAM and 60-80% CPU.
- **Translation:** Gemma 4 E2B via llama-cpp-python. Each finalized sentence is fanned out to N parallel translation calls (one per active student language). Q4_K_M quantization.
- **Server:** FastAPI. SSE endpoint per language (`/stream/{lang}`); REST endpoints for class lifecycle and bundle download.
- **State:** SQLite for lectures + transcripts + translations. Audio stored as Opus.

### Student PWA (during class)

- Single static HTML page served by the Pi. No build step needed (vanilla JS or Vite for dev experience).
- QR code on teacher screen → `http://<pi-ip>/join?class=<id>`.
- Language picker (one-tap; saved in localStorage).
- Live captions stream via EventSource (SSE).
- Each caption tappable → marks a "confusion moment" stored back to the Pi for inclusion in the study pack.
- "Sync to phone" button at end of class (or auto-prompt) deep-links into the Android app to download the bundle.

### Android app (after class)

- Kotlin, single-activity, Jetpack Compose for UI.
- **MediaPipe LLM Inference Task** loads Gemma 4 E2B (INT4) at app start. Benchmarked ~60+ tok/s on mid-range Android hardware.
- Bundle downloader (mDNS or scanned URL) pulls the lecture bundle from the Pi over local WiFi.
- Q&A interface: student types or speaks a question in their language; on-device Gemma answers using the lecture transcript + translation as context. Fully offline.
- Confusion-marked moments shown as suggested questions ("Re-explain this part?").

## Demo video story (3 minutes)

| Time | Scene |
|------|-------|
| 0:00–0:25 | Open: refugee learning center. Four students from different countries. Teacher with one Raspberry Pi on the table. |
| 0:25–0:50 | Teacher writes URL on board, shows QR. Students scan with their phones. Each picks a different language. |
| 0:50–1:20 | Teacher starts a science lesson. Cut between teacher speaking and four phone screens, each showing live captions in a different language. The hub working. |
| 1:20–1:45 | One student taps a confusing caption (close-up). Teacher continues, unaware. |
| 1:45–2:10 | Class ends. Phone shows "Lecture saved for offline study." Bundle syncs. |
| 2:10–2:45 | Cut to a student walking, then sitting on a bus with no signal (airplane mode shown). Opens the app, asks a question in their language about the lecture. Gemma answers, on-device. |
| 2:45–3:00 | Closing card: "$80. No internet. Any classroom. LocalLearning." |

## Build plan (14 days)

| Days | Milestone |
|------|-----------|
| 1–2 | Pi server skeleton: FastAPI + audio capture loop + whisper.cpp wrapper streaming finalized English sentences. |
| 3–4 | Gemma translation pipeline: llama.cpp wrapper, per-language SSE streams, multi-language fan-out. |
| 5–6 | Student PWA: QR join, language picker, live captions, confusion tap. |
| 7–8 | Study pack generator + bundle download API. |
| 9–11 | Android app: bundle download, MediaPipe LLM integration, Q&A UI. |
| 12 | End-to-end test on real Pi 5 + real Android phone. Tune. |
| 13 | Demo video filming + edit. |
| 14 | Kaggle writeup, polish, submit. |

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Pi can't keep up with translation when 4+ students join at once | Cache translations of identical chunks; cap simultaneous languages at 4; degrade gracefully (queue with visible "translating…" indicator). |
| MediaPipe LiteRT integration on Android takes longer than expected | Fallback: ship Android app with bundle viewer + study-pack reader only; mark Q&A as "live demo on Pi" instead of on-device. Decide by Day 10. |
| Whisper + Gemma fight for CPU | Whisper runs continuously; Gemma translation runs in a single worker thread on a separate core. Pi 5 has 4 cores. Pin processes. |
| Demo audio quality (mic, room noise) | Test with USB lavalier mic before filming. Voice activity detection in whisper helps. |
| Real refugee-center filming logistics | If unable to film in a real location, use a school classroom + diverse student stand-ins; framing carries the message. |

## Out of scope (YAGNI)

- iOS app (Android-first, iOS is post-deadline)
- During-class live Q&A (was rejected; would steal Pi cycles from translation)
- Whisper multilingual model (English-only source for v1)
- Cloud sync, accounts, multi-classroom federation
- Teacher dashboard with analytics
- Custom Gemma fine-tuning (use stock instruction-tuned weights)

## Prize-track positioning

- **Main track** — overall vision and execution.
- **Future of Education Impact** — multi-tool agent (transcribe + translate + study pack + Q&A) that adapts to the individual student.
- **Digital Equity & Inclusivity Impact** — linguistic diversity, refugee context, $80 price point.
- **llama.cpp special prize** — Gemma running on Pi 5 via llama.cpp on resource-constrained hardware.
- **LiteRT special prize** — Gemma on Android via MediaPipe LiteRT.

A single project can win one main + one special prize, so this is positioned to be eligible for as many prize buckets as plausible while keeping a single coherent narrative.
