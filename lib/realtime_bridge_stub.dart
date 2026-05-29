import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_config.dart';

typedef RealtimeEventCallback = void Function(String rawEvent);

class RealtimeBridge {
  static const _channel = MethodChannel('travelbuddy_ai/native');

  HttpClient? _client;
  WebSocketChannel? _realtimeSocket;
  RealtimeEventCallback? _lastCallback;
  RealtimeEventCallback? _goalCallback;
  String _lastGoal = '';
  bool _active = false;
  bool _muted = false;
  bool _busy = false;
  bool _usingRealtime = false;
  bool _realtimeConnected = false;
  bool _realtimePlaybackActive = false;
  bool _finishingRealtimePlayback = false;
  bool _fallbackRecordingTurn = false;
  int _sentChunkCount = 0;
  int _receivedAudioChunkCount = 0;
  String _liveAiTranscript = '';
  Timer? _realtimeConnectTimeout;
  Timer? _fallbackTurnRecordingTimer;
  Timer? _fallbackAutoListenTimer;
  final List<Map<String, String>> _conversation = [];

  RealtimeBridge() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  void start(String goal, RealtimeEventCallback onEvent) {
    _lastCallback = onEvent;
    _lastGoal = goal;
    _active = true;
    _muted = false;
    _busy = false;
    _usingRealtime = true;
    _realtimeConnected = false;
    _realtimePlaybackActive = false;
    _finishingRealtimePlayback = false;
    _fallbackRecordingTurn = false;
    _sentChunkCount = 0;
    _receivedAudioChunkCount = 0;
    _liveAiTranscript = '';
    _conversation.clear();
    _fallbackTurnRecordingTimer?.cancel();
    _fallbackAutoListenTimer?.cancel();
    _startRealtimeSession(goal, onEvent);
  }

  void stop() {
    _active = false;
    _muted = false;
    _busy = false;
    _usingRealtime = false;
    _realtimeConnected = false;
    _realtimePlaybackActive = false;
    _finishingRealtimePlayback = false;
    _fallbackRecordingTurn = false;
    _realtimeConnectTimeout?.cancel();
    _fallbackTurnRecordingTimer?.cancel();
    _fallbackAutoListenTimer?.cancel();
    _realtimeSocket?.sink.close();
    _realtimeSocket = null;
    _client?.close(force: true);
    _client = null;
    _channel
        .invokeMethod<bool>('stopRealtimeAudioCapture')
        .catchError((_) => false);
    _channel
        .invokeMethod<bool>('stopRealtimeAudioPlayback')
        .catchError((_) => false);
    _channel
        .invokeMethod<bool>('cancelVoiceRecording')
        .catchError((_) => false);
    _channel.invokeMethod<bool>('stopPlayback').catchError((_) => false);
    _emit(_lastCallback, 'status', {'message': 'Stopped'});
  }

  void approve() {
    if (_usingRealtime && _realtimeSocket != null) {
      _realtimeSocket!.sink.add(jsonEncode({'type': 'approve'}));
    }
    _emit(_lastCallback, 'approved', {
      'message':
          'Approved. AI will confirm only after your approval and save the final note.',
    });
  }

