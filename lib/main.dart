import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_config.dart';
import 'auth_service.dart';
import 'realtime_bridge.dart';

const developerDebugMode = bool.fromEnvironment(
  'DEVELOPER_DEBUG',
  defaultValue: true,
);

void main() {
  runApp(const TravelNegotiatorApp());
}

class TravelNegotiatorApp extends StatefulWidget {
  const TravelNegotiatorApp({super.key});

  @override
  State<TravelNegotiatorApp> createState() => _TravelNegotiatorAppState();
}

class _TravelNegotiatorAppState extends State<TravelNegotiatorApp> {
  bool darkMode = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TravelBuddy AI',
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: NegotiatorDashboard(
        darkMode: darkMode,
        onDarkModeChanged: (value) => setState(() => darkMode = value),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(useMaterial3: true, brightness: brightness);
    return base.copyWith(
      scaffoldBackgroundColor:
          isDark ? AppColors.darkBackground : AppColors.midnight,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.blue,
        brightness: brightness,
      ),
      textTheme: base.textTheme.apply(
        bodyColor:
            isDark ? Colors.white.withValues(alpha: 0.92) : AppColors.text,
        displayColor: isDark ? Colors.white : AppColors.text,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.04),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              BorderSide(color: isDark ? AppColors.darkLine : AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.blue, width: 1.5),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class NegotiatorDashboard extends StatefulWidget {
  const NegotiatorDashboard({
    super.key,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<NegotiatorDashboard> createState() => _NegotiatorDashboardState();
}

class _NegotiatorDashboardState extends State<NegotiatorDashboard>
    with WidgetsBindingObserver {
  final destination = TextEditingController(text: 'Coral Island');
  final activity = TextEditingController(
      text: 'Private boat transfer and 2-hour island visit');
  final people = TextEditingController(text: '4');
  final budget = TextEditingController(text: '1,500 THB');
  final maxPrice = TextEditingController(text: '1,900 THB');
  final notes = TextEditingController(
      text:
          'Prefer safe boat, life jackets, clear pickup point, no hidden fees.');

  String providerLanguage = 'Thai';
  String userLanguage = 'English';
  VoiceState voiceState = VoiceState.ready;
  bool approvalRequired = true;
  bool loginComplete = false;
  bool micMuted = false;
  bool goalRecording = false;
  bool goalProcessing = false;
  bool backendConnected = false;
  bool microphonePermission = false;
  bool realtimeReady = false;
  bool realtimeRecovering = false;
  bool weakNetworkMode = false;
  String statusMessage = 'Ready to start realtime negotiation.';
  String debugStatusMessage = 'Diagnostics ready.';
  final realtimeBridge = RealtimeBridge();
  final authService = createAuthService();
  String liveAiTranscript = '';
  String lastPrivateGoal = '';
  DateTime lastRealtimeEventAt = DateTime.now();
  Timer? realtimeWatchdog;
  int selectedTab = 0;

  static const tripNotesStorageKey = 'trip_notes';
  static const liveSnapshotStorageKey = 'live_conversation_snapshot';
  static const analyticsStorageKey = 'analytics_events';

  final providerMessages = <ConversationLine>[
    const ConversationLine(
      title: 'Provider original',
      text: 'ราคา 2,200 บาท สำหรับ 4 คน ไปกลับ รวมเสื้อชูชีพครับ',
      translation:
          'The price is 2,200 baht for 4 people, round trip, life jackets included.',
    ),
    const ConversationLine(
      title: 'Provider original',
      text: 'รับที่ท่าเรือหลัก ใช้เวลา 2 ชั่วโมง แต่ไม่รวมค่าขึ้นเกาะครับ',
      translation:
          'Pickup is at the main pier for 2 hours, but island entry fee is not included.',
    ),
  ];

  final aiMessages = <ConversationLine>[
    const ConversationLine(
      title: 'AI speaking',
      text: 'ขอบคุณครับ ถ้าเป็น 4 คน และจองตอนนี้ ลดเหลือ 1,600 บาทได้ไหมครับ',
      translation:
          'Thank you. For 4 people booking now, could you reduce it to 1,600 baht?',
    ),
    const ConversationLine(
      title: 'AI speaking',
      text:
          'ขอเช็กอีกนิดครับ ราคานี้รวมรับส่ง น้ำมัน เสื้อชูชีพ และไม่มีค่าใช้จ่ายแอบแฝงใช่ไหมครับ',
      translation:
          'One more check: does this include pickup, fuel, life jackets, and no hidden fees?',
    ),
  ];

  final tripNotes = <TripNote>[
    const TripNote('10:42',
        'Boat offer found: 1,800 THB for 4 people, 2 hours, pickup at main pier.'),
    const TripNote('10:39',
        'AI asked safety checklist: life jackets, fuel, pickup point, island fee.'),
    const TripNote('10:36',
        'Started negotiation for Coral Island private boat. Target 1,500 THB.'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadTripNotes();
    loadLiveSnapshot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (selectedTab == 1) {
        realtimeBridge.setMuted(true);
        micMuted = true;
        trackEvent('app_backgrounded_live_session');
        saveLiveSnapshot();
      }
      return;
    }

    if (state == AppLifecycleState.resumed && selectedTab == 1) {
      trackEvent('app_resumed_live_session');
      if (lastPrivateGoal.isNotEmpty && !backendConnected) {
        resumeNegotiation();
      } else if (micMuted) {
        realtimeBridge.setMuted(false);
        setState(() {
          micMuted = false;
          voiceState = VoiceState.listening;
          statusMessage = 'Back online. Listening again.';
        });
      }
    }
  }

  Future<void> loadTripNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final rawNotes = prefs.getStringList(tripNotesStorageKey);
    if (rawNotes == null || rawNotes.isEmpty) return;

    final loadedNotes = rawNotes
        .map(
            (raw) => TripNote.fromJson(jsonDecode(raw) as Map<String, dynamic>))
        .toList();

    if (!mounted) return;
    setState(() {
      tripNotes
        ..clear()
        ..addAll(loadedNotes);
    });
  }

  Future<void> saveTripNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      tripNotesStorageKey,
      tripNotes.map((note) => jsonEncode(note.toJson())).toList(),
    );
  }

  Future<void> loadLiveSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(liveSnapshotStorageKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final provider = (data['providerMessages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ConversationLine.fromJson)
          .toList();
      final ai = (data['aiMessages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ConversationLine.fromJson)
          .toList();
      if (!mounted || (provider.isEmpty && ai.isEmpty)) return;
      setState(() {
        providerMessages
          ..clear()
          ..addAll(provider);
        aiMessages
          ..clear()
          ..addAll(ai);
        lastPrivateGoal = data['goal']?.toString() ?? '';
      });
    } catch (_) {
      await prefs.remove(liveSnapshotStorageKey);
    }
  }

  Future<void> saveLiveSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      liveSnapshotStorageKey,
      jsonEncode({
        'goal': lastPrivateGoal,
        'providerMessages':
            providerMessages.take(30).map((line) => line.toJson()).toList(),
        'aiMessages': aiMessages.take(30).map((line) => line.toJson()).toList(),
      }),
    );
  }

  Future<void> trackEvent(String name,
      [Map<String, Object?> data = const {}]) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(analyticsStorageKey) ?? const [];
    final next = [
      ...current.take(60),
      jsonEncode({
        'name': name,
        'at': DateTime.now().toIso8601String(),
        'live': selectedTab == 1,
        'voiceState': voiceState.name,
        ...data,
      }),
    ];
    await prefs.setStringList(analyticsStorageKey, next);
  }

  void fillVoiceGoal() {
    if (goalRecording) {
      realtimeBridge.stopGoalSpeech();
      setState(() {
        goalRecording = false;
        goalProcessing = true;
        voiceState = VoiceState.thinking;
        statusMessage = 'Processing voice goal...';
      });
      return;
    }

    realtimeBridge.startGoalSpeech(handleRealtimeEvent);
    setState(() {
      goalRecording = true;
      goalProcessing = false;
      voiceState = VoiceState.listening;
      statusMessage = 'Recording your travel goal. Press stop when done.';
    });
  }

  String buildPrivateGoal() {
    return [
      'Destination: ${destination.text}',
      'Activity: ${activity.text}',
      'People: ${people.text}',
      'Target price: ${budget.text}',
      'Maximum price before approval: ${maxPrice.text}',
      'Provider language: $providerLanguage',
      'User translation language: $userLanguage',
      'Private notes: ${notes.text}',
      'Rules: talk like a normal friendly person. Ask short, straight questions. Do not sound like a complicated AI.',
      'Core questions: How much can you reduce? What is the final price? What is included? Pickup and drop-off included? Any extra fee?',
      'Context rules: taxi/rental car asks about toll fee, waiting time, pickup/drop-off, luggage, route, and extra charge. Boat asks about life jacket, round trip, island fee, pickup point, safety, and duration. Hotel asks about tax, breakfast, deposit, and late checkout. Shopping asks about discount, warranty, original/fake, and delivery.',
      'Approval rule: do not confirm a final deal until the user approves in the app.'
    ].join('\n');
  }

  void startNegotiation() {
    final goal = buildPrivateGoal();
    lastPrivateGoal = goal;
    lastRealtimeEventAt = DateTime.now();
    startRealtimeWatchdog();
    trackEvent('live_start');
    setState(() {
      voiceState = VoiceState.thinking;
      selectedTab = 1;
      micMuted = false;
      backendConnected = false;
      microphonePermission = false;
      realtimeReady = false;
      realtimeRecovering = false;
      weakNetworkMode = false;
      approvalRequired = true;
      statusMessage = 'Connecting...';
      liveAiTranscript = '';
      providerMessages
        ..clear()
        ..add(
          const ConversationLine(
            title: 'Realtime session',
            text: 'Waiting for provider speech...',
            translation:
                'Allow microphone access, then let the service provider speak near your Mac.',
          ),
        );
      aiMessages
        ..clear()
        ..add(
          ConversationLine(
            title: 'AI speaking',
            text: 'Preparing polite $providerLanguage negotiation...',
            translation:
                'The AI will speak to the provider, then summarize before any final deal.',
          ),
        );
    });

    realtimeBridge.start(goal, handleRealtimeEvent);
  }

  void resumeNegotiation() {
    if (lastPrivateGoal.isEmpty) return;
    lastRealtimeEventAt = DateTime.now();
    startRealtimeWatchdog();
    trackEvent('live_resume');
    setState(() {
      selectedTab = 1;
      realtimeRecovering = true;
      weakNetworkMode = true;
      voiceState = VoiceState.thinking;
      statusMessage = 'Recovering realtime session...';
    });
    realtimeBridge.start(lastPrivateGoal, handleRealtimeEvent);
  }

  void startRealtimeWatchdog() {
    realtimeWatchdog?.cancel();
    realtimeWatchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted || selectedTab != 1 || lastPrivateGoal.isEmpty) return;
      final staleFor = DateTime.now().difference(lastRealtimeEventAt);
      final activeTurn = voiceState == VoiceState.thinking ||
          voiceState == VoiceState.providerSpeaking ||
          voiceState == VoiceState.speaking;

      if (staleFor.inSeconds >= 24 && activeTurn && !realtimeRecovering) {
        trackEvent('live_timeout_recovery', {'seconds': staleFor.inSeconds});
        setState(() {
          weakNetworkMode = true;
          realtimeRecovering = true;
          statusMessage = 'Weak network. Reconnecting smoothly...';
          aiMessages.add(
            const ConversationLine(
              title: 'Recovery',
              text: 'Reconnecting...',
              translation:
                  'Keeping the conversation ready while signal recovers.',
            ),
          );
        });
        realtimeBridge.stop();
        Future<void>.delayed(const Duration(milliseconds: 900), () {
          if (mounted && realtimeRecovering) resumeNegotiation();
        });
      }
    });
  }

  void pauseNegotiation() {
    realtimeBridge.setMuted(true);
    setState(() {
      voiceState = VoiceState.paused;
      micMuted = true;
      statusMessage = 'Muted. Tap unmute when you want to listen again.';
    });
  }

  void toggleMicMute() {
    final nextMuted = !micMuted;
    realtimeBridge.setMuted(nextMuted);
    setState(() {
      micMuted = nextMuted;
      voiceState = micMuted ? VoiceState.paused : VoiceState.listening;
      statusMessage =
          micMuted ? 'Muted. The mic is paused.' : 'Listening again.';
    });
  }

  void stopNegotiation() {
    realtimeBridge.stop();
    realtimeWatchdog?.cancel();
    trackEvent('live_stop');
    setState(() {
      voiceState = VoiceState.ready;
      micMuted = false;
      realtimeRecovering = false;
      weakNetworkMode = false;
      statusMessage = 'Realtime negotiation stopped.';
    });
  }

  void testBackendConnection() {
    trackEvent('debug_test_backend');
    setState(() {
      debugStatusMessage = 'Testing backend...';
      statusMessage = 'Connecting...';
    });
    realtimeBridge.testBackend(handleRealtimeEvent);
  }

  void testAiTextReply() {
    trackEvent('debug_test_ai_text');
    setState(() {
      debugStatusMessage = 'Testing AI text reply...';
      statusMessage = 'AI Thinking';
      voiceState = VoiceState.thinking;
    });
    realtimeBridge.testAiTextReply(handleRealtimeEvent);
  }

  void approveDeal() {
    realtimeBridge.approve();
    trackEvent('deal_approved');
    setState(() {
      approvalRequired = false;
      voiceState = VoiceState.speaking;
      statusMessage =
          'Approved. AI is confirming the deal in $providerLanguage.';
      tripNotes.insert(
        0,
        TripNote(currentClockTime(),
            'User approved current offer. AI confirmation sent to provider.'),
      );
    });
    saveTripNotes();
  }

  void negotiateMore() {
    setState(() {
      approvalRequired = true;
      voiceState = VoiceState.thinking;
      statusMessage = 'AI will continue negotiating before final approval.';
      aiMessages.add(
        const ConversationLine(
          title: 'User instruction',
          text: 'Please negotiate more before confirming.',
          translation: 'The AI should ask for a better price or clearer terms.',
        ),
      );
    });
  }

  void rejectDeal() {
    realtimeBridge.stop();
    realtimeWatchdog?.cancel();
    trackEvent('deal_rejected');
    setState(() {
      approvalRequired = false;
      voiceState = VoiceState.ready;
      statusMessage =
          'Deal rejected. Suggested next step: ask for a lower price or clearer inclusions.';
      tripNotes.insert(
          0,
          TripNote(currentClockTime(),
              'Deal rejected. Ask for a lower price or choose another provider.'));
    });
    saveTripNotes();
  }

  void handleRealtimeEvent(String rawEvent) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(rawEvent) as Map<String, dynamic>;
    } catch (_) {
      trackEvent('realtime_event_parse_failed');
      return;
    }

    lastRealtimeEventAt = DateTime.now();
    final type = data['type']?.toString() ?? '';

    setState(() {
      switch (type) {
        case 'status':
          final message =
              data['message']?.toString() ?? 'Realtime status update';
          statusMessage = message;
          voiceState = voiceStateFromStatus(message);
          updateConnectionFlagsFromStatus(message);
          realtimeRecovering = false;
        case 'provider_speaking':
          statusMessage =
              data['message']?.toString() ?? 'Provider is speaking...';
          voiceState = VoiceState.providerSpeaking;
        case 'backend_status':
          backendConnected = data['connected'] == true;
          microphonePermission = data['microphonePermission'] == true;
          realtimeReady = data['realtimeReady'] == true;
          statusMessage = backendConnected
              ? realtimeReady
                  ? 'Connected'
                  : 'Connected'
              : 'Offline';
          if (backendConnected) realtimeRecovering = false;
        case 'fallback_mode':
          statusMessage = 'Connected';
          realtimeReady = false;
          realtimeRecovering = false;
          debugStatusMessage =
              data['message']?.toString() ?? 'Using AI text fallback.';
        case 'permission_denied':
          statusMessage = data['message']?.toString() ?? 'Permission needed';
          voiceState = VoiceState.ready;
          microphonePermission = false;
        case 'debug_result':
          final name = data['name']?.toString() ?? 'Diagnostic';
          final ok = data['ok'] == true;
          final message = data['message']?.toString() ?? '';
          debugStatusMessage = '${ok ? 'OK' : 'Failed'}: $name\n$message';
          statusMessage = ok ? 'Connected' : 'Offline';
        case 'provider_transcript':
          final text = data['text']?.toString().trim();
          if (text != null && text.isNotEmpty) {
            backendConnected = true;
            microphonePermission = true;
            realtimeReady = true;
            providerMessages.add(
              ConversationLine(
                title: 'Provider original',
                text: text,
                translation: data['translation']?.toString() ??
                    'Translating to $userLanguage...',
              ),
            );
            statusMessage = 'Provider heard. AI is preparing a response.';
            voiceState = VoiceState.thinking;
            saveLiveSnapshot();
          }
        case 'goal_speech_status':
          statusMessage =
              data['message']?.toString() ?? 'Listening to your goal...';
          goalProcessing = statusMessage.toLowerCase().contains('processing');
          voiceState =
              goalProcessing ? VoiceState.thinking : VoiceState.listening;
        case 'goal_speech_result':
          final transcript = data['transcript']?.toString() ?? '';
          final spokenDestination = data['destination']?.toString() ?? '';
          final spokenActivity = data['activity']?.toString() ?? '';
          final spokenPeople = data['people']?.toString() ?? '';
          final spokenBudget = data['budget']?.toString() ?? '';
          final spokenNotes = data['notes']?.toString() ?? '';
          if (spokenDestination.isNotEmpty) {
            destination.text = spokenDestination;
          }
          if (spokenActivity.isNotEmpty) activity.text = spokenActivity;
          if (spokenPeople.isNotEmpty) people.text = spokenPeople;
          if (spokenBudget.isNotEmpty) budget.text = spokenBudget;
          if (spokenNotes.isNotEmpty) {
            notes.text = '$spokenNotes\nVoice goal: $transcript';
          }
          statusMessage = goalRecording
              ? 'Recording... keep speaking or press stop.'
              : 'Goal filled from voice. Check it, then start negotiation.';
          goalProcessing = false;
          voiceState = goalRecording ? VoiceState.listening : VoiceState.ready;
        case 'goal_speech_error':
          statusMessage =
              data['message']?.toString() ?? 'Could not hear your goal.';
          goalRecording = false;
          goalProcessing = false;
          voiceState = VoiceState.ready;
        case 'provider_translation':
          final text = data['text']?.toString().trim();
          final translation = data['translation']?.toString().trim();
          if (text != null &&
              translation != null &&
              text.isNotEmpty &&
              translation.isNotEmpty) {
            final index =
                providerMessages.lastIndexWhere((line) => line.text == text);
            if (index != -1) {
              providerMessages[index] =
                  providerMessages[index].copyWith(translation: translation);
            }
          }
        case 'ai_delta':
          liveAiTranscript = data['transcript']?.toString() ??
              '$liveAiTranscript${data['text'] ?? ''}';
          final liveLine = ConversationLine(
            title: 'AI speaking',
            text: liveAiTranscript.isEmpty
                ? 'AI is speaking...'
                : liveAiTranscript,
            translation:
                'Translating to $userLanguage after this voice turn...',
          );
          if (aiMessages.isNotEmpty &&
              aiMessages.last.title == 'AI speaking live') {
            aiMessages[aiMessages.length - 1] =
                liveLine.copyWith(title: 'AI speaking live');
          } else {
            aiMessages.add(liveLine.copyWith(title: 'AI speaking live'));
          }
          statusMessage = 'AI is speaking to the provider.';
          voiceState = VoiceState.speaking;
          realtimeRecovering = false;
        case 'ai_translation':
          final text = data['text']?.toString().trim();
          final translation = data['translation']?.toString().trim();
          if (translation != null &&
              translation.isNotEmpty &&
              aiMessages.isNotEmpty) {
            final index = aiMessages.lastIndexWhere((line) {
              final sameLiveTurn = line.title == 'AI speaking live';
              final sameText =
                  text != null && text.isNotEmpty && line.text == text;
              return sameLiveTurn || sameText;
            });
            if (index != -1) {
              aiMessages[index] =
                  aiMessages[index].copyWith(translation: translation);
            }
          }
        case 'ai_turn_done':
          liveAiTranscript = '';
          final text = data['text']?.toString().trim();
          final index = aiMessages.lastIndexWhere((line) {
            final sameLiveTurn = line.title == 'AI speaking live';
            final sameText =
                text != null && text.isNotEmpty && line.text == text;
            return sameLiveTurn || sameText;
          });
          if (index != -1) {
            aiMessages[index] =
                aiMessages[index].copyWith(title: 'AI speaking');
          }
          saveLiveSnapshot();
        case 'approved':
          statusMessage = data['message']?.toString() ??
              'Approved. AI is confirming in $providerLanguage.';
          voiceState = VoiceState.speaking;
        case 'error':
          final message =
              data['message']?.toString() ?? 'Realtime voice error.';
          statusMessage = message;
          voiceState = VoiceState.ready;
          backendConnected = false;
          realtimeReady = false;
          realtimeRecovering = true;
          weakNetworkMode = true;
          trackEvent('realtime_error');
          aiMessages.add(
            ConversationLine(
              title: 'Connection issue',
              text: message,
              translation:
                  'Check Render deployment, then set OPENAI_API_KEY only in the backend environment.',
            ),
          );
      }
    });
  }

  void updateConnectionFlagsFromStatus(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('disconnect') || normalized.contains('stopped')) {
      backendConnected = false;
      realtimeReady = false;
      return;
    }
    if (normalized.contains('connected') ||
        normalized.contains('listening') ||
        normalized.contains('ai')) {
      backendConnected = true;
      realtimeReady = true;
    }
    if (normalized.contains('permission') ||
        normalized.contains('microphone') ||
        normalized.contains('listening')) {
      microphonePermission = !normalized.contains('requesting');
    }
  }

  VoiceState voiceStateFromStatus(String message) {
    final normalized = message.toLowerCase();
    if (normalized.contains('muted')) return VoiceState.paused;
    if (normalized.contains('stop') || normalized.contains('disconnect')) {
      return VoiceState.ready;
    }
    if (normalized.contains('waiting')) return VoiceState.ready;
    if (normalized.contains('listening')) return VoiceState.listening;
    if (normalized.contains('thinking') || normalized.contains('preparing')) {
      return VoiceState.thinking;
    }
    if (normalized.contains('ai') || normalized.contains('confirm')) {
      return VoiceState.speaking;
    }
    if (normalized.contains('permission') || normalized.contains('connect')) {
      return VoiceState.thinking;
    }
    return voiceState;
  }

  String currentClockTime() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    realtimeWatchdog?.cancel();
    realtimeBridge.stop();
    destination.dispose();
    activity.dispose();
    people.dispose();
    budget.dispose();
    maxPrice.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!loginComplete) {
      return _LoginScreen(
        authService: authService,
        onContinue: (message) {
          setState(() {
            loginComplete = true;
            statusMessage = message;
          });
        },
      );
    }

    return Scaffold(
      extendBody: true,
      body: _ScreenBackground(
        child: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 118),
                children: [_buildCurrentTab()],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _FigmaBottomNav(
        selectedIndex: selectedTab,
        onSelected: (index) => setState(() => selectedTab = index),
      ),
    );
  }

  Widget _buildCurrentTab() {
    switch (selectedTab) {
      case 0:
        return Column(
          children: [
            _GoalInputSection(
              destination: destination,
              activity: activity,
              people: people,
              budget: budget,
              maxPrice: maxPrice,
              notes: notes,
              providerLanguage: providerLanguage,
              userLanguage: userLanguage,
              recording: goalRecording,
              processing: goalProcessing,
              onProviderLanguageChanged: (value) =>
                  setState(() => providerLanguage = value),
              onUserLanguageChanged: (value) =>
                  setState(() => userLanguage = value),
              onMic: fillVoiceGoal,
            ),
            const SizedBox(height: 14),
            _PrimaryStartPanel(onStart: startNegotiation),
            const SizedBox(height: 14),
            const _NegotiationPlanSection(),
          ],
        );
      case 1:
        return _LiveConversationSection(
          state: voiceState,
          micMuted: micMuted,
          backendConnected: backendConnected,
          microphonePermission: microphonePermission,
          realtimeReady: realtimeReady,
          backendBaseUrl: ApiConfig.backendBaseUrl,
          recovering: realtimeRecovering,
          weakNetworkMode: weakNetworkMode,
          providerMessages: providerMessages,
          aiMessages: aiMessages,
          onMic: startNegotiation,
          onMuteToggle: toggleMicMute,
          onPause: pauseNegotiation,
          onStop: stopNegotiation,
          onAccept: approveDeal,
          onReject: rejectDeal,
          onTestBackend: testBackendConnection,
          onTestAiText: testAiTextReply,
          debugStatusMessage: debugStatusMessage,
        );
      case 2:
        return Column(
          children: [
            _DealSummaryCard(overBudget: approvalRequired),
            const SizedBox(height: 14),
            _ApprovalSection(
              approvalRequired: approvalRequired,
              onApprove: approveDeal,
              onNegotiateMore: negotiateMore,
              onReject: rejectDeal,
            ),
          ],
        );
      case 3:
        return _TripNotesSection(notes: tripNotes);
      case 4:
        return _ProfileSection(
          darkMode: widget.darkMode,
          onDarkModeChanged: widget.onDarkModeChanged,
          onLogout: () => setState(() => loginComplete = false),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _ScreenBackground extends StatelessWidget {
  const _ScreenBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -110,
            left: -70,
            child: _SoftGlow(
              color: isDark ? AppColors.blue : AppColors.lightBlueGlow,
              size: 260,
              opacity: isDark ? 0.24 : 0.46,
            ),
          ),
          Positioned(
            right: -95,
            bottom: 80,
            child: _SoftGlow(
              color: isDark ? AppColors.purple : AppColors.lightPurpleGlow,
              size: 300,
              opacity: isDark ? 0.22 : 0.42,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _SoftGlow extends StatelessWidget {
  const _SoftGlow({
    required this.color,
    required this.size,
    required this.opacity,
  });

  final Color color;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: opacity),
        ),
      ),
    );
  }
}

