import 'dart:js_interop';

typedef RealtimeEventCallback = void Function(String rawEvent);

@JS('startFlutterRealtimeNegotiator')
external void startFlutterRealtimeNegotiator(JSString goal, JSExportedDartFunction onEvent);

@JS('stopFlutterRealtimeNegotiator')
external void stopFlutterRealtimeNegotiator();

@JS('approveFlutterRealtimeDeal')
external void approveFlutterRealtimeDeal();

@JS('setFlutterRealtimeMuted')
external void setFlutterRealtimeMuted(JSBoolean muted);

@JS('startFlutterGoalSpeech')
external void startFlutterGoalSpeech(JSExportedDartFunction onEvent);

@JS('stopFlutterGoalSpeech')
external void stopFlutterGoalSpeech();

class RealtimeBridge {
  JSExportedDartFunction? _callback;
  JSExportedDartFunction? _goalCallback;

  void start(String goal, RealtimeEventCallback onEvent) {
    _callback = ((JSString rawEvent) {
      onEvent(rawEvent.toDart);
    }).toJS;

    startFlutterRealtimeNegotiator(goal.toJS, _callback!);
  }

  void stop() {
    stopFlutterRealtimeNegotiator();
  }

  void approve() {
    approveFlutterRealtimeDeal();
  }

  void setMuted(bool muted) {
    setFlutterRealtimeMuted(muted.toJS);
  }

  void startGoalSpeech(RealtimeEventCallback onEvent) {
    _goalCallback = ((JSString rawEvent) {
      onEvent(rawEvent.toDart);
    }).toJS;

    startFlutterGoalSpeech(_goalCallback!);
  }

  void stopGoalSpeech() {
    stopFlutterGoalSpeech();
  }
}
