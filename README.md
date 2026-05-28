# Voice Negotiator

Flutter frontend for Real-Time Voice Negotiator Mode.

## Current Chrome-first build

This version intentionally removes native microphone and audio playback packages so the app can compile and run on Chrome first.

The UI includes:

- Private negotiation goal
- Start / Stop
- Simulated Thai provider speech input
- AI Thai response placeholder
- English summary
- User approval step
- Trip Notes

## Target Architecture

- Flutter app captures microphone audio later.
- Flutter sends base64 PCM audio to the Node.js backend over `ws://localhost:3000/ws/negotiator` later.
- Node.js connects to OpenAI Realtime API with the private API key.
- OpenAI responds with Thai voice audio and text events later.
- Flutter plays Thai voice responses, shows an English user summary, asks for approval, and saves Trip Notes.

The OpenAI API key stays only in the Node.js backend `.env` file.

## Run Backend

From `ai-assistant-app`:

```bash
node server.js
```

No OpenAI key belongs in Flutter. Put `OPENAI_API_KEY=...` in the backend `.env` file.

## Run Flutter

From this folder:

```bash
flutter pub get
flutter run
```

For iOS Simulator, use `ws://127.0.0.1:3000/ws/negotiator`.
For Android Emulator, use `ws://10.0.2.2:3000/ws/negotiator`.
