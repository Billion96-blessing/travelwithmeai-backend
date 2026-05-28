typedef RealtimeEventCallback = void Function(String rawEvent);

class RealtimeBridge {
  void start(String goal, RealtimeEventCallback onEvent) {
    onEvent(
      '{"type":"error","message":"Realtime voice is available when running this app in Chrome."}',
    );
  }

  void stop() {}

  void approve() {}

  void setMuted(bool muted) {}

  void startGoalSpeech(RealtimeEventCallback onEvent) {
    onEvent(
      '{"type":"goal_speech_error","message":"Voice goal input is available in Chrome or the mobile app microphone bridge."}',
    );
  }

  void stopGoalSpeech() {}
}