class _FigmaBottomNav extends StatelessWidget {
  const _FigmaBottomNav({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const items = [
    (Icons.flag_circle_outlined, Icons.flag_circle, 'Goal'),
    (Icons.chat_bubble_outline, Icons.chat_bubble, 'Live'),
    (Icons.verified_user_outlined, Icons.verified_user, 'Deal'),
    (Icons.route_outlined, Icons.route, 'Notes'),
    (Icons.person_outline, Icons.person, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              height: 74,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.58)
                    : Colors.white.withValues(alpha: 0.76),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.62),
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 32,
                    offset: Offset(0, 14),
                  )
                ],
              ),
              child: Row(
                children: [
                  for (var index = 0; index < items.length; index++)
                    Expanded(
                      child: _FigmaNavItem(
                        icon: items[index].$1,
                        selectedIcon: items[index].$2,
                        label: items[index].$3,
                        selected: selectedIndex == index,
                        onTap: () => onSelected(index),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FigmaNavItem extends StatelessWidget {
  const _FigmaNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = isDark ? Colors.white : AppColors.blue;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: selected
              ? AppColors.blue.withValues(alpha: isDark ? 0.24 : 0.14)
              : Colors.transparent,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? selectedIcon : icon,
              size: 22,
              color: selected
                  ? activeColor
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.66)
                      : AppColors.muted),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? activeColor
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.62)
                        : AppColors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoginScreen extends StatelessWidget {
  const _LoginScreen({required this.authService, required this.onContinue});

  final TravelBuddyAuth authService;
  final ValueChanged<String> onContinue;

  Future<void> _handle(
      BuildContext context, Future<AuthResult> Function() action) async {
    final result = await action();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
    if (result.ok) onContinue(result.message);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/travel_hero.jpg', fit: BoxFit.cover),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? const [
                        Color(0xCC020617),
                        Color(0xAA0F766E),
                        Color(0xF0050812)
                      ]
                    : const [
                        Color(0x88E0F7FA),
                        Color(0xDDF8FEFF),
                        Color(0xFFEAF6F2)
                      ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 120, 24, 48),
                  shrinkWrap: true,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              color: Colors.white
                                  .withValues(alpha: isDark ? 0.13 : 0.7),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.26)),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Icon(Icons.travel_explore,
                                color: isDark ? Colors.white : AppColors.cyan,
                                size: 48),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Welcome back',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : AppColors.text,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in to your AI travel assistant',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.76)
                            : AppColors.muted,
                        fontSize: 16,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 34),
                    _LoginButton(
                      icon: Icons.g_mobiledata,
                      label: 'Continue with Google',
                      onPressed: () =>
                          _handle(context, authService.signInWithGoogle),
                    ),
                    const SizedBox(height: 12),
                    _LoginButton(
                      icon: Icons.apple,
                      label: 'Continue with Apple',
                      onPressed: () =>
                          _handle(context, authService.signInWithApple),
                    ),
                    const SizedBox(height: 12),
                    _LoginButton(
                      icon: Icons.person_add_alt_1,
                      label: 'Create account',
                      onPressed: () =>
                          _handle(context, authService.createAccount),
                    ),
                    const SizedBox(height: 12),
                    _LoginButton(
                      icon: Icons.mail_outline,
                      label: 'Continue with Email',
                      onPressed: () =>
                          _handle(context, authService.signInWithEmail),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'By continuing, you agree to our Terms & Privacy',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginButton extends StatelessWidget {
  const _LoginButton(
      {required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 58,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor:
                  Colors.white.withValues(alpha: isDark ? 0.14 : 0.86),
              foregroundColor: isDark ? Colors.white : AppColors.text,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
              side: BorderSide(
                  color: Colors.white.withValues(alpha: isDark ? 0.22 : 0.65)),
            ),
            onPressed: onPressed,
            icon: Icon(icon, color: isDark ? Colors.white : AppColors.coral),
            label: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ),
      ),
    );
  }
}

