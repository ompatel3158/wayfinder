import 'dart:async';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agent.dart';
import 'config.dart';
import 'db.dart';
import 'export.dart';
import 'ingest.dart';
import 'registry.dart';

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
  final AgentResult? result;
  final String? question;

  ChatMessage({
    required this.isUser,
    required this.text,
    this.revealedText,
    this.result,
    this.question,
  });
}

class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  final List<ChatMessage> messages;
  AgentResult? latestResult;
  String? activeRoute;
  String? errorMessage;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
    this.latestResult,
    this.activeRoute,
    this.errorMessage,
  });
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

  final List<ChatSession> _sessions = [];
  int _currentSessionIndex = 0;

  ChatSession get _currentSession {
    if (_sessions.isEmpty) {
      _sessions.add(ChatSession(
        id: '1',
        title: 'New Chat',
        createdAt: DateTime.now(),
        messages: [],
      ));
    }
    return _sessions[_currentSessionIndex];
  }

  List<ChatMessage> get _messages => _currentSession.messages;

  bool _isRunning = false;
  String? _lastQuestion;

  // Evidence state
  AgentResult? _latestResult;
  String? _activeRoute;
  String? _errorMessage;

  // Import and drag state
  bool _isDragging = false;
  bool _isImporting = false;
  double _importProgress = 0.0;
  String _importStatus = '';

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

  void _createNewChat() {
    _wordRevealTimer?.cancel();
    setState(() {
      final newSession = ChatSession(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'Chat ${_sessions.length + 1}',
        createdAt: DateTime.now(),
        messages: [],
      );
      _sessions.add(newSession);
      _currentSessionIndex = _sessions.length - 1;
      _latestResult = null;
      _activeRoute = null;
      _errorMessage = null;
      _showSqlCard = false;
      _showRowsCard = false;
      _showChunksCard = false;
      for (var s in _steps) {
        s.status = StepStatus.pending;
        s.elapsedMs = 0;
      }
      _currentStepIndex = -1;
    });
    _scrollToBottom();
  }

  void _switchSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    _wordRevealTimer?.cancel();
    setState(() {
      _currentSessionIndex = index;
      final session = _sessions[index];
      _latestResult = session.latestResult;
      _activeRoute = session.activeRoute;
      _errorMessage = session.errorMessage;
      _showSqlCard = session.latestResult?.sql != null;
      _showRowsCard = session.latestResult?.rows.isNotEmpty ?? false;
      _showChunksCard = session.latestResult?.chunks.isNotEmpty ?? false;
      for (var s in _steps) {
        s.status = StepStatus.pending;
        s.elapsedMs = 0;
      }
      _currentStepIndex = -1;
    });
    _scrollToBottom();
  }

  void _deleteSession(int index) {
    setState(() {
      _sessions.removeAt(index);
      if (_sessions.isEmpty) {
        _sessions.add(ChatSession(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: 'New Chat',
          createdAt: DateTime.now(),
          messages: [],
        ));
        _currentSessionIndex = 0;
      } else if (_currentSessionIndex >= _sessions.length) {
        _currentSessionIndex = _sessions.length - 1;
      }
      final session = _sessions[_currentSessionIndex];
      _latestResult = session.latestResult;
      _activeRoute = session.activeRoute;
      _errorMessage = session.errorMessage;
      _showSqlCard = session.latestResult?.sql != null;
      _showRowsCard = session.latestResult?.rows.isNotEmpty ?? false;
      _showChunksCard = session.latestResult?.chunks.isNotEmpty ?? false;
    });
  }

  Future<void> _importFile(File file) async {
    final fileName = file.uri.pathSegments.last;
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    if (ext != 'csv' && ext != 'json' && ext != 'txt' && ext != 'md') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unsupported file type: .$ext. Supported: CSV, JSON, TXT, MD.'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() {
      _isImporting = true;
      _importProgress = 0.0;
      _importStatus = 'Importing $fileName...';
    });

    try {
      final message = await ingestCustomFile(
        file,
        onProgress: (prog, stat) {
          if (mounted) {
            setState(() {
              _importProgress = prog;
              _importStatus = stat;
            });
          }
        },
      );
      if (mounted) {
        _showToast(message);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import $fileName: $e'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0.0;
          _importStatus = '';
        });
      }
    }
  }

  Future<void> _pickAndImportFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'json', 'txt', 'md'],
      );
      for (final f in files) {
        if (f.path != null) {
          await _importFile(File(f.path!));
        }
      }
    } catch (e) {
      _showToast('Error picking file: $e');
    }
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

    if (_messages.isEmpty) {
      _currentSession.title = q.length > 28 ? '${q.substring(0, 28)}...' : q;
    }

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

    final history = <Map<String, String>>[];
    for (int i = 0; i < _messages.length - 1; i++) {
      final m = _messages[i];
      final text = m.revealedText ?? m.text;
      if (text.isNotEmpty) {
        history.add({
          'role': m.isUser ? 'user' : 'assistant',
          'content': text,
        });
      }
    }

    try {
      final result = await ask(
        q,
        history: history,
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
        _currentSession.latestResult = result;
        _currentSession.activeRoute = result.route;
        _currentSession.errorMessage = result.error;
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

      _startWordReveal(result.answer, result: result, question: q);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _errorMessage = e.toString();
        _currentSession.errorMessage = e.toString();
        _messages.add(ChatMessage(
          isUser: false,
          text: 'An error occurred while processing the request.',
        ));
      });
      _scrollToBottom();
    }
  }

  void _startWordReveal(String fullText, {AgentResult? result, String? question}) {
    _wordRevealTimer?.cancel();
    final words = fullText.split(' ');
    if (words.isEmpty) {
      setState(() {
        _messages.add(ChatMessage(
          isUser: false,
          text: fullText,
          result: result,
          question: question,
        ));
      });
      _scrollToBottom();
      return;
    }

    int currentWordCount = 0;
    final msgIndex = _messages.length;
    _messages.add(ChatMessage(
      isUser: false,
      text: fullText,
      revealedText: '',
      result: result,
      question: question,
    ));

    _wordRevealTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      currentWordCount++;
      if (currentWordCount >= words.length) {
        timer.cancel();
        setState(() {
          if (msgIndex < _messages.length) {
            _messages[msgIndex] = ChatMessage(
              isUser: false,
              text: fullText,
              revealedText: fullText,
              result: result,
              question: question,
            );
          }
        });
      } else {
        final partial = words.take(currentWordCount).join(' ');
        setState(() {
          if (msgIndex < _messages.length) {
            _messages[msgIndex] = ChatMessage(
              isUser: false,
              text: fullText,
              revealedText: partial,
              result: result,
              question: question,
            );
          }
        });
      }
      _scrollToBottom();
    });
  }

  void _showChatHistoryDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: kPanelColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: kBorderColor),
              ),
              child: Container(
                width: 520,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.history_rounded,
                            color: kAccentColor, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          'Chat History (${_sessions.length})',
                          style: const TextStyle(
                            color: kTextColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Inter',
                            fontFamilyFallback: kTextFallback,
                          ),
                        ),
                        const Spacer(),
                        _HeaderButton(
                          icon: Icons.add_rounded,
                          label: 'New Chat',
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _createNewChat();
                          },
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: kMutedColor, size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _sessions.length,
                        separatorBuilder: (_, _) =>
                            const Divider(color: kBorderColor, height: 1),
                        itemBuilder: (context, index) {
                          final session = _sessions[index];
                          final isActive = index == _currentSessionIndex;
                          return InkWell(
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _switchSession(index);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  Icon(
                                    isActive
                                        ? Icons.chat_bubble_rounded
                                        : Icons.chat_bubble_outline_rounded,
                                    color:
                                        isActive ? kAccentColor : kMutedColor,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          session.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isActive
                                                ? kTextColor
                                                : kMutedColor,
                                            fontWeight: isActive
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${session.messages.length} messages · ${_formatTime(session.createdAt)}',
                                          style: TextStyle(
                                            color: kMutedColor.withValues(
                                                alpha: 0.7),
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isActive)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: kAccentColor.withValues(
                                            alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: kAccentColor.withValues(
                                                alpha: 0.4)),
                                      ),
                                      child: const Text(
                                        'Active',
                                        style: TextStyle(
                                          color: kAccentColor,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                        color: kMutedColor),
                                    tooltip: 'Delete Chat',
                                    onPressed: () {
                                      _deleteSession(index);
                                      setDialogState(() {});
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showDataSourcesDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final tables = DataRegistry.instance.tables.values.toList();
            final documents = DataRegistry.instance.documents.values.toList();

            return Dialog(
              backgroundColor: kPanelColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: kBorderColor),
              ),
              child: Container(
                width: 620,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.storage_rounded,
                            color: kAccentColor, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          'Data Sources (${DataRegistry.instance.totalSourcesCount})',
                          style: const TextStyle(
                            color: kTextColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Inter',
                            fontFamilyFallback: kTextFallback,
                          ),
                        ),
                        const Spacer(),
                        _HeaderButton(
                          icon: Icons.add_rounded,
                          label: 'Add Data',
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await _pickAndImportFiles();
                          },
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: kMutedColor, size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 420),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Section: SQL Tables
                            Row(
                              children: [
                                const Icon(Icons.table_chart_rounded,
                                    size: 16, color: kRouteSql),
                                const SizedBox(width: 6),
                                Text(
                                  'SQL Tables (${tables.length})',
                                  style: const TextStyle(
                                    color: kTextColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (tables.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No SQL tables currently loaded.',
                                  style: TextStyle(
                                      color: kMutedColor, fontSize: 13),
                                ),
                              )
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: tables.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(color: kBorderColor, height: 1),
                                itemBuilder: (context, index) {
                                  final tbl = tables[index];
                                  return Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color:
                                                kRouteSql.withValues(alpha: 0.1),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: const Icon(
                                              Icons.table_chart_rounded,
                                              size: 18,
                                              color: kRouteSql),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                tbl.tableName,
                                                style: const TextStyle(
                                                  color: kTextColor,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${tbl.rowCount} rows · ${tbl.columns.length} columns · source: ${tbl.sourceFileName}',
                                                style: TextStyle(
                                                  color: kMutedColor.withValues(
                                                      alpha: 0.8),
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                tbl.columns
                                                    .map((c) =>
                                                        '${c.name} (${c.type.toLowerCase()})')
                                                    .join(', '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: kMutedColor,
                                                  fontSize: 11,
                                                  fontFamily: 'JetBrainsMono',
                                                  fontFamilyFallback:
                                                      kMonoFallback,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 18,
                                              color: kMutedColor),
                                          tooltip: 'Remove Table',
                                          onPressed: () async {
                                            await AppDatabase.instance
                                                .dropTable(tbl.tableName);
                                            DataRegistry.instance
                                                .unregisterTable(tbl.tableName);
                                            setDialogState(() {});
                                            setState(() {});
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),

                            const SizedBox(height: 20),

                            // Section: Documents
                            Row(
                              children: [
                                const Icon(Icons.article_rounded,
                                    size: 16, color: kRouteVector),
                                const SizedBox(width: 6),
                                Text(
                                  'Policy & Text Documents (${documents.length})',
                                  style: const TextStyle(
                                    color: kTextColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (documents.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No documents currently loaded.',
                                  style: TextStyle(
                                      color: kMutedColor, fontSize: 13),
                                ),
                              )
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: documents.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(color: kBorderColor, height: 1),
                                itemBuilder: (context, index) {
                                  final doc = documents[index];
                                  return Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: kRouteVector
                                                .withValues(alpha: 0.1),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: const Icon(
                                              Icons.article_rounded,
                                              size: 18,
                                              color: kRouteVector),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                doc.sourceFileName,
                                                style: const TextStyle(
                                                  color: kTextColor,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${doc.chunkCount} vector embeddings indexed offline',
                                                style: TextStyle(
                                                  color: kMutedColor.withValues(
                                                      alpha: 0.8),
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 18,
                                              color: kMutedColor),
                                          tooltip: 'Remove Document',
                                          onPressed: () async {
                                            await AppDatabase.instance
                                                .deleteChunksBySource(
                                                    doc.sourceFileName);
                                            DataRegistry.instance
                                                .unregisterDocument(
                                                    doc.sourceFileName);
                                            setDialogState(() {});
                                            setState(() {});
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
      child: DropTarget(
        onDragEntered: (details) => setState(() => _isDragging = true),
        onDragExited: (details) => setState(() => _isDragging = false),
        onDragDone: (details) async {
          setState(() => _isDragging = false);
          for (final f in details.files) {
            await _importFile(File(f.path));
          }
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

                // Drag Overlay
                if (_isDragging)
                  Positioned.fill(
                    child: Container(
                      color: kBgColor.withValues(alpha: 0.85),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 40, vertical: 32),
                          decoration: BoxDecoration(
                            color: kPanelColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: kAccentColor, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: kAccentColor.withValues(alpha: 0.2),
                                blurRadius: 24,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.file_upload_outlined,
                                  color: kAccentColor, size: 48),
                              SizedBox(height: 16),
                              Text(
                                'Drop files to add data',
                                style: TextStyle(
                                  color: kTextColor,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'Inter',
                                  fontFamilyFallback: kTextFallback,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Supported: CSV, JSON, TXT, MD',
                                style: TextStyle(
                                  color: kMutedColor,
                                  fontSize: 13,
                                  fontFamily: 'Inter',
                                  fontFamilyFallback: kTextFallback,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // Importing Progress Overlay
                if (_isImporting)
                  Positioned(
                    top: 64,
                    right: 24,
                    child: Container(
                      width: 320,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: kPanelColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kAccentColor),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: kAccentColor),
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'Importing Data...',
                                style: TextStyle(
                                  color: kTextColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${(_importProgress * 100).toInt()}%',
                                style: const TextStyle(
                                  color: kAccentColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: 'JetBrainsMono',
                                  fontFamilyFallback: kMonoFallback,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value:
                                  _importProgress > 0 ? _importProgress : null,
                              backgroundColor: kBorderColor,
                              color: kAccentColor,
                              minHeight: 6,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _importStatus,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kMutedColor,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
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
                            const Icon(Icons.check_circle_rounded,
                                color: kAccentColor, size: 16),
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
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
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
          const SizedBox(width: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: kBgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '●',
                  style: TextStyle(color: kAccentColor, fontSize: 11),
                ),
                const SizedBox(width: 6),
                Text(
                  'Running locally on ${Config.chatModel.split('/').last}',
                  style: const TextStyle(
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
          _HeaderButton(
            icon: Icons.add_comment_outlined,
            label: 'New Chat',
            onTap: _createNewChat,
          ),
          const SizedBox(width: 8),
          _HeaderButton(
            icon: Icons.history_rounded,
            label: 'History (${_sessions.length})',
            onTap: _showChatHistoryDialog,
          ),
          const SizedBox(width: 8),
          _HeaderButton(
            icon: Icons.storage_rounded,
            label: 'Data Sources (${DataRegistry.instance.totalSourcesCount})',
            onTap: _showDataSourcesDialog,
          ),
          const SizedBox(width: 8),
          _HeaderButton(
            icon: Icons.add_circle_outline_rounded,
            label: 'Add Data',
            isAccent: true,
            onTap: _pickAndImportFiles,
          ),
          const SizedBox(width: 12),
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
                    return _ChatBubble(
                      message: msg,
                      onShowToast: _showToast,
                    );
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
  final void Function(String message)? onShowToast;

  const _ChatBubble({required this.message, this.onShowToast});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final textToShow = message.revealedText ?? message.text;
    final hasResults = !isUser &&
        message.result != null &&
        (message.result!.rows.isNotEmpty || message.result!.chunks.isNotEmpty);

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    textToShow,
                    style: TextStyle(
                      color: isUser ? Colors.white : kTextColor,
                      fontSize: 14.5,
                      height: 1.45,
                      fontFamily: 'Inter',
                      fontFamilyFallback: kTextFallback,
                    ),
                  ),
                  if (hasResults) ...[
                    const SizedBox(height: 10),
                    _ExportButton(
                      message: message,
                      onShowToast: onShowToast,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 28),
        ],
      ),
    );
  }
}

class _ExportButton extends StatelessWidget {
  final ChatMessage message;
  final void Function(String message)? onShowToast;

  const _ExportButton({
    required this.message,
    this.onShowToast,
  });

  @override
  Widget build(BuildContext context) {
    final result = message.result!;
    final hasRows = result.rows.isNotEmpty;

    return PopupMenuButton<String>(
      tooltip: 'Export Results',
      color: kPanelColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: kBorderColor),
      ),
      onSelected: (value) async {
        try {
          if (value == 'csv') {
            if (!hasRows) {
              onShowToast?.call('No rows to export as CSV.');
              return;
            }
            final path = await saveCsv(rows: result.rows);
            if (path != null) {
              onShowToast?.call('Saved CSV: $path');
            }
          } else if (value == 'pdf') {
            final path = await savePdfReport(
              question: message.question ?? 'Wayfinder Report',
              result: result,
            );
            if (path != null) {
              onShowToast?.call('Saved PDF: $path');
            }
          }
        } catch (e) {
          onShowToast?.call('Export failed: $e');
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'csv',
          enabled: hasRows,
          child: Row(
            children: [
              Icon(
                Icons.table_chart_outlined,
                size: 16,
                color: hasRows ? kTextColor : kMutedColor,
              ),
              const SizedBox(width: 8),
              Text(
                'CSV (result rows)',
                style: TextStyle(
                  color: hasRows ? kTextColor : kMutedColor,
                  fontSize: 13,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'pdf',
          child: Row(
            children: [
              Icon(Icons.picture_as_pdf_outlined, size: 16, color: kTextColor),
              const SizedBox(width: 8),
              Text(
                'PDF report',
                style: TextStyle(
                  color: kTextColor,
                  fontSize: 13,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: kBgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorderColor),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_rounded, size: 14, color: kAccentColor),
            SizedBox(width: 6),
            Text(
              'Export',
              style: TextStyle(
                color: kTextColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'Inter',
                fontFamilyFallback: kTextFallback,
              ),
            ),
            SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 16, color: kMutedColor),
          ],
        ),
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

class _HeaderButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isAccent;

  const _HeaderButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isAccent = false,
  });

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isAccent
        ? (_isHovered
            ? kAccentColor.withValues(alpha: 0.25)
            : kAccentColor.withValues(alpha: 0.12))
        : (_isHovered ? const Color(0xFF1F2430) : kBgColor);
    final borderColor = widget.isAccent
        ? kAccentColor.withValues(alpha: _isHovered ? 0.8 : 0.4)
        : (_isHovered ? kAccentColor.withValues(alpha: 0.5) : kBorderColor);
    final fg =
        widget.isAccent ? kAccentColor : (_isHovered ? kTextColor : kMutedColor);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'Inter',
                  fontFamilyFallback: kTextFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
