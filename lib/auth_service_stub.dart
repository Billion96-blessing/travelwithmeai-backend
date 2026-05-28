import 'auth_service.dart';

TravelBuddyAuth createPlatformAuthService() => const StubAuthService();

class StubAuthService implements TravelBuddyAuth {
  const StubAuthService();

  @override
  Future<AuthResult> signInWithGoogle() async {
    return const AuthResult(ok: true, message: 'Google login is ready for Firebase configuration.');
  }

  @override
  Future<AuthResult> signInWithApple() async {
    return const AuthResult(ok: true, message: 'Apple login is ready for Firebase configuration.');
  }

  @override
  Future<AuthResult> createAccount() async {
    return const AuthResult(ok: true, message: 'Account signup screen can be connected to Firebase Auth.');
  }

  @override
  Future<AuthResult> signInWithEmail() async {
    return const AuthResult(ok: true, message: 'Email login screen can be connected to Firebase Auth.');
  }
}
