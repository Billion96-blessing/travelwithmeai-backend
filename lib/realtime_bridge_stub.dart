import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'api_config.dart';

typedef RealtimeEventCallback = void Function(String rawEvent);

class RealtimeBridge {
  static const _channel = MethodChannel('travelbuddy_ai/native');

  HttpClient? _client;
  RealtimeEventCallback? _lastCallback;
  RealtimeEventCallback? _goalCallback;
  String _lastGoal = '';
  bool _active = false;
  bool _muted = false;
  bool _recordingTurn = false;
  bool _busy = false;
  Timer? _turnRecordingTimer;
  Timer? _autoListenTimer;
  final List<Map<String, String>> _conversation = [];

  void start(String goal, RealtimeEventCallback onEvent) {
    _lastCallback = onEvent;
    _lastGoal = goal;
    _active = true;
    _muted = false;
    _recordingTurn = false;
    _turnRecordingTimer?.cancel();
    _autoListenTimer?.cancel();
    _conversation.clear();
    _startVoiceSession(goal, onEvent);
  }

  void stop() {
    _active = false;
    _muted = false;
    _busy = false;
    _recordingTurn = false;
    _turnRecordingTimer?.cancel();
    _autoListenTimer?.cancel();
    _client?.close(force: true);
    _client = null;
    _channel
        .invokeMethod<bool>('cancelVoiceRecording')
        .catchError((_) => false);
    _channel.invokeMethod<bool>('stopPlayback').catchError((_) => false);
    _emit(_lastCallback, 'status', {'message': 'Stopped'});
  }

  void approve() {
    _emit(_lastCallback, 'approved', {
      'message':
          'Approved. AI will confirm only after your approval and save the final note.',
    });
  }

  void setMuted(bool muted) {
    _muted = muted;
    if (muted && _recordingTurn) {
      _recordingTurn = false;
      _turnRecordingTimer?.cancel();
      _channel
          .invokeMethod<bool>('cancelVoiceRecording')
          .catchError((_) => false);
    }
    if (muted) _autoListenTimer?.cancel();
    _emit(_lastCallback, 'status', {
      'message': muted ? 'Muted' : 'Listening',
    });
  }

  void toggleVoiceTurn(String goal, RealtimeEventCallback onEvent) {
    _lastCallback = onEvent;
    if (!_active) {
      start(goal, onEvent);
      return;
    }

    if (_muted) {
      setMuted(false);
      return;
    }

    if (_busy) {
      _emit(onEvent, 'status', {'message': 'AI Thinking'});
      return;
    }

    if (_recordingTurn) {
      _turnRecordingTimer?.cancel();
      _finishVoiceTurn(onEvent);
    } else {
      _startVoiceTurnRecording(onEvent);
    }
  }

  void startGoalSpeech(RealtimeEventCallback onEvent) {
    _goalCallback = onEvent;
    _startGoalRecording(onEvent);
  }

  void stopGoalSpeech() {
    final callback = _goalCallback;
    if (callback != null) {
      _finishGoalRecording(callback);
    }
  }

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

  Future<void> _startVoiceSession(
    String goal,
    RealtimeEventCallback onEvent,
  ) async {
    _emit(onEvent, 'voice_log', {'message': 'mic permission requested'});
    _emit(onEvent, 'status', {'message': 'Permission needed'});
    final granted = await _requestMicrophonePermission(onEvent, quiet: true);
    if (!granted) {
      _emit(onEvent, 'permission_denied', {
        'message': 'Permission needed. Please allow microphone access.',
      });
      return;
    }

    _emit(onEvent, 'voice_log', {'message': 'mic permission granted'});
    _emit(onEvent, 'backend_status', {
      'connected': false,
      'microphonePermission': true,
      'realtimeReady': false,
      'backendBaseUrl': ApiConfig.backendBaseUrl,
    });

    final backendReady = await _checkCloudBackend(
      onEvent,
      microphonePermission: true,
    );
    if (!backendReady) return;

    try {
      _busy = true;
      _emit(onEvent, 'status', {'message': 'AI Thinking'});
      final data = await _postJson(
          '/api/voice-start',
          {
            'goal': goal,
          },
          timeout: const Duration(seconds: 45));
      _emit(onEvent, 'backend_status', {
        'connected': true,
        'microphonePermission': true,
        'realtimeReady': true,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      await _emitVoiceResponse(onEvent, data, providerWasSpoken: false);
      _emit(onEvent, 'status', {'message': 'Listening'});
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'Voice startup had a problem. Please try again.',
      });
      _emit(onEvent, 'voice_log', {'message': 'voice startup failed: $error'});
      await _sendAiTextReply(goal, onEvent);
    } finally {
      _busy = false;
      _scheduleAutoListen(onEvent);
    }
  }

