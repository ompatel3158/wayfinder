import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agent.dart';
import 'db.dart';
import 'ingest.dart';

void main() {
  runApp(const WayfinderApp());
}

// Design Palette
const kBgColor = Color(0xFF0F1115);
const kPanelColor = Color(0xFF171A21);
const kBorderColor = Color(0xFF262B36);
const kTextColor = Color(0xFFE6E8EC);
const kMutedColor = Color(0xFF8B93A1);
const kAccentColor = Color(0xFF2DD4BF);

const kRouteSql = Color(0xFF60A5FA);
const kRouteVector = Color(0xFFA78BFA);
const kRouteBoth = Color(0xFFFBBF24);

const kTextFallback = ['Segoe UI', 'sans-serif'];
const kMonoFallback = ['Consolas', 'monospace'];

class WayfinderApp extends StatelessWidget {
  const WayfinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wayfinder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBgColor,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(
            color: kTextColor,
            fontSize: 15,
            fontFamily: 'Inter',
            fontFamilyFallback: kTextFallback,
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

enum StepStatus { pending, running, completed, skipped }

class StepInfo {
  final String name;
  StepStatus status;
  int elapsedMs;
  StepInfo({
    required this.name,
    this.status = StepStatus.pending,
    this.elapsedMs = 0,
  });
}

class ChatMessage {
  final bool isUser;
  final String text;
  final String? revealedText;
  ChatMessage({required this.isUser, required this.text, this.revealedText});
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isLoadingApp = true;
  String _loadingMessage = 'Loading data and warming up model...';

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  final List<ChatMessage> _messages = [];
  bool _isRunning = false;
  String? _lastQuestion;

  // Evidence state
  AgentResult? _latestResult;
  String? _activeRoute;
  String? _errorMessage;

  // Toast state
  String? _toastMessage;
  Timer? _toastTimer;

  // Staggered card visibility
  bool _showSqlCard = false;
  bool _showRowsCard = false;
  bool _showChunksCard = false;

  // Checklist state
  final List<StepInfo> _steps = [
    StepInfo(name: 'Routing'),
    StepInfo(name: 'Searching policy'),
    StepInfo(name: 'Writing SQL'),
    StepInfo(name: 'Answering'),
  ];
  Stopwatch? _stepStopwatch;
  int _currentStepIndex = -1;

  Timer? _wordRevealTimer;

  static const List<String> _demoQuestions = [
    'What is the total refund amount for Travel?',
    'How many days do I have to request a refund?',
    'Which invoices break the refund policy?',
  ];

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _wordRevealTimer?.cancel();
    _inputController.dispose();
    _chatScrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toastMessage = message);
    _toastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  Future<void> _initializeApp() async {
    try {
      final db = AppDatabase.instance;
      if (!db.isInitialized) {
        setState(() => _loadingMessage = 'Opening local ULTSQL database...');
        await db.init();
        setState(() => _loadingMessage = 'Ingesting invoices and policy chunks...');
        await ingestData();
        setState(() => _loadingMessage = 'Warming up Gemma 4 E2B...');
        await warmup();
      }
      if (mounted) {
        setState(() => _isLoadingApp = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingMessage = 'Failed to initialize: $e';
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _handleStepUpdate(String stepName) {
    if (!mounted) return;

    setState(() {
      if (_currentStepIndex >= 0 && _currentStepIndex < _steps.length) {
        _steps[_currentStepIndex].status = StepStatus.completed;
        _steps[_currentStepIndex].elapsedMs = _stepStopwatch?.elapsedMilliseconds ?? 0;
      }

      final idx = _steps.indexKey(stepName);
      if (idx != -1) {
        _currentStepIndex = idx;
        _steps[idx].status = StepStatus.running;
        _stepStopwatch = Stopwatch()..start();
      }
    });
  }

  Future<void> _submitQuestion(String question) async {
    final q = question.trim();
    if (q.isEmpty || _isRunning) return;

    _inputController.clear();
    _lastQuestion = q;

    setState(() {
      _isRunning = true;
      _errorMessage = null;
      _activeRoute = null;
      _latestResult = null;
      _showSqlCard = false;
      _showRowsCard = false;
      _showChunksCard = false;

      for (var s in _steps) {
        s.status = StepStatus.pending;
        s.elapsedMs = 0;
      }
      _currentStepIndex = -1;

      _messages.add(ChatMessage(isUser: true, text: q));
    });
    _scrollToBottom();

    try {
      final result = await ask(
        q,
        onStep: (step) => _handleStepUpdate(step),
      );

      if (!mounted) return;

      if (_currentStepIndex >= 0 && _currentStepIndex < _steps.length) {
        _steps[_currentStepIndex].status = StepStatus.completed;
        _steps[_currentStepIndex].elapsedMs = _stepStopwatch?.elapsedMilliseconds ?? 0;
      }

      for (var s in _steps) {
        if (s.status == StepStatus.pending) {
          s.status = StepStatus.skipped;
        }
      }

      setState(() {
        _latestResult = result;
        _activeRoute = result.route;
        _errorMessage = result.error;
        _isRunning = false;
      });

      // Stagger in evidence cards: 0ms, 60ms, 120ms
      Timer(const Duration(milliseconds: 0), () {
        if (mounted) setState(() => _showSqlCard = true);
      });
      Timer(const Duration(milliseconds: 60), () {
        if (mounted) setState(() => _showRowsCard = true);
      });
      Timer(const Duration(milliseconds: 120), () {
        if (mounted) setState(() => _showChunksCard = true);
      });

      _startWordReveal(result.answer);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _errorMessage = e.toString();
        _messages.add(ChatMessage(
          isUser: false,
          text: 'An error occurred while processing the request.',
        ));
      });
      _scrollToBottom();
    }
  }

  void _startWordReveal(String fullText) {
    _wordRevealTimer?.cancel();
    final words = fullText.split(' ');
    if (words.isEmpty) {
      setState(() {
        _messages.add(ChatMessage(isUser: false, text: fullText));
      });
      _scrollToBottom();
      return;
    }

    int currentWordCount = 0;
    final msgIndex = _messages.length;
    _messages.add(ChatMessage(isUser: false, text: fullText, revealedText: ''));

    _wordRevealTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      currentWordCount++;
      if (currentWordCount >= words.length) {
        timer.cancel();
        setState(() {
          _messages[msgIndex] = ChatMessage(isUser: false, text: fullText, revealedText: fullText);
        });
      } else {
        final partial = words.take(currentWordCount).join(' ');
        setState(() {
          _messages[msgIndex] = ChatMessage(isUser: false, text: fullText, revealedText: partial);
        });
      }
      _scrollToBottom();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingApp) {
      return Scaffold(
        backgroundColor: kBgColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: kAccentColor,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _loadingMessage,
                style: const TextStyle(
                  color: kMutedColor,
                  fontSize: 14,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          _inputFocusNode.requestFocus();
        },
      },
      child: Scaffold(
        backgroundColor: kBgColor,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left Pane: Chat (~40%)
                        Expanded(
                          flex: 40,
                          child: _buildChatPane(),
                        ),
                        Container(width: 1, color: kBorderColor),
                        // Right Pane: Evidence (~60%)
                        Expanded(
                          flex: 60,
                          child: RepaintBoundary(
                            child: _buildEvidencePane(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Toast Banner
              if (_toastMessage != null)
                Positioned(
                  bottom: 24,
                  right: 32,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _toastMessage != null ? 1.0 : 0.0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2937),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kAccentColor),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle_rounded, color: kAccentColor, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            _toastMessage!,
                            style: const TextStyle(
                              color: kTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              fontFamily: 'Inter',
                              fontFamilyFallback: kTextFallback,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: kPanelColor,
        border: Border(bottom: BorderSide(color: kBorderColor, width: 1)),
      ),
      child: Row(
        children: [
          const Text(
            'Wayfinder',
            style: TextStyle(
              color: kTextColor,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFamily: 'Inter',
              fontFamilyFallback: kTextFallback,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: kBgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorderColor),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '●',
                  style: TextStyle(color: kAccentColor, fontSize: 11),
                ),
                SizedBox(width: 6),
                Text(
                  'Running locally on Gemma 4 E2B',
                  style: TextStyle(
                    color: kMutedColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'Inter',
                    fontFamilyFallback: kTextFallback,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: kBgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kBorderColor),
            ),
            child: const Text(
              'Ctrl + K',
              style: TextStyle(
                color: kMutedColor,
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Fully Offline',
            style: TextStyle(
              color: kMutedColor,
              fontSize: 12,
              fontFamily: 'Inter',
              fontFamilyFallback: kTextFallback,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPane() {
    return Column(
      children: [
        // Message List
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded,
                          size: 40, color: kMutedColor.withValues(alpha: 0.5)),
                      const SizedBox(height: 12),
                      const Text(
                        'Try a demo question',
                        style: TextStyle(
                          color: kMutedColor,
                          fontSize: 15,
                          fontFamily: 'Inter',
                          fontFamilyFallback: kTextFallback,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.all(20),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    return _ChatBubble(message: msg);
                  },
                ),
        ),

        // Demo Chips + Input Bar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: kPanelColor,
            border: Border(top: BorderSide(color: kBorderColor, width: 1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 3 Demo Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _demoQuestions.map((q) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 12),
                      child: _DemoChip(
                        text: q,
                        enabled: !_isRunning,
                        onTap: () => _submitQuestion(q),
                      ),
                    );
                  }).toList(),
                ),
              ),

              // Text Field Input with Keyboard Support
              Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    _submitQuestion(_inputController.text);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        focusNode: _inputFocusNode,
                        enabled: !_isRunning,
                        maxLines: 3,
                        minLines: 1,
                        style: const TextStyle(
                          color: kTextColor,
                          fontSize: 14,
                          fontFamily: 'Inter',
                          fontFamilyFallback: kTextFallback,
                        ),
                        decoration: InputDecoration(
                          hintText: _isRunning
                              ? 'Agent is processing question...'
                              : 'Ask a question (Enter sends, Shift+Enter newline)...',
                          hintStyle: const TextStyle(color: kMutedColor),
                          filled: true,
                          fillColor: kBgColor,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: kBorderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: kBorderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: kAccentColor),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 44,
                      width: 44,
                      child: ElevatedButton(
                        onPressed: _isRunning
                            ? null
                            : () => _submitQuestion(_inputController.text),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kAccentColor,
                          foregroundColor: kBgColor,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isRunning
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: kBgColor,
                                ),
                              )
                            : const Icon(Icons.arrow_upward_rounded, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEvidencePane() {
    return Container(
      color: kBgColor,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Section Title & Route Chip Header
          Row(
            children: [
              const Text(
                'Evidence',
                style: TextStyle(
                  color: kTextColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
              const Spacer(),
              if (_latestResult != null)
                Text(
                  '${_latestResult!.milliseconds} ms',
                  style: const TextStyle(
                    color: kMutedColor,
                    fontSize: 13,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFallback,
                  ),
                ),
              const SizedBox(width: 12),
              _buildRouteChip(),
            ],
          ),

          const SizedBox(height: 20),

          // Live Checklist Card
          _buildChecklistCard(),

          // Error Card (if any)
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            _buildErrorCard(),
          ],

          // Evidence Cards (Staggered Animation)
          if (_latestResult != null) ...[
            if (_latestResult!.sql != null) ...[
              const SizedBox(height: 16),
              AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                offset: _showSqlCard ? Offset.zero : const Offset(0, 0.05),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  opacity: _showSqlCard ? 1.0 : 0.0,
                  child: _buildSqlCard(_latestResult!.sql!),
                ),
              ),
            ],

            if (_latestResult!.rows.isNotEmpty) ...[
              const SizedBox(height: 16),
              AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                offset: _showRowsCard ? Offset.zero : const Offset(0, 0.05),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  opacity: _showRowsCard ? 1.0 : 0.0,
                  child: _buildRowsCard(_latestResult!.rows),
                ),
              ),
            ],

            if (_latestResult!.chunks.isNotEmpty) ...[
              const SizedBox(height: 16),
              AnimatedSlide(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                offset: _showChunksCard ? Offset.zero : const Offset(0, 0.05),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  opacity: _showChunksCard ? 1.0 : 0.0,
                  child: _buildChunksCard(_latestResult!.chunks),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildRouteChip() {
    Color chipColor = kBorderColor;
    String label = 'READY';

    if (_activeRoute != null) {
      label = _activeRoute!.toUpperCase();
      switch (_activeRoute) {
        case 'sql':
          chipColor = kRouteSql;
          break;
        case 'vector':
          chipColor = kRouteVector;
          break;
        case 'both':
          chipColor = kRouteBoth;
          break;
        case 'none':
          chipColor = kMutedColor;
          break;
      }
    }

    final isKnown = _activeRoute != null;

    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 1.0, end: isKnown ? 1.05 : 1.0),
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: chipColor, width: 1.5),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: chipColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                fontFamily: 'Inter',
                fontFamilyFallback: kTextFallback,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildChecklistCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPanelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Execution Pipeline',
            style: TextStyle(
              color: kMutedColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'Inter',
              fontFamilyFallback: kTextFallback,
            ),
          ),
          const SizedBox(height: 12),
          ..._steps.map((step) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeOutCubic,
                        child: _buildStepIcon(step.status),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    step.name,
                    style: TextStyle(
                      color: step.status == StepStatus.running ||
                              step.status == StepStatus.completed
                          ? kTextColor
                          : kMutedColor,
                      fontSize: 14,
                      fontWeight: step.status == StepStatus.running
                          ? FontWeight.w600
                          : FontWeight.w400,
                      fontFamily: 'Inter',
                      fontFamilyFallback: kTextFallback,
                    ),
                  ),
                  const Spacer(),
                  if (step.elapsedMs > 0)
                    Text(
                      '${step.elapsedMs} ms',
                      style: const TextStyle(
                        color: kMutedColor,
                        fontSize: 12,
                        fontFamily: 'JetBrainsMono',
                        fontFamilyFallback: kMonoFallback,
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStepIcon(StepStatus status) {
    switch (status) {
      case StepStatus.running:
        return const SizedBox(
          key: ValueKey('running'),
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kAccentColor,
          ),
        );
      case StepStatus.completed:
        return const Icon(
          Icons.check_circle_rounded,
          key: ValueKey('completed'),
          color: kAccentColor,
          size: 16,
        );
      case StepStatus.skipped:
        return Icon(
          Icons.remove_circle_outline,
          key: const ValueKey('skipped'),
          color: kMutedColor.withValues(alpha: 0.5),
          size: 14,
        );
      case StepStatus.pending:
        return Container(
          key: const ValueKey('pending'),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: kMutedColor.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
        );
    }
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1517),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Color(0xFFF87171), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Query Execution Issue',
                style: TextStyle(
                  color: Color(0xFFF87171),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              if (_lastQuestion != null && !_isRunning)
                TextButton.icon(
                  onPressed: () => _submitQuestion(_lastQuestion!),
                  icon: const Icon(Icons.refresh_rounded, size: 14, color: kTextColor),
                  label: const Text('Retry', style: TextStyle(color: kTextColor, fontSize: 13)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    backgroundColor: kBorderColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage ?? '',
            style: const TextStyle(
              color: Color(0xFFFCA5A5),
              fontSize: 13,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: kMonoFallback,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSqlCard(String sql) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPanelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Generated SQL Query',
                style: TextStyle(
                  color: kMutedColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
              const Spacer(),
              // Tier 2: Copy SQL button
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 16, color: kMutedColor),
                tooltip: 'Copy SQL',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: sql));
                  _showToast('SQL copied to clipboard');
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kBgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorderColor),
            ),
            // Tier 2: Simple Keyword Coloring using TextSpan
            child: SelectableText.rich(
              _highlightSql(sql),
            ),
          ),
        ],
      ),
    );
  }

  TextSpan _highlightSql(String sql) {
    final keywords = {
      'SELECT', 'FROM', 'WHERE', 'GROUP', 'BY', 'ORDER', 'SUM',
      'COUNT', 'AVG', 'AND', 'OR', 'AS', 'LIMIT', 'NOT', 'IN'
    };

    final spans = <TextSpan>[];
    final regex = RegExp(r"('(?:''|[^'])*'|\b\w+\b|[^\w\s']+|\s+)");
    final matches = regex.allMatches(sql);

    for (final m in matches) {
      final token = m.group(0)!;
      final upper = token.toUpperCase();
      if (keywords.contains(upper)) {
        spans.add(TextSpan(
          text: token,
          style: const TextStyle(
            color: Color(0xFF60A5FA), // Accent blue keyword
            fontWeight: FontWeight.w700,
          ),
        ));
      } else if (token.startsWith("'")) {
        spans.add(TextSpan(
          text: token,
          style: const TextStyle(
            color: Color(0xFF34D399), // Green string literals
          ),
        ));
      } else if (RegExp(r'^\d+(\.\d+)?$').hasMatch(token)) {
        spans.add(TextSpan(
          text: token,
          style: const TextStyle(
            color: Color(0xFFFBBF24), // Amber numbers
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: token,
          style: const TextStyle(
            color: kTextColor,
          ),
        ));
      }
    }

    return TextSpan(
      style: const TextStyle(
        fontSize: 13.5,
        fontFamily: 'JetBrainsMono',
        fontFamilyFallback: kMonoFallback,
        height: 1.4,
      ),
      children: spans,
    );
  }

  Widget _buildRowsCard(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.first.keys.toList();
    final isQuestion3 = _lastQuestion != null &&
        (_lastQuestion!.toLowerCase().contains('break') ||
            _lastQuestion!.toLowerCase().contains('refund policy'));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPanelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Result Rows',
                style: TextStyle(
                  color: kMutedColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
              const Spacer(),
              Text(
                '${rows.length} row(s)',
                style: const TextStyle(
                  color: kMutedColor,
                  fontSize: 12,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Tier 2: Staggered row fade-in + amber left border for question 3
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row
                Container(
                  color: kBgColor,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: columns.map((col) {
                      return SizedBox(
                        width: 110,
                        child: Text(
                          col,
                          style: const TextStyle(
                            color: kMutedColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: kMonoFallback,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                // Data Rows with Staggered Fade-in
                ...rows.asMap().entries.map((entry) {
                  final rowIndex = entry.key;
                  final row = entry.value;

                  return TweenAnimationBuilder<double>(
                    duration: Duration(milliseconds: 200 + (rowIndex * 50)),
                    curve: Curves.easeOutCubic,
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    builder: (context, opacity, child) {
                      return Opacity(
                        opacity: opacity,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isQuestion3
                                ? const Color(0xFFFBBF24).withValues(alpha: 0.05)
                                : (rowIndex % 2 == 0 ? kPanelColor : kBgColor),
                            border: Border(
                              bottom: const BorderSide(color: kBorderColor, width: 0.5),
                              left: isQuestion3
                                  ? const BorderSide(color: Color(0xFFFBBF24), width: 3.5)
                                  : BorderSide.none,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: columns.map((col) {
                              final val = row[col];
                              return SizedBox(
                                width: 110,
                                child: Text(
                                  val?.toString() ?? 'null',
                                  style: TextStyle(
                                    color: isQuestion3 && col == 'id'
                                        ? const Color(0xFFFBBF24)
                                        : kTextColor,
                                    fontSize: 13,
                                    fontFamily: 'JetBrainsMono',
                                    fontFamilyFallback: kMonoFallback,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      );
                    },
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChunksCard(List<Chunk> chunks) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPanelColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Retrieved Policy Excerpts',
            style: TextStyle(
              color: kMutedColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'Inter',
              fontFamilyFallback: kTextFallback,
            ),
          ),
          const SizedBox(height: 12),
          ...chunks.asMap().entries.map((entry) {
            final idx = entry.key;
            final chunk = entry.value;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kBgColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kBorderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: kRouteVector.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Rank #${idx + 1}',
                          style: const TextStyle(
                            color: kRouteVector,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        chunk.source,
                        style: const TextStyle(
                          color: kMutedColor,
                          fontSize: 12,
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: kMonoFallback,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Score: ${chunk.score.toStringAsFixed(4)}',
                        style: const TextStyle(
                          color: kAccentColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: kMonoFallback,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Tier 2: Animated similarity score bar
                  _buildScoreBar(chunk.score),
                  const SizedBox(height: 10),
                  Text(
                    chunk.text,
                    style: const TextStyle(
                      color: kTextColor,
                      fontSize: 13.5,
                      height: 1.4,
                      fontFamily: 'Inter',
                      fontFamilyFallback: kTextFallback,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildScoreBar(double score) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0.0, end: score),
      builder: (context, val, child) {
        return Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Container(
                  height: 4.5,
                  color: kBorderColor,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: val.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: kRouteVector,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(val * 100).toStringAsFixed(1)}%',
              style: const TextStyle(
                color: kAccentColor,
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: kMonoFallback,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final textToShow = message.revealedText ?? message.text;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: kAccentColor.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(color: kAccentColor.withValues(alpha: 0.4)),
              ),
              child: const Center(
                child: Text('W',
                    style: TextStyle(
                        color: kAccentColor,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF1E293B) : kPanelColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isUser ? const Color(0xFF334155) : kBorderColor,
                ),
              ),
              child: Text(
                textToShow,
                style: TextStyle(
                  color: isUser ? Colors.white : kTextColor,
                  fontSize: 14.5,
                  height: 1.45,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 28),
        ],
      ),
    );
  }
}

class _DemoChip extends StatefulWidget {
  final String text;
  final bool enabled;
  final VoidCallback onTap;

  const _DemoChip({
    required this.text,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_DemoChip> createState() => _DemoChipState();
}

class _DemoChipState extends State<_DemoChip> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      onEnter: (_) {
        if (widget.enabled) setState(() => _isHovered = true);
      },
      onExit: (_) {
        setState(() {
          _isHovered = false;
          _isPressed = false;
        });
      },
      child: GestureDetector(
        onTapDown: (_) {
          if (widget.enabled) setState(() => _isPressed = true);
        },
        onTapUp: (_) {
          if (widget.enabled) {
            setState(() => _isPressed = false);
            widget.onTap();
          }
        },
        onTapCancel: () {
          setState(() => _isPressed = false);
        },
        child: AnimatedScale(
          scale: _isPressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _isHovered ? const Color(0xFF1F2430) : kBgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isHovered ? kAccentColor.withValues(alpha: 0.6) : kBorderColor,
                width: 1,
              ),
            ),
            child: Text(
              widget.text,
              style: TextStyle(
                color: _isHovered ? kTextColor : kMutedColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                fontFamily: 'Inter',
                fontFamilyFallback: kTextFallback,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension _StepListExt on List<StepInfo> {
  int indexKey(String stepName) {
    for (int i = 0; i < length; i++) {
      if (this[i].name.toLowerCase() == stepName.toLowerCase()) return i;
    }
    return -1;
  }
}
