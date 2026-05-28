class FirebaseAuthStructure {
  const FirebaseAuthStructure._();

  static const setupSteps = [
    'Create a Firebase project.',
    'Enable Google, Apple, and Email/Password providers in Firebase Authentication.',
    'Run flutterfire configure to generate firebase_options.dart.',
    'Add firebase_core, firebase_auth, google_sign_in, and sign_in_with_apple.',
    'Replace TravelBuddyAuth stub methods with FirebaseAuth provider calls.',
  ];
}