  Future<void> _startVoiceTurnRecording(RealtimeEventCallback onEvent) async {
    final granted = await _requestMicrophonePermission(onEvent, quiet: true);
    if (!granted) {
      _emit(onEvent, 'permission_denied', {
        'message': 'Permission needed. Please allow microphone access.',
      });
      return;
    }

    try {
      await _channel
          .invokeMethod<bool>('startVoiceRecording')
          .timeout(const Duration(seconds: 6));
      _recordingTurn = true;
      _emit(onEvent, 'recording_started', {
        'message': 'Listening. Speak now.',
      });
      _emit(onEvent, 'provider_speaking', {
        'message': 'Recording provider speech...',
      });
      _emit(onEvent, 'voice_log', {'message': 'recording started'});
      _turnRecordingTimer?.cancel();
      _turnRecordingTimer = Timer(const Duration(seconds: 7), () {
        if (_active && !_muted && _recordingTurn && !_busy) {
          _finishVoiceTurn(onEvent);
        }
      });
    } catch (error) {
      _recordingTurn = false;
      _emit(onEvent, 'error', {
        'message': 'Could not start Android microphone recording.',
      });
      _emit(
          onEvent, 'voice_log', {'message': 'recording start failed: $error'});
    }
  }

  Future<void> _finishVoiceTurn(RealtimeEventCallback onEvent) async {
    try {
      _busy = true;
      _recordingTurn = false;
      _turnRecordingTimer?.cancel();
      _emit(onEvent, 'recording_stopped', {
        'message': 'Recording stopped.',
      });
      final result = await _channel
          .invokeMapMethod<String, Object?>('stopVoiceRecording')
          .timeout(const Duration(seconds: 8));
      final audioBase64 = result?['audioBase64']?.toString() ?? '';
      final mimeType = result?['mimeType']?.toString() ?? 'audio/mp4';
      final bytes = result?['bytes']?.toString() ?? '0';
      final durationMs = result?['durationMs']?.toString() ?? '0';
      final headerHex = result?['headerHex']?.toString() ?? '';
      _emit(onEvent, 'audio_sent', {
        'message': 'Audio sent. AI is listening.',
        'bytes': bytes,
        'durationMs': durationMs,
      });
      _emit(onEvent, 'status', {'message': 'AI Thinking'});
      _emit(onEvent, 'voice_log', {
        'message':
            'recorded audio bytes=$bytes durationMs=$durationMs mime=$mimeType header=$headerHex',
      });

      final data = await _postJson(
          '/api/voice-turn',
          {
            'goal': _lastGoal,
            'audioBase64': audioBase64,
            'audioMimeType': mimeType,
            'conversation': _conversation,
          },
          timeout: const Duration(seconds: 55));

      await _emitVoiceResponse(onEvent, data, providerWasSpoken: true);
      _emit(onEvent, 'status', {'message': 'Listening'});
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'I could not process that voice turn. Please try again.',
      });
      _emit(onEvent, 'voice_log', {'message': 'voice turn failed: $error'});
    } finally {
      _busy = false;
      _scheduleAutoListen(onEvent);
    }
  }

  void _scheduleAutoListen(RealtimeEventCallback onEvent) {
    _autoListenTimer?.cancel();
    if (!_active || _muted || _recordingTurn || _busy) return;
    _autoListenTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_active || _muted || _recordingTurn || _busy) return;
      _startVoiceTurnRecording(onEvent);
    });
  }

  Future<void> _startGoalRecording(RealtimeEventCallback onEvent) async {
    final granted = await _requestMicrophonePermission(onEvent, quiet: true);
    if (!granted) {
      _emit(onEvent, 'permission_denied', {
        'message': 'Permission needed. Please allow microphone access.',
      });
      return;
    }

    try {
      await _channel
          .invokeMethod<bool>('startVoiceRecording')
          .timeout(const Duration(seconds: 6));
      _emit(onEvent, 'goal_speech_status', {
        'message': 'Recording your travel goal. Press stop when done.',
      });
      _emit(onEvent, 'voice_log', {'message': 'goal recording started'});
    } catch (error) {
      _emit(onEvent, 'goal_speech_error', {
        'message': 'Could not start Android microphone recording.',
      });
      _emit(onEvent, 'voice_log', {'message': 'goal recording failed: $error'});
    }
  }

  Future<void> _finishGoalRecording(RealtimeEventCallback onEvent) async {
    try {
      _emit(onEvent, 'goal_speech_status', {
        'message': 'Processing voice goal...',
      });
      final result = await _channel
          .invokeMapMethod<String, Object?>('stopVoiceRecording')
          .timeout(const Duration(seconds: 8));
      final data = await _postJson(
          '/api/voice-goal',
          {
            'audioBase64': result?['audioBase64']?.toString() ?? '',
            'audioMimeType': result?['mimeType']?.toString() ?? 'audio/mp4',
            'userLanguage': 'English',
          },
          timeout: const Duration(seconds: 45));
      _emit(onEvent, 'goal_speech_result', {
        'transcript': data['transcript'],
        'destination': data['destination'],
        'activity': data['activity'],
        'people': data['people'],
        'budget': data['budget'],
        'notes': data['notes'],
      });
      _emit(onEvent, 'voice_log', {'message': 'goal speech parsed'});
    } catch (error) {
      _emit(onEvent, 'goal_speech_error', {
        'message': 'Could not process your voice goal.',
      });
      _emit(
          onEvent, 'voice_log', {'message': 'goal processing failed: $error'});
    }
  }

  Future<bool> _checkCloudBackend(
    RealtimeEventCallback onEvent, {
    bool microphonePermission = false,
  }) async {
    _emit(onEvent, 'status', {
      'message': 'Connecting...',
    });
    _emit(onEvent, 'backend_status', {
      'connected': false,
      'microphonePermission': microphonePermission,
      'realtimeReady': false,
      'backendBaseUrl': ApiConfig.backendBaseUrl,
    });

    try {
      final request = await _httpClient
          .getUrl(ApiConfig.endpoint('/api/health'))
          .timeout(const Duration(seconds: 12));
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      final body = await utf8.decodeStream(response);
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final connected = response.statusCode >= 200 && response.statusCode < 300;
      final realtimeReady = connected &&
          payload['hasOpenAIKey'] == true &&
          (payload['voiceReady'] == true || payload['hasOpenAIKey'] == true);

      _emit(onEvent, 'backend_status', {
        'connected': connected,
        'microphonePermission': microphonePermission,
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
            ? 'Backend health OK. Voice ready: $realtimeReady.'
            : 'Backend health failed with ${response.statusCode}.',
      });
      _emit(onEvent, 'voice_log', {
        'message': connected ? 'backend health ok' : 'backend health failed',
      });
      return connected && realtimeReady;
    } catch (error) {
      _emit(onEvent, 'backend_status', {
        'connected': false,
        'microphonePermission': microphonePermission,
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
      _emit(onEvent, 'voice_log', {'message': 'backend health failed: $error'});
      return false;
    }
  }

  Future<void> _sendAiTextReply(
    String prompt,
    RealtimeEventCallback onEvent, {
    bool debugEvent = false,
  }) async {
    try {
      final data = await _postJson(
          '/api/assistant',
          {
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
          },
          timeout: const Duration(seconds: 24));

      final reply = data['reply']?.toString().trim() ?? '';
      _emit(onEvent, 'backend_status', {
        'connected': true,
        'microphonePermission': true,
        'realtimeReady': false,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      _emit(onEvent, 'ai_delta', {
        'text': reply,
        'transcript': reply,
      });
      _emit(onEvent, 'ai_translation', {
        'text': reply,
        'translation':
            'Voice is reconnecting. You can continue with this text reply.',
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

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request =
        await _httpClient.postUrl(ApiConfig.endpoint(path)).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decodeStream(response);
    final data = body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        data['error']?.toString() ?? 'Request failed.',
        uri: ApiConfig.endpoint(path),
      );
    }

    _emit(_lastCallback, 'voice_log', {
      'message':
          'upload success path=$path status=${response.statusCode} responseBytes=${body.length}',
    });
    return data;
  }

  Future<void> _emitVoiceResponse(
    RealtimeEventCallback onEvent,
    Map<String, dynamic> data, {
    required bool providerWasSpoken,
  }) async {
    final providerTranscript = data['providerTranscript']?.toString() ?? '';
    final providerTranslation = data['providerTranslation']?.toString() ?? '';
    final aiReply = data['aiReply']?.toString().trim() ?? '';
    final aiTranslation = data['aiTranslation']?.toString().trim() ?? '';
    final audioBase64 = data['audioBase64']?.toString() ?? '';
    final audioMimeType = data['audioMimeType']?.toString() ?? 'audio/mpeg';
    final audioByteLength = data['audioByteLength']?.toString() ?? '';
    final audioHeaderHex = data['audioHeaderHex']?.toString() ?? '';

    if (providerWasSpoken && providerTranscript.isNotEmpty) {
      _conversation.add({
        'speaker': 'provider',
        'text': providerTranscript,
      });
      _emit(onEvent, 'provider_transcript', {
        'text': providerTranscript,
        'translation': providerTranslation,
      });
    }

    if (aiReply.isNotEmpty) {
      _conversation.add({
        'speaker': 'ai',
        'text': aiReply,
      });
      _emit(onEvent, 'ai_delta', {
        'text': aiReply,
        'transcript': aiReply,
      });
      _emit(onEvent, 'ai_translation', {
        'text': aiReply,
        'translation': aiTranslation,
      });
      _emit(onEvent, 'voice_log', {
        'message': 'AI text generated: ${aiReply.length} chars',
      });
    }

    if (data['needsUserApproval'] == true) {
      _emit(onEvent, 'approval_needed', {
        'message': 'Do you approve this deal?',
        'finalNote': data['finalNote'],
      });
    }

    if (audioBase64.isNotEmpty) {
      _emit(onEvent, 'voice_log', {
        'message':
            'AI audio received mime=$audioMimeType bytes=$audioByteLength header=$audioHeaderHex base64Length=${audioBase64.length}',
      });
      _emit(onEvent, 'audio_playback_started', {
        'message': 'AI voice playback started.',
      });
      await _playAudioBase64(audioBase64, audioMimeType, onEvent);
      _emit(onEvent, 'audio_playback_ended', {
        'message': 'AI voice playback ended.',
      });
    } else {
      _emit(onEvent, 'error', {
        'message': 'AI answered with text, but voice audio was not returned.',
      });
    }

    if (aiReply.isNotEmpty) {
      _emit(onEvent, 'ai_turn_done', {'text': aiReply});
    }
  }

  Future<void> _playAudioBase64(
    String audioBase64,
    String mimeType,
    RealtimeEventCallback onEvent,
  ) async {
    try {
      await _channel.invokeMethod<bool>('playAudioBase64', {
        'audioBase64': audioBase64,
        'mimeType': mimeType,
        'fallbackText':
            _conversation.isNotEmpty ? _conversation.last['text'] ?? '' : '',
      }).timeout(const Duration(seconds: 70));
      _emit(onEvent, 'voice_log', {'message': 'audio playback completed'});
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'Voice playback had a problem. Please try again.',
      });
      _emit(onEvent, 'voice_log', {'message': 'playback failed: $error'});
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
      _emit(onEvent, 'voice_log', {'message': 'mic permission failed: $error'});
      return false;
    }
  }

  HttpClient get _httpClient {
    final existing = _client;
    if (existing != null) return existing;
    final next = HttpClient()
      ..connectionTimeout = const Duration(seconds: 14)
      ..idleTimeout = const Duration(seconds: 20);
    _client = next;
    return next;
  }

  void _emit(
    RealtimeEventCallback? onEvent,
    String type,
    Map<String, Object?> payload,
  ) {
    onEvent?.call(jsonEncode({'type': type, ...payload}));
  }
}
