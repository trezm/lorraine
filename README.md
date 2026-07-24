# Lorraine

Lorraine is a local-first Flutter meeting recorder for macOS. It captures the Mac's system audio and microphone into one retained recording, submits that recording to a private Modal job running WhisperX, and stores the returned speaker-labelled transcript locally.

It also keeps a normalized voice embedding and a short WAV sample for every anonymous speaker. A user can identify an unknown voice with a name and email; embeddings from future meetings are compared with the local profile list during transcription. Optional summaries run against Gemma through a local Ollama server.

## What works

- macOS 15+ system audio and microphone capture via ScreenCaptureKit
- durable local M4A recordings and JSON-backed meeting history
- asynchronous Modal upload, processing, polling, retry, and failure states
- transcription-optimized audio with checksummed, retriable chunk uploads
- automatic idempotent Modal deployment on app startup through the authenticated CLI
- WhisperX large-v3 transcription, alignment, and pyannote diarization on an A10G GPU
- anonymous speaker labels, short voice samples, and normalized speaker embeddings
- cosine-similarity matching against user-identified local voice profiles
- local Markdown meeting summaries using Ollama (default model: `gemma3:4b`)

The Flutter shell is generated for Windows and Linux as well, but recording is deliberately reported as unsupported there until equivalent WASAPI/PipeWire loopback bridges are added.

## Run the app

Requirements:

- Flutter 3.41 or newer
- Xcode with macOS 15 SDK or newer
- macOS microphone and Screen Recording permission

```sh
flutter pub get
flutter run -d macos
```

On first recording, macOS asks for Screen Recording and microphone permission. Lorraine does not capture or save video; Screen Recording permission is required by ScreenCaptureKit to receive system audio.

## Deploy transcription

Follow the one-time authentication and secret setup in [backend/README.md](backend/README.md). On each startup, Lorraine runs `modal token info` followed by an idempotent `modal deploy`, discovers and health-checks the `modal.run` URL, and stores it in Settings. Modal treats unchanged deployments as no-ops. Settings also provides deployment status, a manual URL fallback, and a **Deploy now** retry.

Recordings remain on the Mac. The backend deletes its uploaded copy after successful transcription while retaining the JSON job result in its Modal Volume.

## Enable local Gemma summaries

Install [Ollama](https://ollama.com), then run:

```sh
ollama pull gemma3:4b
ollama serve
```

The defaults in Settings point to `http://localhost:11434` and `gemma3:4b`. Summary requests never leave the local Ollama server.

## Data and privacy

Meeting recordings, transcripts, voice embeddings, samples, settings, and the configured API key are stored under the platform application-support directory. This MVP does not encrypt those files. Voice embeddings may be biometric data, so production deployment should add encrypted-at-rest storage, profile deletion/export, retention controls, consent UX, and organization-specific legal review.

Speaker recognition is probabilistic. The default cosine threshold is `0.72` and can be adjusted in Settings. A match is a suggestion, not proof of identity. Overlapping speakers and poor-quality system audio can also reduce WhisperX diarization accuracy.

## Verify

```sh
flutter analyze
flutter test
python3 -m py_compile backend/modal_app.py
flutter build macos
```

The last command requires a complete Xcode installation and CocoaPods.

## Project map

- `lib/app_controller.dart` — recording, job polling, identity, and summary workflow
- `lib/repository.dart` — local meeting/profile persistence and media locations
- `lib/services.dart` — Modal CLI startup deployment, API client, capture channel, and Ollama client
- `macos/Runner/MeetingAudioCapture.swift` — ScreenCaptureKit capture and AVFoundation mixdown
- `backend/modal_app.py` — asynchronous FastAPI + Modal + WhisperX service