class _FigmaHeader extends StatelessWidget {
  const _FigmaHeader({
    required this.title,
    required this.subtitle,
    this.trailingText,
    this.trailingIcon,
    this.onTrailingTap,
  });

  final String title;
  final String subtitle;
  final String? trailingText;
  final IconData? trailingIcon;
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [AppColors.blue, AppColors.cyan],
                ).createShader(bounds),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.58)
                      : AppColors.muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTrailingTap,
          child: Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [AppColors.purple, AppColors.blue],
              ),
              boxShadow: [BoxShadow(color: Color(0x553B82F6), blurRadius: 18)],
            ),
            padding: const EdgeInsets.all(2),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isDark ? Colors.black : Colors.white,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: trailingIcon == null
                    ? Text(
                        trailingText ?? '',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      )
                    : Icon(trailingIcon, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MicRing extends StatelessWidget {
  const _MicRing({
    required this.size,
    required this.color,
    required this.alpha,
  });

  final double size;
  final Color color;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: alpha), width: 1.4),
      ),
    );
  }
}

class _GradientOrbButton extends StatelessWidget {
  const _GradientOrbButton({
    required this.size,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  final double size;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: active
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.blue, AppColors.indigo, AppColors.cyan],
                ),
          color: active ? AppColors.red : null,
          boxShadow: [
            BoxShadow(
              color: (active ? AppColors.red : AppColors.blue)
                  .withValues(alpha: 0.42),
              blurRadius: 34,
              spreadRadius: 2,
            )
          ],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.42),
      ),
    );
  }
}

