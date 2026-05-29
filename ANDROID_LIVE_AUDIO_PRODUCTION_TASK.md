# Android Live Audio Production Task

Owner: Antigravity/Codex worker

Status: Active blocker

## Problem

The web prototype handles realtime voice more smoothly than Android. The Android app still behaves like a fallback speech-to-text/text-to-speech demo:

- Voice playback frequently fails.
- AI sometimes returns text only.
- Listening does not reliably continue after AI response.
- User may need repeated tap-to-speak behavior.
- Continuous live negotiation is not stable enough for production.

## Required Result

The Android app must complete this loop on a physical Android phone:

1. User presses Start once.
2. Provider speaks.
3. AI hears and understands the provider.
4. AI replies by voice through Android speaker.
5. Playback completes.
6. App automatically resumes listening.
7. Provider speaks again.
8. The conversation continues without extra button presses.

## Investigation Scope

- Flutter live voice state machine in `lib/realtime_bridge_stub.dart` and `lib/main.dart`.
- Native Android audio capture/playback in `android/app/src/main/kotlin/com/travelwithmeai/app/MainActivity.kt`.
- Backend websocket and OpenAI Realtime bridge in the Node server.
- Audio format contract between Android, backend, and OpenAI Realtime.
- Automatic listening resume after AI playback.
- Interruption/barge-in behavior.
- Production UI removal of debug/test cards from normal user flow.

## Constraints

- Keep `OPENAI_API_KEY` only in the backend environment.
- Keep the Render backend URL unchanged: `https://travelwithmeai-server.onrender.com`.
- Do not replace realtime with fallback STT/TTS except as emergency backup.
- Do not mark production-ready without physical Android loop verification.

## Verification Required

- Confirm microphone permission and capture.
- Confirm realtime websocket connects.
- Confirm backend receives audio chunks.
- Confirm OpenAI returns audio chunks.
- Confirm Android plays audio chunks successfully.
- Confirm app returns to listening after playback.
- Confirm loop works over multiple provider/AI turns.
- Build a fresh APK and record the exact output path.