  void setMuted(bool muted) {
    _muted = muted;
    if (_usingRealtime) {
      if (muted) {
        _channel
            .invokeMethod<bool>('stopRealtimeAudioCapture')
            .catchError((_) => false);
      } else if (_active && _realtimeConnected && !_realtimePlaybackActive) {
        _startNativeRealtimeCapture();
      }
    } else if (muted && _fallbackRecordingTurn) {
      _fallbackRecordingTurn = false;
      _fallbackTurnRecordingTimer?.cancel();
      _channel
          .invokeMethod<bool>('cancelVoiceRecording')
          .catchError((_) => false);
    }
    if (muted) _fallbackAutoListenTimer?.cancel();
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
    if (_usingRealtime) {
      setMuted(!_muted);
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
    if (_fallbackRecordingTurn) {
      _fallbackTurnRecordingTimer?.cancel();
      _finishFallbackVoiceTurn(onEvent);
    } else {
      _startFallbackTurnRecording(onEvent);
    }
  }

  void startGoalSpeech(RealtimeEventCallback onEvent) {
    _goalCallback = onEvent;
    _startGoalRecording(onEvent);
  }

  void stopGoalSpeech() {
    final callback = _goalCallback;
    if (callback != null) _finishGoalRecording(callback);
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

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'nativeVoiceEvent') return null;
    final raw = (call.arguments as Map?) ?? const {};
    final type = raw['type']?.toString() ?? '';
    final data = (raw['data'] as Map?) ?? const {};

    switch (type) {
      case 'realtime_audio_chunk':
        _sendRealtimeAudioChunk(data);
      case 'realtime_recording_started':
        _emit(_lastCallback, 'recording_started', {
          'message': 'Listening...',
        });
        _emit(_lastCallback, 'voice_log', {
          'message': 'recording started',
        });
      case 'realtime_recording_stopped':
        _emit(_lastCallback, 'voice_log', {
          'message': 'recording stopped',
        });
      case 'realtime_playback_started':
        _emit(_lastCallback, 'audio_playback_started', {
          'message': 'AI Speaking',
        });
      case 'realtime_playback_ended':
        _emit(_lastCallback, 'voice_log', {
          'message': 'native realtime playback ended',
        });
      case 'realtime_playback_error':
        _realtimePlaybackActive = false;
        _finishingRealtimePlayback = false;
        _emit(_lastCallback, 'error', {
          'message':
              data['message']?.toString() ?? 'Realtime audio playback failed.',
        });
    }
    return null;
  }

  Future<void> _startRealtimeSession(
    String goal,
    RealtimeEventCallback onEvent,
  ) async {
    _emit(onEvent, 'status', {'message': 'Permission needed'});
    final granted = await _requestMicrophonePermission(onEvent, quiet: true);
    if (!granted) {
      _emit(onEvent, 'permission_denied', {
        'message': 'Permission needed. Please allow microphone access.',
      });
      return;
    }
    _emit(onEvent, 'voice_log', {'message': 'mic permission granted'});

    final backendReady = await _checkCloudBackend(
      onEvent,
      microphonePermission: true,
    );
    if (!backendReady || !_active) return;

    try {
      _emit(onEvent, 'status', {'message': 'Connecting...'});
      final uri = ApiConfig.websocketEndpoint('/ws/negotiator');
      final socket = WebSocketChannel.connect(uri);
      _realtimeSocket = socket;
      _emit(onEvent, 'voice_log', {
        'message': 'realtime websocket connecting',
      });

      _realtimeConnectTimeout?.cancel();
      _realtimeConnectTimeout = Timer(const Duration(seconds: 14), () {
        if (_active && _usingRealtime && !_realtimeConnected) {
          _emit(onEvent, 'error', {
            'message':
                'Realtime voice could not connect. Backup voice mode is starting.',
          });
          _startBackupVoiceMode(goal, onEvent);
        }
      });

      socket.stream.listen(
        (event) => _handleRealtimeSocketEvent(event, onEvent),
        onError: (Object error) {
          _emit(onEvent, 'voice_log', {
            'message': 'realtime websocket error: $error',
          });
          if (!_realtimeConnected) {
            _startBackupVoiceMode(goal, onEvent);
          } else {
            _emit(onEvent, 'error', {
              'message': 'Realtime connection dropped. Please try again.',
            });
          }
        },
        onDone: () {
          _emit(onEvent, 'voice_log', {
            'message': 'realtime websocket disconnected',
          });
          if (_active && _usingRealtime) {
            _emit(onEvent, 'error', {
              'message': 'Realtime connection ended.',
            });
          }
        },
        cancelOnError: false,
      );

      socket.sink.add(jsonEncode({'type': 'start', 'goal': goal}));
    } catch (error) {
      _emit(onEvent, 'voice_log', {
        'message': 'realtime startup failed: $error',
      });
      _startBackupVoiceMode(goal, onEvent);
    }
  }