class _GoalInputSection extends StatelessWidget {
  const _GoalInputSection({
    required this.destination,
    required this.activity,
    required this.people,
    required this.budget,
    required this.maxPrice,
    required this.notes,
    required this.providerLanguage,
    required this.userLanguage,
    required this.recording,
    required this.processing,
    required this.onProviderLanguageChanged,
    required this.onUserLanguageChanged,
    required this.onMic,
  });

  final TextEditingController destination;
  final TextEditingController activity;
  final TextEditingController people;
  final TextEditingController budget;
  final TextEditingController maxPrice;
  final TextEditingController notes;
  final String providerLanguage;
  final String userLanguage;
  final bool recording;
  final bool processing;
  final ValueChanged<String> onProviderLanguageChanged;
  final ValueChanged<String> onUserLanguageChanged;
  final VoidCallback onMic;

  static const languages = [
    'Thai',
    'English',
    'Burmese',
    'Chinese',
    'Japanese',
    'Korean'
  ];

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 430;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FigmaHeader(
          title: 'Good Evening',
          subtitle: 'What can I help you negotiate today?',
          trailingText: 'Me',
        ),
        const SizedBox(height: 22),
        _GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 34),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.blue.withValues(alpha: isDark ? 0.18 : 0.12),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      if (recording) ...[
                        const _MicRing(
                            size: 148, color: AppColors.red, alpha: 0.24),
                        const _MicRing(
                            size: 190, color: AppColors.red, alpha: 0.14),
                      ],
                      _GradientOrbButton(
                        size: 96,
                        active: recording,
                        icon: recording ? Icons.stop : Icons.mic,
                        onPressed: onMic,
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    recording
                        ? 'Listening... tap to stop'
                        : processing
                            ? 'Processing your voice'
                            : 'Tap to speak your goal',
                    style: TextStyle(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.78)
                          : AppColors.muted,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _GlassPanel(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.auto_awesome, color: AppColors.cyan, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Or enter details manually',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (compact) ...[
                _AppTextField(
                    label: 'Service / destination',
                    controller: destination,
                    icon: Icons.navigation_outlined),
                const SizedBox(height: 12),
                _AppTextField(
                    label: 'People',
                    controller: people,
                    icon: Icons.groups_2_outlined),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: _AppTextField(
                          label: 'Service / destination',
                          controller: destination,
                          icon: Icons.navigation_outlined),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _AppTextField(
                          label: 'People',
                          controller: people,
                          icon: Icons.groups_2_outlined),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              if (compact) ...[
                _AppTextField(
                    label: 'Max Budget',
                    controller: budget,
                    icon: Icons.attach_money),
                const SizedBox(height: 12),
                _LanguageDropdown(
                  label: 'Language',
                  value: providerLanguage,
                  items: languages,
                  onChanged: onProviderLanguageChanged,
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: _AppTextField(
                          label: 'Max Budget',
                          controller: budget,
                          icon: Icons.attach_money),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _LanguageDropdown(
                        label: 'Language',
                        value: providerLanguage,
                        items: languages,
                        onChanged: onProviderLanguageChanged,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              _LanguageDropdown(
                label: 'Your translation language',
                value: userLanguage,
                items: languages,
                onChanged: onUserLanguageChanged,
              ),
              const SizedBox(height: 12),
              _AppTextField(
                  label: 'Requirements / Notes',
                  controller: notes,
                  icon: Icons.notes_outlined,
                  maxLines: 4),
              const SizedBox(height: 12),
              _AppTextField(
                  label: 'Activity details',
                  controller: activity,
                  icon: Icons.travel_explore),
              const SizedBox(height: 12),
              _AppTextField(
                  label: 'Approval limit',
                  controller: maxPrice,
                  icon: Icons.price_check_outlined),
            ],
          ),
        ),
      ],
    );
  }
}

