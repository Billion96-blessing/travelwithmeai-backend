import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'api_config.dart';

typedef RealtimeEventCallback = void Function(String rawEvent);

class RealtimeBridge {
  static const _channel = MethodChannel('travelbuddy_ai/native');

  HttpClient? _client;
  RealtimeEventCallback? _lastCallback;

  void start(String goal, RealtimeEventCallback onEvent) {
    _lastCallback = onEvent;
    _startHttpFallback(goal, onEvent);
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
    _requestMicrophonePermission(onEvent);
  }

  void stopGoalSpeech() {}

  void testBackend(RealtimeEventCallback onEvent) {
    _checkCloudBackend(onEvent);
  }

  void testAiTextReply(RealtimeEventCallback onEvent) {
    _sendAiTextReply(
      'Reply with one short friendly sentence: TravelBuddy AI backend is working.',
      onEvent,
      debugEvent: true,
    );
  }

  Future<void> _checkCloudBackend(RealtimeEventCallback onEvent) async {
    _emit(onEvent, 'status', {
      'message': 'Connecting...',
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
                ? 'Connected'
                : 'Connected, but AI key is not ready on backend.'
            : 'Cloud backend returned status ${response.statusCode}.',
      });
      _emit(onEvent, 'debug_result', {
        'name': 'Backend health',
        'ok': connected,
        'message': connected
            ? 'Backend health OK. OpenAI key ready: $realtimeReady.'
            : 'Backend health failed with ${response.statusCode}.',
      });
      return;
    } catch (error) {
      _emit(onEvent, 'backend_status', {
        'connected': false,
        'microphonePermission': false,
        'realtimeReady': false,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      _emit(onEvent, 'error', {
        'message': 'Offline. Could not reach backend.',
      });
      _emit(onEvent, 'debug_result', {
        'name': 'Backend health',
        'ok': false,
        'message': 'Could not reach backend: $error',
      });
    }
  }

  Future<void> _startHttpFallback(
    String goal,
    RealtimeEventCallback onEvent,
  ) async {
    _emit(onEvent, 'status', {'message': 'Connecting...'});
    _emit(onEvent, 'fallback_mode', {
      'message': 'Realtime voice unavailable on Android. Using AI text reply.',
    });
    await _requestMicrophonePermission(onEvent, quiet: true);
    await _sendAiTextReply(goal, onEvent);
  }

  Future<void> _sendAiTextReply(
    String prompt,
    RealtimeEventCallback onEvent, {
    bool debugEvent = false,
  }) async {
    try {
      _client?.close(force: true);
      _client = HttpClient();
      final request = await _client!
          .postUrl(ApiConfig.endpoint('/api/assistant'))
          .timeout(const Duration(seconds: 14));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'tone': 'short, natural, helpful',
        'messages': [
          {
            'role': 'user',
            'content': [
              'You are TravelBuddy AI beta Android fallback mode.',
              'Reply briefly and naturally.',
              'Do not confirm a final deal without user approval.',
              '',
              prompt,
            ].join('\n'),
          }
        ],
      }));

      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decodeStream(response);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final ok = response.statusCode >= 200 && response.statusCode < 300;

      if (!ok) {
        final message = data['error']?.toString() ?? 'AI text reply failed.';
        _emit(onEvent, 'error', {'message': message});
        if (debugEvent) {
          _emit(onEvent, 'debug_result', {
            'name': 'AI text reply',
            'ok': false,
            'message': message,
          });
        }
        return;
      }

      final reply = data['reply']?.toString().trim() ?? '';
      _emit(onEvent, 'backend_status', {
        'connected': true,
        'microphonePermission': false,
        'realtimeReady': false,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      _emit(onEvent, 'ai_delta', {
        'text': reply,
        'transcript': reply,
      });
      _emit(onEvent, 'ai_translation', {
        'text': reply,
        'translation': 'Android fallback text mode. Realtime voice comes next.',
      });
      _emit(onEvent, 'ai_turn_done', {'text': reply});
      _emit(onEvent, 'status', {'message': 'Connected'});

      if (debugEvent) {
        _emit(onEvent, 'debug_result', {
          'name': 'AI text reply',
          'ok': true,
          'message': reply.isEmpty ? 'AI replied with empty text.' : reply,
        });
      }
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'AI text request timed out or failed.',
      });
      if (debugEvent) {
        _emit(onEvent, 'debug_result', {
          'name': 'AI text reply',
          'ok': false,
          'message': '$error',
        });
      }
    }
  }

  Future<bool> _requestMicrophonePermission(
    RealtimeEventCallback onEvent, {
    bool quiet = false,
  }) async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestMicrophonePermission') ??
              false;
      _emit(onEvent, 'backend_status', {
        'connected': false,
        'microphonePermission': granted,
        'realtimeReady': false,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      if (!quiet) {
        _emit(onEvent, granted ? 'goal_speech_status' : 'permission_denied', {
          'message': granted
              ? 'Microphone permission granted.'
              : 'Permission needed. Please allow microphone access.',
        });
      }
      return granted;
    } catch (error) {
      if (!quiet) {
        _emit(onEvent, 'permission_denied', {
          'message': 'Permission needed. Could not open microphone prompt.',
        });
      }
      return false;
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
