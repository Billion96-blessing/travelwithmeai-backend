import 'auth_service_stub.dart' if (dart.library.js_interop) 'auth_service_web.dart';

class AuthResult {
  const AuthResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

abstract class TravelBuddyAuth {
  Future<AuthResult> signInWithGoogle();
  Future<AuthResult> signInWithApple();
  Future<AuthResult> createAccount();
  Future<AuthResult> signInWithEmail();
}

TravelBuddyAuth createAuthService() => createPlatformAuthService();
