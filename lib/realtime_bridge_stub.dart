import 'dart:convert';
import 'dart:io';

import 'api_config.dart';

typedef RealtimeEventCallback = void Function(String rawEvent);

class RealtimeBridge {
  HttpClient? _client;
  RealtimeEventCallback? _lastCallback;

  void start(String goal, RealtimeEventCallback onEvent) {
    _lastCallback = onEvent;
    _checkCloudBackend(onEvent);
  }

  void stop() {
    _client?.close(force: true);
    _client = null;
    _emit(_lastCallback, 'status', {'message': 'Stopped'});
  }

  void approve() {
    _emit(_lastCallback, 'approved', {
      'message':
          'Approved locally. Cloud backend is ready; native realtime voice confirmation is the next mobile bridge step.',
    });
  }

  void setMuted(bool muted) {
    _emit(_lastCallback, 'status', {'message': muted ? 'Muted' : 'Listening'});
  }

  void startGoalSpeech(RealtimeEventCallback onEvent) {
    _lastCallback = onEvent;
    _emit(onEvent, 'goal_speech_error', {
      'message':
          'Android microphone UI is ready. Native speech-to-text will be connected after the cloud backend deploy is live.',
    });
    _emit(onEvent, 'backend_status', {
      'connected': false,
      'microphonePermission': false,
      'realtimeReady': false,
      'backendBaseUrl': ApiConfig.backendBaseUrl,
    });
  }

  void stopGoalSpeech() {}

  Future<void> _checkCloudBackend(RealtimeEventCallback onEvent) async {
    _emit(onEvent, 'status', {
      'message': 'Checking cloud backend at ${ApiConfig.backendBaseUrl}...',
    });
    _emit(onEvent, 'backend_status', {
      'connected': false,
      'microphonePermission': false,
      'realtimeReady': false,
      'backendBaseUrl': ApiConfig.backendBaseUrl,
    });

    try {
      _client?.close(force: true);
      _client = HttpClient();
      final request = await _client!
          .getUrl(ApiConfig.endpoint('/api/health'))
          .timeout(const Duration(seconds: 12));
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      final body = await utf8.decodeStream(response);
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final connected = response.statusCode >= 200 && response.statusCode < 300;
      final realtimeReady = connected && payload['hasOpenAIKey'] == true;

      _emit(onEvent, 'backend_status', {
        'connected': connected,
        'microphonePermission': false,
        'realtimeReady': realtimeReady,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      _emit(onEvent, connected ? 'status' : 'error', {
        'message': connected
            ? realtimeReady
                ? 'Cloud backend connected. Realtime API key is ready.'
                : 'Cloud backend connected, but OPENAI_API_KEY is not set on Render yet.'
            : 'Cloud backend returned status ${response.statusCode}.',
      });
    } catch (error) {
      _emit(onEvent, 'backend_status', {
        'connected': false,
        'microphonePermission': false,
        'realtimeReady': false,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      _emit(onEvent, 'error', {
        'message':
            'Could not reach cloud backend at ${ApiConfig.backendBaseUrl}. Deploy Render first, then test again.',
      });
    }
  }

  void _emit(
    RealtimeEventCallback? onEvent,
    String type,
    Map<String, Object?> payload,
  ) {
    onEvent?.call(jsonEncode({'type': type, ...payload}));
  }
}
