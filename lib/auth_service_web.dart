import 'dart:js_interop';

import 'auth_service.dart';

@JS('startTravelBuddyGoogleLogin')
external void startTravelBuddyGoogleLogin();

TravelBuddyAuth createPlatformAuthService() => const WebAuthService();

class WebAuthService implements TravelBuddyAuth {
  const WebAuthService();

  @override
  Future<AuthResult> signInWithGoogle() async {
    startTravelBuddyGoogleLogin();
    return const AuthResult(ok: true, message: 'Opened Google login. Firebase Auth config can complete this flow.');
  }

  @override
  Future<AuthResult> signInWithApple() async {
    return const AuthResult(ok: true, message: 'Apple login is prepared for Firebase Auth.');
  }

  @override
  Future<AuthResult> createAccount() async {
    return const AuthResult(ok: true, message: 'Create account is prepared for Firebase Auth.');
  }

  @override
  Future<AuthResult> signInWithEmail() async {
    return const AuthResult(ok: true, message: 'Email login is prepared for Firebase Auth.');
  }
}
