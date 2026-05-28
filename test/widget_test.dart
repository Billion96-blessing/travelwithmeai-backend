import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_negotiator/main.dart';

void main() {
  testWidgets('shows TravelBuddy AI mobile UI', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TravelNegotiatorApp());

    expect(find.text('Welcome back'), findsOneWidget);
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    expect(find.text('Good Evening'), findsOneWidget);
    expect(find.text('Or enter details manually'), findsOneWidget);
    expect(find.text('2. Negotiation Plan'), findsOneWidget);

    await tester.ensureVisible(find.text('Start Negotiating'));
    await tester.tap(find.text('Start Negotiating'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Live'), findsWidgets);

    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(find.text('Live Negotiation'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Deal'));
    await tester.pumpAndSettle();
    expect(find.text('Deal Reached!'), findsOneWidget);
    expect(find.text('5. User Approval'), findsOneWidget);

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('6. Saved Trip Notes'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
  });
}
