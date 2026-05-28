# TravelBuddy AI Production Release Checklist

## Android Identity

- Package name: `com.travelwithmeai.app`
- Release version: `1.0.0+2`
- Backend URL: `https://travelwithmeai-server.onrender.com`
- Future custom API domain: `https://api.travelwithmeai.com`

## Release Signing

Create an upload keystore locally and never commit it:

```bash
keytool -genkey -v -keystore android/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias travelwithmeai
cp android/key.properties.example android/key.properties
```

Then edit `android/key.properties` with the real passwords. `android/key.properties` and `*.jks` are ignored by git.

## Play Store Build

```bash
flutter build appbundle --release --dart-define=TRAVELWITHMEAI_API_BASE_URL=https://travelwithmeai-server.onrender.com
```

Upload `build/app/outputs/bundle/release/app-release.aab` to Play Console.

## Security

- Do not put `OPENAI_API_KEY` in Flutter.
- Store `OPENAI_API_KEY` only in Render environment variables.
- Keep cleartext traffic disabled on Android.
- Set backend `ALLOWED_ORIGINS` before public launch.
- Test microphone permission prompts on a physical Android device.