class _NegotiationPlanSection extends StatelessWidget {
  const _NegotiationPlanSection();

  @override
  Widget build(BuildContext context) {
    const questions = [
      'Ask initial price and whether it is private or shared.',
      'Ask exact duration and route.',
      'Confirm pickup/drop-off point.',
      'Ask what is included and excluded.',
    ];
    const safety = [
      'Life jackets',
      'Weather check',
      'Licensed operator',
      'No hidden fees'
    ];

    return const _GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
            icon: Icons.psychology_alt_outlined,
            title: '2. Negotiation Plan',
            subtitle: 'AI strategy preview before it speaks.',
          ),
          SizedBox(height: 14),
          _PlanCard(
            title: 'AI strategy preview',
            body:
                'Open politely, collect full terms, anchor near 1,500 THB, then trade flexibility for a fair discount.',
            icon: Icons.auto_awesome,
          ),
          SizedBox(height: 10),
          _PlanCard(
            title: 'Price negotiation strategy',
            body:
                'Counter at 1,500 THB, accept up to 1,900 THB only after user approval.',
            icon: Icons.trending_down,
          ),
          SizedBox(height: 12),
          _Checklist(title: 'Questions AI will ask', items: questions),
          SizedBox(height: 12),
          _Checklist(title: 'Safety checklist', items: safety),
        ],
      ),
    );
  }
}

class _LiveConversationSection extends StatefulWidget {
  const _LiveConversationSection({
    required this.state,
    required this.micMuted,
    required this.backendConnected,
    required this.microphonePermission,
    required this.realtimeReady,
    required this.backendBaseUrl,
    required this.recovering,
    required this.weakNetworkMode,
    required this.providerMessages,
    required this.aiMessages,
    required this.onMic,
    required this.onMuteToggle,
    required this.onPause,
    required this.onStop,
    required this.onAccept,
    required this.onReject,
    required this.onTestBackend,
    required this.onTestAiText,
    required this.debugStatusMessage,
  });

  final VoiceState state;
  final bool micMuted;
  final bool backendConnected;
  final bool microphonePermission;
  final bool realtimeReady;
  final String backendBaseUrl;
  final bool recovering;
  final bool weakNetworkMode;
  final List<ConversationLine> providerMessages;
  final List<ConversationLine> aiMessages;
  final VoidCallback onMic;
  final VoidCallback onMuteToggle;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onTestBackend;
  final VoidCallback onTestAiText;
  final String debugStatusMessage;

  @override
  State<_LiveConversationSection> createState() =>
      _LiveConversationSectionState();
}