  void _handleRealtimeSocketEvent(
    Object event,
    RealtimeEventCallback onEvent,
  ) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(event.toString()) as Map<String, dynamic>;
    } catch (_) {
      _emit(onEvent, 'voice_log', {
        'message': 'realtime event parse failed',
      });
      return;
    }

    final type = data['type']?.toString() ?? '';
    switch (type) {
      case 'status':
        final message = data['message']?.toString() ?? 'Realtime status';
        _emit(onEvent, 'status', {'message': message});
        if (message.toLowerCase().contains('connected') &&
            !_realtimeConnected) {
          _realtimeConnected = true;
          _realtimeConnectTimeout?.cancel();
          _emit(onEvent, 'backend_status', {
            'connected': true,
            'microphonePermission': true,
            'realtimeReady': true,
            'backendBaseUrl': ApiConfig.backendBaseUrl,
          });
          _emit(onEvent, 'voice_log', {
            'message': 'realtime session connected',
          });
          _startNativeRealtimeCapture();
        }
      case 'realtime_ready':
        _realtimeConnected = true;
        _realtimeConnectTimeout?.cancel();
        _emit(onEvent, 'backend_status', {
          'connected': true,
          'microphonePermission': true,
          'realtimeReady': true,
          'backendBaseUrl': ApiConfig.backendBaseUrl,
        });
        _emit(onEvent, 'status', {
          'message': data['message']?.toString() ?? 'Connected',
        });
        _emit(onEvent, 'voice_log', {
          'message': 'realtime session ready',
        });
        if (data['listen'] == true) _startNativeRealtimeCapture();
      case 'provider_speaking':
        _emit(onEvent, 'provider_speaking', {
          'message': data['message'] ?? 'Provider speaking...',
        });
      case 'provider_transcript':
        _emit(onEvent, 'provider_transcript', {
          'text': data['text'] ?? '',
          'translation': data['translation'] ?? '',
        });
      case 'ai_transcript_delta':
        _liveAiTranscript = '$_liveAiTranscript${data['text'] ?? ''}';
        _emit(onEvent, 'ai_delta', {
          'text': data['text'] ?? '',
          'transcript': _liveAiTranscript,
        });
      case 'audio_delta':
        final audio = data['audio']?.toString() ?? '';
        if (audio.isEmpty) return;
        if (!_realtimePlaybackActive) {
          _realtimePlaybackActive = true;
          _finishingRealtimePlayback = false;
          _receivedAudioChunkCount = 0;
          _channel
              .invokeMethod<bool>('stopRealtimeAudioCapture')
              .catchError((_) => false);
          _emit(onEvent, 'audio_playback_started', {
            'message': 'AI Speaking',
          });
          _emit(onEvent, 'status', {'message': 'AI Speaking'});
        }
        _receivedAudioChunkCount += 1;
        if (_receivedAudioChunkCount == 1 ||
            _receivedAudioChunkCount % 50 == 0) {
          _emit(onEvent, 'voice_log', {
            'message':
                'AI audio chunk received count=$_receivedAudioChunkCount',
          });
        }
        _channel.invokeMethod<bool>('playRealtimeAudioChunk', {
          'audioBase64': audio,
        }).catchError((_) => false);
      case 'ai_audio_done':
        _finishRealtimePlayback(onEvent);
      case 'response_done':
      case 'summary':
        if (_liveAiTranscript.trim().isNotEmpty) {
          _emit(onEvent, 'ai_turn_done', {'text': _liveAiTranscript.trim()});
          _liveAiTranscript = '';
        }
        if (type == 'response_done' && data['hadAudio'] == false) {
          _emit(onEvent, 'voice_log', {
            'message': 'realtime response completed without audio',
          });
        }
        if (_realtimePlaybackActive) {
          _finishRealtimePlayback(onEvent);
        } else if (_active && _usingRealtime && _realtimeConnected) {
          _returnToRealtimeListening(onEvent);
        }
      case 'returned_listening':
        _emit(onEvent, 'status', {'message': 'Listening'});
      case 'error':
        _emit(onEvent, 'error', {
          'message': data['message'] ?? 'Realtime voice error.',
        });
    }
  }

  void _sendRealtimeAudioChunk(Map<dynamic, dynamic> data) {
    if (!_active ||
        !_usingRealtime ||
        !_realtimeConnected ||
        _muted ||
        _realtimePlaybackActive ||
        _finishingRealtimePlayback) {
      return;
    }
    final audio = data['audioBase64']?.toString() ?? '';
    if (audio.isEmpty) return;
    _sentChunkCount += 1;
    if (_sentChunkCount == 1 || _sentChunkCount % 50 == 0) {
      _emit(_lastCallback, 'voice_log', {
        'message':
            'audio chunk sent count=$_sentChunkCount bytes=${data['bytes'] ?? ''}',
      });
    }
    _realtimeSocket?.sink.add(jsonEncode({'type': 'audio', 'audio': audio}));
  }

  void _finishRealtimePlayback(RealtimeEventCallback onEvent) {
    if (!_realtimePlaybackActive || _finishingRealtimePlayback) return;
    _finishingRealtimePlayback = true;
    _emit(onEvent, 'voice_log', {
      'message': 'waiting for realtime audio drain',
    });
    () async {
      try {
        await _channel
            .invokeMethod<bool>('finishRealtimeAudioPlayback')
            .timeout(const Duration(seconds: 20));
      } catch (error) {
        _emit(onEvent, 'voice_log', {
          'message': 'realtime audio drain failed: $error',
        });
        await _channel
            .invokeMethod<bool>('stopRealtimeAudioPlayback')
            .catchError((_) => false);
      }
      _realtimePlaybackActive = false;
      _finishingRealtimePlayback = false;
      _returnToRealtimeListening(onEvent);
    }();
  }

  void _returnToRealtimeListening(RealtimeEventCallback onEvent) {
    if (!_active || !_usingRealtime) return;
    _emit(onEvent, 'audio_playback_ended', {'message': 'Listening'});
    _emit(onEvent, 'status', {'message': 'Listening'});
    _emit(onEvent, 'voice_log', {
      'message': 'returned to listening',
    });
    if (!_muted) {
      _startNativeRealtimeCapture();
    }
  }

  Future<void> _startNativeRealtimeCapture() async {
    if (!_active ||
        _muted ||
        _realtimePlaybackActive ||
        _finishingRealtimePlayback) {
      return;
    }
    try {
      await _channel
          .invokeMethod<bool>('startRealtimeAudioCapture')
          .timeout(const Duration(seconds: 6));
    } catch (error) {
      _emit(_lastCallback, 'error', {
        'message': 'Could not start live microphone streaming.',
      });
      _emit(_lastCallback, 'voice_log', {
        'message': 'live microphone streaming failed: $error',
      });
    }
  }

  void _startBackupVoiceMode(String goal, RealtimeEventCallback onEvent) {
    if (!_active) return;
    _usingRealtime = false;
    _realtimeConnected = false;
    _realtimePlaybackActive = false;
    _finishingRealtimePlayback = false;
    _realtimeSocket?.sink.close();
    _realtimeSocket = null;
    _channel
        .invokeMethod<bool>('stopRealtimeAudioCapture')
        .catchError((_) => false);
    _channel
        .invokeMethod<bool>('stopRealtimeAudioPlayback')
        .catchError((_) => false);
    _emit(onEvent, 'fallback_mode', {
      'message': 'Backup voice mode active while realtime reconnects.',
    });
    _startFallbackVoiceSession(goal, onEvent);
  }

  Future<void> _startFallbackVoiceSession(
    String goal,
    RealtimeEventCallback onEvent,
  ) async {
    final granted = await _requestMicrophonePermission(onEvent, quiet: true);
    if (!granted) {
      _emit(onEvent, 'permission_denied', {
        'message': 'Permission needed. Please allow microphone access.',
      });
      return;
    }

    try {
      _busy = true;
      _emit(onEvent, 'status', {'message': 'AI Thinking'});
      final data = await _postJson(
          '/api/voice-start',
          {
            'goal': goal,
          },
          timeout: const Duration(seconds: 45));
      await _emitVoiceResponse(onEvent, data, providerWasSpoken: false);
      _emit(onEvent, 'status', {'message': 'Listening'});
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'Voice startup had a problem. Please try again.',
      });
      await _sendAiTextReply(goal, onEvent);
    } finally {
      _busy = false;
      _scheduleFallbackAutoListen(onEvent);
    }
  }

  Future<void> _startFallbackTurnRecording(
      RealtimeEventCallback onEvent) async {
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
      _fallbackRecordingTurn = true;
      _emit(onEvent, 'recording_started', {'message': 'Listening...'});
      _emit(onEvent, 'provider_speaking', {
        'message': 'Recording provider speech...',
      });
      _fallbackTurnRecordingTimer?.cancel();
      _fallbackTurnRecordingTimer = Timer(const Duration(seconds: 7), () {
        if (_active && !_muted && _fallbackRecordingTurn && !_busy) {
          _finishFallbackVoiceTurn(onEvent);
        }
      });
    } catch (error) {
      _fallbackRecordingTurn = false;
      _emit(onEvent, 'error', {
        'message': 'Could not start Android microphone recording.',
      });
    }
  }

  Future<void> _finishFallbackVoiceTurn(RealtimeEventCallback onEvent) async {
    try {
      _busy = true;
      _fallbackRecordingTurn = false;
      _fallbackTurnRecordingTimer?.cancel();
      final result = await _channel
          .invokeMapMethod<String, Object?>('stopVoiceRecording')
          .timeout(const Duration(seconds: 8));
      _emit(onEvent, 'status', {'message': 'AI Thinking'});
      final data = await _postJson(
          '/api/voice-turn',
          {
            'goal': _lastGoal,
            'audioBase64': result?['audioBase64']?.toString() ?? '',
            'audioMimeType': result?['mimeType']?.toString() ?? 'audio/mp4',
            'conversation': _conversation,
          },
          timeout: const Duration(seconds: 55));

      await _emitVoiceResponse(onEvent, data, providerWasSpoken: true);
      _emit(onEvent, 'status', {'message': 'Listening'});
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'I could not process that voice turn. Please try again.',
      });
    } finally {
      _busy = false;
      _scheduleFallbackAutoListen(onEvent);
    }
  }

  void _scheduleFallbackAutoListen(RealtimeEventCallback onEvent) {
    _fallbackAutoListenTimer?.cancel();
    if (_usingRealtime ||
        !_active ||
        _muted ||
        _fallbackRecordingTurn ||
        _busy) {
      return;
    }
    _fallbackAutoListenTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_usingRealtime &&
          _active &&
          !_muted &&
          !_fallbackRecordingTurn &&
          !_busy) {
        _startFallbackTurnRecording(onEvent);
      }
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
    } catch (error) {
      _emit(onEvent, 'goal_speech_error', {
        'message': 'Could not start Android microphone recording.',
      });
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
    } catch (error) {
      _emit(onEvent, 'goal_speech_error', {
        'message': 'Could not process your voice goal.',
      });
    }
  }

  Future<bool> _checkCloudBackend(
    RealtimeEventCallback onEvent, {
    bool microphonePermission = false,
  }) async {
    _emit(onEvent, 'status', {'message': 'Connecting...'});
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
      final realtimeReady = connected && payload['hasOpenAIKey'] == true;

      _emit(onEvent, 'backend_status', {
        'connected': connected,
        'microphonePermission': microphonePermission,
        'realtimeReady': realtimeReady,
        'backendBaseUrl': ApiConfig.backendBaseUrl,
      });
      _emit(onEvent, connected ? 'status' : 'error', {
        'message': connected ? 'Connected' : 'Cloud backend error.',
      });
      _emit(onEvent, 'debug_result', {
        'name': 'Backend health',
        'ok': connected,
        'message': connected
            ? 'Backend health OK. Realtime ready: $realtimeReady.'
            : 'Backend health failed with ${response.statusCode}.',
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
      _emit(onEvent, 'ai_delta', {'text': reply, 'transcript': reply});
      _emit(onEvent, 'ai_translation', {
        'text': reply,
        'translation':
            'Voice is reconnecting. You can continue with this text reply.',
      });
      _emit(onEvent, 'ai_turn_done', {'text': reply});
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

    if (providerWasSpoken && providerTranscript.isNotEmpty) {
      _conversation.add({'speaker': 'provider', 'text': providerTranscript});
      _emit(onEvent, 'provider_transcript', {
        'text': providerTranscript,
        'translation': providerTranslation,
      });
    }

    if (aiReply.isNotEmpty) {
      _conversation.add({'speaker': 'ai', 'text': aiReply});
      _emit(onEvent, 'ai_delta', {'text': aiReply, 'transcript': aiReply});
      _emit(onEvent, 'ai_translation', {
        'text': aiReply,
        'translation': aiTranslation,
      });
    }

    if (data['needsUserApproval'] == true) {
      _emit(onEvent, 'approval_needed', {
        'message': 'Do you approve this deal?',
        'finalNote': data['finalNote'],
      });
    }

    if (audioBase64.isNotEmpty) {
      _emit(onEvent, 'audio_playback_started', {'message': 'AI Speaking'});
      await _playAudioBase64(audioBase64, audioMimeType, onEvent);
      _emit(onEvent, 'audio_playback_ended', {'message': 'Listening'});
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
    } catch (error) {
      _emit(onEvent, 'error', {
        'message': 'Voice playback had a problem. Please try again.',
      });
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
    } catch (_) {
      if (!quiet) {
        _emit(onEvent, 'permission_denied', {
          'message': 'Permission needed. Could not open microphone prompt.',
        });
      }
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