class _LiveConversationSectionState extends State<_LiveConversationSection> {
  final scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _LiveConversationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.providerMessages.length != widget.providerMessages.length ||
            oldWidget.aiMessages.length != widget.aiMessages.length ||
            oldWidget.state != widget.state;
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToLatest());
    }
  }

  void scrollToLatest() {
    if (!scrollController.hasClients) return;
    scrollController.animateTo(
      scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final messages = <_LiveChatItem>[];
    final maxLength = widget.providerMessages.length > widget.aiMessages.length
        ? widget.providerMessages.length
        : widget.aiMessages.length;

    for (var index = 0; index < maxLength; index += 1) {
      if (index < widget.providerMessages.length) {
        messages.add(_LiveChatItem(widget.providerMessages[index], false));
      }
      if (index < widget.aiMessages.length) {
        messages.add(_LiveChatItem(widget.aiMessages[index], true));
      }
    }

    final statusLabel = widget.micMuted
        ? 'Muted'
        : !widget.microphonePermission
            ? 'Permission needed'
            : widget.recovering
                ? 'Reconnecting'
                : !widget.backendConnected
                    ? 'Connecting'
                    : widget.state == VoiceState.providerSpeaking
                        ? 'Provider Speaking'
                        : widget.state == VoiceState.speaking
                            ? 'AI Speaking'
                            : widget.state == VoiceState.thinking
                                ? 'AI Thinking'
                                : widget.state == VoiceState.listening
                                    ? 'Listening'
                                    : 'Waiting';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  colorScheme.surface.withValues(alpha: 0.92),
                  colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
                ]
              : [
                  colorScheme.surface,
                  colorScheme.primaryContainer.withValues(alpha: 0.36),
                ],
        ),
        border: Border.all(
          color: isDark ? AppColors.darkLine : AppColors.lightBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: isDark ? 0.28 : 0.10),
            blurRadius: 34,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Live Negotiation',
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 24,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Boat Tour • Bali',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                _LiveStatusPill(
                  status: statusLabel,
                  active: !widget.micMuted,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Column(
              children: [
                const _LiveBudgetCard(),
                const SizedBox(height: 12),
                _BackendStatusStrip(
                  connected: widget.backendConnected,
                  microphonePermission: widget.microphonePermission,
                  realtimeReady: widget.realtimeReady,
                ),
                if (widget.recovering || widget.weakNetworkMode) ...[
                  const SizedBox(height: 10),
                  _RecoveryBanner(recovering: widget.recovering),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  height: 330,
                  child: ListView.separated(
                    controller: scrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: messages.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final item = messages[index];
                      return _ReferenceChatBubble(
                        line: item.line,
                        isAi: item.isAi,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _ReferenceWaveCard(state: widget.state, muted: widget.micMuted),
                const SizedBox(height: 12),
                _BigLiveMicButton(
                  permissionGranted: widget.microphonePermission,
                  muted: widget.micMuted,
                  listening: widget.state == VoiceState.listening ||
                      widget.state == VoiceState.providerSpeaking,
                  onPressed: widget.microphonePermission
                      ? widget.onMuteToggle
                      : widget.onMic,
                ),
                if (developerDebugMode) ...[
                  const SizedBox(height: 12),
                  _LiveDebugPanel(
                    message: widget.debugStatusMessage,
                    onTestBackend: widget.onTestBackend,
                    onTestAiText: widget.onTestAiText,
                  ),
                ],
                const SizedBox(height: 18),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            decoration: BoxDecoration(
              color:
                  colorScheme.surface.withValues(alpha: isDark ? 0.86 : 0.96),
              border: Border(
                top: BorderSide(
                  color: isDark ? AppColors.darkLine : AppColors.lightBorder,
                ),
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _ReferenceControlButton(
                        icon: widget.micMuted ? Icons.mic_off : Icons.mic,
                        label: widget.micMuted ? 'Unmute' : 'Mute',
                        onPressed: widget.onMuteToggle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ReferenceControlButton(
                        icon: Icons.pause,
                        label: 'Pause',
                        onPressed: widget.onPause,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ReferenceControlButton(
                        icon: Icons.stop_rounded,
                        label: 'Stop',
                        onPressed: widget.onStop,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _ReferenceAcceptButton(onPressed: widget.onAccept),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ReferenceRejectButton(onPressed: widget.onReject),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveChatItem {
  const _LiveChatItem(this.line, this.isAi);

  final ConversationLine line;
  final bool isAi;
}

class _LiveStatusPill extends StatelessWidget {
  const _LiveStatusPill({required this.status, required this.active});

  final String status;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeColor = active ? colorScheme.primary : colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: activeColor,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: activeColor.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, color: Colors.white, size: 12),
          const SizedBox(width: 6),
          Text(
            status,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _BackendStatusStrip extends StatelessWidget {
  const _BackendStatusStrip({
    required this.connected,
    required this.microphonePermission,
    required this.realtimeReady,
  });

  final bool connected;
  final bool microphonePermission;
  final bool realtimeReady;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: isDark ? 0.62 : 0.86),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: isDark ? AppColors.darkLine : AppColors.lightBorder,
            width: 1.4),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: isDark ? 0.20 : 0.06),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _TinyStatusChip(
                label: connected ? 'Connected' : 'Offline',
                active: connected,
                icon: connected ? Icons.cloud_done : Icons.cloud_off,
              ),
              _TinyStatusChip(
                label: microphonePermission
                    ? 'Mic permission'
                    : 'Mic permission needed',
                active: microphonePermission,
                icon: microphonePermission ? Icons.mic : Icons.mic_none,
              ),
              _TinyStatusChip(
                label: realtimeReady
                    ? 'Voice ready'
                    : connected
                        ? 'AI text ready'
                        : 'Connecting',
                active: realtimeReady,
                icon: Icons.graphic_eq_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TinyStatusChip extends StatelessWidget {
  const _TinyStatusChip({
    required this.label,
    required this.active,
    required this.icon,
  });

  final String label;
  final bool active;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = active ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: active ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecoveryBanner extends StatelessWidget {
  const _RecoveryBanner({required this.recovering});

  final bool recovering;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colorScheme.tertiary.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: recovering
                ? CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: colorScheme.onTertiaryContainer,
                  )
                : Icon(Icons.network_check,
                    size: 18, color: colorScheme.onTertiaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              recovering
                  ? 'Recovering connection and keeping this conversation ready...'
                  : 'Weak mobile signal detected. Responses may arrive in smaller chunks.',
              style: TextStyle(
                color: colorScheme.onTertiaryContainer,
                fontWeight: FontWeight.w800,
                fontSize: 12,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BigLiveMicButton extends StatelessWidget {
  const _BigLiveMicButton({
    required this.permissionGranted,
    required this.muted,
    required this.listening,
    required this.onPressed,
  });

  final bool permissionGranted;
  final bool muted;
  final bool listening;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = !permissionGranted
        ? 'Tap to allow microphone'
        : muted
            ? 'Tap to unmute'
            : listening
                ? 'Listening'
                : 'Tap to start listening';
    final icon = !permissionGranted || muted ? Icons.mic_off : Icons.mic;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      width: double.infinity,
      height: 68,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary,
            colorScheme.secondary,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.26),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: colorScheme.onPrimary, size: 25),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveDebugPanel extends StatelessWidget {
  const _LiveDebugPanel({
    required this.message,
    required this.onTestBackend,
    required this.onTestAiText,
  });

  final String message;
  final VoidCallback onTestBackend;
  final VoidCallback onTestAiText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Beta diagnostics',
            style: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onTestBackend,
                  child: const Text('Test Backend'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onTestAiText,
                  child: const Text('Test AI Reply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveBudgetCard extends StatelessWidget {
  const _LiveBudgetCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: isDark ? 0.68 : 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? AppColors.darkLine : AppColors.lightBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: isDark ? 0.18 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.circle, color: colorScheme.primary, size: 8),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Budget: \$100',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Icon(Icons.trending_down, color: colorScheme.secondary, size: 18),
              const SizedBox(width: 5),
              Text(
                '\$160',
                style: TextStyle(
                  color: colorScheme.secondary,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Stack(
              children: [
                Container(
                    height: 9,
                    color: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.55)),
                FractionallySizedBox(
                  widthFactor: 0.62,
                  child: Container(
                    height: 9,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colorScheme.primary,
                          colorScheme.secondary,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'AI saved you \$40 so far',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReferenceChatBubble extends StatelessWidget {
  const _ReferenceChatBubble({required this.line, required this.isAi});

  final ConversationLine line;
  final bool isAi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    final aiColor = colorScheme.primary;
    final providerColor =
        colorScheme.surface.withValues(alpha: isDark ? 0.72 : 0.96);
    return Align(
      alignment: isAi ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width * (isAi ? 0.82 : 0.78)),
        child: Container(
          padding: EdgeInsets.fromLTRB(isAi ? 18 : 16, 16, 16, 14),
          decoration: BoxDecoration(
            color: isAi ? aiColor : providerColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isAi ? 18 : 5),
              bottomRight: Radius.circular(isAi ? 5 : 18),
            ),
            border: isAi
                ? null
                : Border.all(
                    color: isDark ? AppColors.darkLine : AppColors.lightBorder,
                  ),
            boxShadow: [
              BoxShadow(
                color: (isAi ? aiColor : colorScheme.shadow)
                    .withValues(alpha: isAi ? 0.22 : 0.05),
                blurRadius: isAi ? 18 : 12,
                offset: const Offset(0, 9),
              )
            ],
          ),
          child: isAi
              ? _AiBubbleContent(line: line)
              : _ProviderBubbleContent(line: line),
        ),
      ),
    );
  }
}

class _ProviderBubbleContent extends StatelessWidget {
  const _ProviderBubbleContent({required this.line});

  final ConversationLine line;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.translate, color: colorScheme.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                line.text,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(vertical: 14),
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.chat_bubble_outline,
                color: colorScheme.primary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                line.translation,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 19,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            'Now · translated',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _AiBubbleContent extends StatelessWidget {
  const _AiBubbleContent({required this.line});

  final ConversationLine line;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.chat_bubble_outline,
                color: colorScheme.onPrimary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                line.text,
                style: TextStyle(
                  color: colorScheme.onPrimary,
                  fontSize: 18,
                  height: 1.36,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Text(
            line.translation,
            style: TextStyle(
              color: colorScheme.onPrimary.withValues(alpha: 0.78),
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            'Now · AI',
            style: TextStyle(
              color: colorScheme.onPrimary.withValues(alpha: 0.78),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ReferenceWaveCard extends StatelessWidget {
  const _ReferenceWaveCard({required this.state, required this.muted});

  final VoiceState state;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final label = muted
        ? 'Muted'
        : state == VoiceState.providerSpeaking
            ? 'Provider speaking...'
            : state == VoiceState.speaking
                ? 'AI is speaking...'
                : state == VoiceState.thinking
                    ? 'AI is thinking...'
                    : state == VoiceState.listening
                        ? 'Listening...'
                        : 'Waiting...';
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: isDark ? 0.70 : 0.94),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
              color: isDark ? AppColors.darkLine : AppColors.lightBorder),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: isDark ? 0.20 : 0.06),
              blurRadius: 14,
              offset: const Offset(0, 8),
            )
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniWave(state: state, muted: muted),
            const SizedBox(width: 18),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniWave extends StatelessWidget {
  const _MiniWave({required this.state, required this.muted});

  final VoiceState state;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final active = !muted &&
        (state == VoiceState.listening ||
            state == VoiceState.providerSpeaking ||
            state == VoiceState.speaking ||
            state == VoiceState.thinking);
    final heights = active ? [26.0, 42.0, 32.0] : [18.0, 18.0, 18.0];
    final colorScheme = Theme.of(context).colorScheme;
    final colors = [
      colorScheme.primary,
      colorScheme.tertiary,
      colorScheme.secondary,
    ];
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          for (var index = 0; index < heights.length; index++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 360),
              width: 5,
              height: heights[index],
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: colors[index],
                borderRadius: BorderRadius.circular(999),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReferenceControlButton extends StatelessWidget {
  const _ReferenceControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return SizedBox(
      height: 58,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          backgroundColor:
              colorScheme.surface.withValues(alpha: isDark ? 0.72 : 0.96),
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(
              color: isDark ? AppColors.darkLine : AppColors.lightBorder,
              width: 1.6),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
      ),
    );
  }
}

class _ReferenceAcceptButton extends StatelessWidget {
  const _ReferenceAcceptButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 66,
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          elevation: 0,
          shadowColor: colorScheme.primary,
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.check, size: 22),
        label: Text(
          'Approve',
          style: TextStyle(color: colorScheme.onPrimary),
        ),
      ),
    );
  }
}

class _ReferenceRejectButton extends StatelessWidget {
  const _ReferenceRejectButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 66,
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.error,
          side: BorderSide(color: colorScheme.error.withValues(alpha: 0.45)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.close_rounded, size: 22),
        label: const Text('Reject'),
      ),
    );
  }
}

class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onPressed,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
          border: Border.all(
            color: color?.withValues(alpha: 0.28) ??
                (isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        child: Icon(
          icon,
          size: 22,
          color: color ?? (isDark ? Colors.white : AppColors.text),
        ),
      ),
    );
  }
}

class _DealSummaryCard extends StatelessWidget {
  const _DealSummaryCard({required this.overBudget});

  final bool overBudget;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.green.withValues(alpha: isDark ? 0.20 : 0.14),
            boxShadow: const [
              BoxShadow(color: Color(0x4467D7A2), blurRadius: 22)
            ],
          ),
          child: const Icon(Icons.check, color: AppColors.green, size: 28),
        ),
        const SizedBox(height: 12),
        const Text('Deal Reached!',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Waiting for your approval',
            style: TextStyle(color: AppColors.muted, fontSize: 14)),
        const SizedBox(height: 24),
        _GlassPanel(
          padding: const EdgeInsets.all(20),
          borderColor: AppColors.green.withValues(alpha: 0.30),
          child: Stack(
            children: [
              Positioned(
                top: -10,
                right: -10,
                child: Icon(Icons.auto_awesome,
                    size: 92, color: AppColors.green.withValues(alpha: 0.08)),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'FINAL TOTAL',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [AppColors.green, AppColors.cyan],
                        ).createShader(bounds),
                        child: const Text(
                          '1,800 ฿',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 42,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Text('2,200 ฿',
                            style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 18,
                                decoration: TextDecoration.lineThrough)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.green.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text('Saved 400 ฿',
                            style: TextStyle(
                                color: AppColors.green,
                                fontSize: 12,
                                fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.green.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.green.withValues(alpha: 0.25)),
                    ),
                    child: const Text(
                      '"1,800 baht total, round trip, life jackets included."',
                      style: TextStyle(
                          color: AppColors.green,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.35),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _DealLine(
                    icon: Icons.place_outlined,
                    title: 'Coral Island',
                    body: 'Pickup from main pier gate 2',
                  ),
                  const _DealLine(
                    icon: Icons.check,
                    iconColor: AppColors.green,
                    title: 'Included',
                    body: 'Life jackets, fuel, pier pickup/drop-off',
                  ),
                  const _DealLine(
                    icon: Icons.close,
                    iconColor: AppColors.red,
                    title: 'Not Included',
                    body: 'Island entry fee is separate',
                  ),
                  _DealLine(
                    icon: Icons.error_outline,
                    iconColor: AppColors.gold,
                    title: 'Extra Fee Warning',
                    body: overBudget
                        ? 'Over target price. Ask approval before confirming.'
                        : 'Approved deal can be confirmed in provider language.',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DealLine extends StatelessWidget {
  const _DealLine({
    required this.icon,
    required this.title,
    required this.body,
    this.iconColor = AppColors.muted,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: iconColor == AppColors.muted ? null : iconColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 14, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalSection extends StatelessWidget {
  const _ApprovalSection({
    required this.approvalRequired,
    required this.onApprove,
    required this.onNegotiateMore,
    required this.onReject,
  });

  final bool approvalRequired;
  final VoidCallback onApprove;
  final VoidCallback onNegotiateMore;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            icon: Icons.verified_user_outlined,
            title: '5. User Approval',
            subtitle: 'The AI cannot finalize without your approval.',
          ),
          const SizedBox(height: 14),
          _GradientActionButton(
            label: approvalRequired ? 'Approve Deal' : 'Deal Approved',
            icon: Icons.check_circle_outline,
            colors: const [AppColors.green, AppColors.cyan],
            onPressed: approvalRequired ? onApprove : null,
          ),
          const SizedBox(height: 10),
          _BigActionButton(
            label: 'Negotiate More',
            icon: Icons.tune,
            color: AppColors.cyan,
            onPressed: onNegotiateMore,
          ),
          const SizedBox(height: 10),
          _BigActionButton(
            label: 'Reject Deal',
            icon: Icons.cancel_outlined,
            color: AppColors.red,
            onPressed: onReject,
          ),
        ],
      ),
    );
  }
}

class _TripNotesSection extends StatelessWidget {
  const _TripNotesSection({required this.notes});

  final List<TripNote> notes;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            icon: Icons.route_outlined,
            title: '6. Saved Trip Notes',
            subtitle: 'Timeline of decisions and useful travel details.',
          ),
          const SizedBox(height: 14),
          for (final note in notes)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                    width: 54,
                    child: Text(note.time,
                        style: const TextStyle(
                            color: AppColors.cyan,
                            fontWeight: FontWeight.w900))),
                Column(
                  children: [
                    Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                            color: AppColors.cyan, shape: BoxShape.circle)),
                    Container(width: 2, height: 42, color: AppColors.line),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(note.text,
                        style: const TextStyle(
                            color: AppColors.muted, height: 1.35)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PrimaryStartPanel extends StatelessWidget {
  const _PrimaryStartPanel({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return _GradientActionButton(
      label: 'Start Negotiating',
      icon: Icons.play_arrow_rounded,
      onPressed: onStart,
    );
  }
}

class _GradientActionButton extends StatelessWidget {
  const _GradientActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.colors = const [AppColors.blue, AppColors.indigo, AppColors.purple],
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white.withValues(alpha: 0.58),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
        ),
      ),
    );
  }
}

class _ProfileSection extends StatefulWidget {
  const _ProfileSection({
    required this.darkMode,
    required this.onDarkModeChanged,
    required this.onLogout,
  });

  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;
  final VoidCallback onLogout;

  @override
  State<_ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<_ProfileSection> {
  bool notifications = true;
  String language = 'English';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _FigmaHeader(
          title: 'Profile',
          subtitle: 'Your travel companion settings',
          trailingIcon: Icons.settings,
          onTrailingTap: () {},
        ),
        const SizedBox(height: 22),
        Center(
          child: Column(
            children: [
              Stack(
                children: [
                  Container(
                    width: 104,
                    height: 104,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.cyan, width: 2),
                      boxShadow: const [
                        BoxShadow(color: Color(0x5538E8FF), blurRadius: 22)
                      ],
                    ),
                    child: ClipOval(
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AppColors.indigo, AppColors.cyan],
                          ),
                        ),
                        child: const Icon(Icons.person,
                            color: Colors.white, size: 54),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 2,
                    child: _RoundGlassButton(
                      icon: Icons.camera_alt,
                      onPressed: () {},
                      color: AppColors.cyan,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text('Alex Voyager',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('alex@travelbuddy.ai',
                  style: TextStyle(color: AppColors.muted, fontSize: 14)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Row(
          children: [
            Expanded(
                child: _MetricCard(
                    value: '12', label: 'Trips', color: AppColors.blue)),
            SizedBox(width: 10),
            Expanded(
                child: _MetricCard(
                    value: '\$450', label: 'Saved', color: AppColors.green)),
            SizedBox(width: 10),
            Expanded(
                child: _MetricCard(
                    value: '95%', label: 'Success', color: AppColors.purple)),
          ],
        ),
        const SizedBox(height: 18),
        _PremiumCard(onTap: () {}),
        const SizedBox(height: 18),
        const _SettingsTile(
            icon: Icons.edit_outlined,
            title: 'Edit Profile',
            trailing: Icon(Icons.chevron_right)),
        _SettingsTile(
          icon: Icons.dark_mode_outlined,
          title: 'Dark mode',
          trailing: Switch(
              value: widget.darkMode, onChanged: widget.onDarkModeChanged),
        ),
        _SettingsTile(
          icon: Icons.language,
          title: 'Language Settings',
          trailing: DropdownButton<String>(
            value: language,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 'English', child: Text('English')),
              DropdownMenuItem(value: 'Thai', child: Text('Thai')),
              DropdownMenuItem(value: 'Japanese', child: Text('Japanese')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => language = value);
            },
          ),
        ),
        const _SettingsTile(
            icon: Icons.mic_none,
            title: 'Voice Settings',
            trailing: Icon(Icons.chevron_right)),
        _SettingsTile(
          icon: Icons.notifications_none,
          title: 'Notification Settings',
          trailing: Switch(
              value: notifications,
              onChanged: (value) => setState(() => notifications = value)),
        ),
        const _SettingsTile(
            icon: Icons.shield_outlined,
            title: 'Privacy & Security',
            trailing: Icon(Icons.chevron_right)),
        const _SettingsTile(
            icon: Icons.lock_outline,
            title: 'Change Password',
            trailing: Icon(Icons.chevron_right)),
        const SizedBox(height: 12),
        _BigActionButton(
          label: 'Log Out',
          icon: Icons.logout,
          color: AppColors.red,
          onPressed: widget.onLogout,
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 25, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _PremiumCard extends StatelessWidget {
  const _PremiumCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: _GlassPanel(
        padding: const EdgeInsets.all(16),
        borderColor: AppColors.cyan.withValues(alpha: 0.30),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient:
                    LinearGradient(colors: [AppColors.cyan, AppColors.blue]),
                boxShadow: [
                  BoxShadow(color: Color(0x5538E8FF), blurRadius: 16)
                ],
              ),
              child: const Icon(Icons.auto_awesome, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TravelBuddy Premium',
                      style: TextStyle(
                          color: AppColors.cyan, fontWeight: FontWeight.w900)),
                  SizedBox(height: 2),
                  Text('Unlock unlimited negotiations',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.cyan),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile(
      {required this.icon, required this.title, required this.trailing});

  final IconData icon;
  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.muted, size: 21),
          const SizedBox(width: 12),
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800))),
          trailing,
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(
      {required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.cyan),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w900)),
              const SizedBox(height: 3),
              Text(subtitle,
                  style: const TextStyle(color: AppColors.muted, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

class _AppTextField extends StatelessWidget {
  const _AppTextField({
    required this.label,
    required this.controller,
    required this.icon,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final IconData icon;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: TextStyle(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.52)
                  : AppColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            isDense: true,
            labelText: null,
            prefixIcon: Icon(icon, size: 19),
            constraints: maxLines == 1
                ? const BoxConstraints(minHeight: 42)
                : const BoxConstraints(minHeight: 96),
          ),
        ),
      ],
    );
  }
}

class _LanguageDropdown extends StatelessWidget {
  const _LanguageDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: TextStyle(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.52)
                  : AppColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        DropdownButtonFormField<String>(
          initialValue: value,
          decoration: const InputDecoration(
            isDense: true,
          ),
          isExpanded: true,
          items: [
            for (final item in items)
              DropdownMenuItem(value: item, child: Text(item)),
          ],
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard(
      {required this.title, required this.body, required this.icon});

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _InsetPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.cyan),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(body,
                    style:
                        const TextStyle(color: AppColors.muted, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return _InsetPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const Icon(Icons.check_circle,
                      color: AppColors.green, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(item,
                          style: const TextStyle(color: AppColors.muted))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BigActionButton extends StatelessWidget {
  const _BigActionButton(
      {required this.label,
      required this.icon,
      required this.color,
      required this.onPressed});

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
            backgroundColor: color, foregroundColor: AppColors.ink),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.black.withValues(alpha: 0.40)
                : Colors.white.withValues(alpha: 0.72),
            border: Border.all(
                color: borderColor ??
                    (isDark
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.white.withValues(alpha: 0.68))),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color:
                    isDark ? const Color(0x66000000) : const Color(0x140A3A3D),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _InsetPanel extends StatelessWidget {
  const _InsetPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.darkGlass
            : AppColors.panelSoft.withValues(alpha: 0.9),
        border: Border.all(color: isDark ? AppColors.darkLine : AppColors.line),
        borderRadius: BorderRadius.circular(24),
      ),
      child: child,
    );
  }
}

enum VoiceState {
  ready('Ready', Icons.radio_button_checked, AppColors.muted),
  listening('Listening', Icons.hearing, AppColors.cyan),
  providerSpeaking('Provider Speaking', Icons.record_voice_over, AppColors.sky),
  thinking('Thinking', Icons.psychology_alt_outlined, AppColors.gold),
  speaking('Speaking', Icons.graphic_eq, AppColors.green),
  paused('Paused', Icons.pause_circle_outline, AppColors.violet);

  const VoiceState(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

class ConversationLine {
  const ConversationLine(
      {required this.title, required this.text, required this.translation});

  factory ConversationLine.fromJson(Map<String, dynamic> json) {
    return ConversationLine(
      title: json['title']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      translation: json['translation']?.toString() ?? '',
    );
  }

  final String title;
  final String text;
  final String translation;

  ConversationLine copyWith(
      {String? title, String? text, String? translation}) {
    return ConversationLine(
      title: title ?? this.title,
      text: text ?? this.text,
      translation: translation ?? this.translation,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'text': text,
      'translation': translation,
    };
  }
}

class TripNote {
  const TripNote(this.time, this.text);

  factory TripNote.fromJson(Map<String, dynamic> json) {
    return TripNote(
      json['time']?.toString() ?? '',
      json['text']?.toString() ?? '',
    );
  }

  final String time;
  final String text;

  Map<String, dynamic> toJson() {
    return {'time': time, 'text': text};
  }
}

class AppColors {
  static const darkBackground = Color(0xFF050510);
  static const darkGlass = Color(0x1AFFFFFF);
  static const darkGlassStrong = Color(0x66101826);
  static const darkLine = Color(0x24FFFFFF);
  static const lightBackground = Color(0xFFF8FAFC);
  static const lightBlueGlow = Color(0xFFBFDBFE);
  static const lightPurpleGlow = Color(0xFFE9D5FF);
  static const midnight = Color(0xFFF8FAFC);
  static const panel = Color(0xFFFFFFFF);
  static const panelSoft = Color(0xFFF4F6F8);
  static const field = Color(0xFFFFFFFF);
  static const line = Color(0x1A000000);
  static const lightBorder = Color(0xFFE5E7EB);
  static const text = Color(0xFF18181B);
  static const muted = Color(0xFF71717A);
  static const zinc500 = Color(0xFF71717A);
  static const ink = Color(0xFF030213);
  static const blue = Color(0xFF3B82F6);
  static const blueDark = Color(0xFF1E3A8A);
  static const indigo = Color(0xFF4F46E5);
  static const purple = Color(0xFF9333EA);
  static const cyan = Color(0xFF22D3EE);
  static const sky = Color(0xFF38BDF8);
  static const coral = Color(0xFFFF8A7A);
  static const violet = Color(0xFFB8A7FF);
  static const green = Color(0xFF10B981);
  static const gold = Color(0xFFFFC857);
  static const red = Color(0xFFEF4444);
  static const referenceInk = Color(0xFF111827);
  static const referenceMuted = Color(0xFF667085);
  static const referenceBlue = Color(0xFF4B83F6);
  static const referencePurple = Color(0xFFA43BFF);
  static const referenceGreen = Color(0xFF08CF6A);
}
