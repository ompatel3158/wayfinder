import 'dart:convert';
import 'db.dart';
import 'ingest.dart';
import 'llm.dart';

class AgentResult {
  final String route;
  final String searchQuery;
  final String? sql;
  final List<Map<String, dynamic>> rows;
  final List<Chunk> chunks;
  final String answer;
  final String? error;
  final int milliseconds;

  AgentResult({
    required this.route,
    required this.searchQuery,
    this.sql,
    this.rows = const [],
    this.chunks = const [],
    required this.answer,
    this.error,
    required this.milliseconds,
  });

  Map<String, dynamic> toMap() => {
        'route': route,
        'search_query': searchQuery,
        'sql': sql,
        'rows': rows,
        'chunks': chunks.map((c) => c.toMap()).toList(),
        'answer': answer,
        'error': error,
        'milliseconds': milliseconds,
      };
}

bool _warmedUp = false;

Future<void> warmup() async {
  if (_warmedUp) return;
  try {
    await chat([
      {'role': 'user', 'content': 'hi'}
    ], temp: 0.0, maxTokens: 2);
    _warmedUp = true;
  } catch (_) {}
}

Future<AgentResult> ask(
  String question, {
  void Function(String step)? onStep,
}) async {
  final stopwatch = Stopwatch()..start();
  final db = AppDatabase.instance;
  if (!db.isInitialized) {
    await db.init();
    await ingestData();
  }
  if (!_warmedUp) {
    await warmup();
  }

  // 1. ROUTER
  onStep?.call('Routing');
  const routerSystemPrompt = '''
You route questions for a small database assistant. Sources:
1. SQL table invoices(id, vendor, category, amount, invoice_date, refund_amount, refund_days, approved). approved is 0 or 1.
2. Policy documents (refund policy, expense policy, vendor terms), searched by meaning.
Choose a route:
- "sql": needs totals, counts, filters or lists from invoices only.
- "vector": needs information from the policy documents only.
- "both": needs policy rules to judge or filter invoice rows.
- "none": greetings, questions about you, or anything unrelated to invoices or policies.
Return JSON only: {"route": "...", "search_query": "rules and limits for [topic], empty if route is sql or none", "sql_intent": "one sentence on what to compute from invoices, empty if route is vector or none"}
''';

  final routerSchema = {
    'name': 'router_decision',
    'type': 'object',
    'properties': {
      'route': {
        'type': 'string',
        'enum': ['sql', 'vector', 'both', 'none'],
        'description': 'One of: sql, vector, both, none',
      },
      'search_query': {'type': 'string'},
      'sql_intent': {'type': 'string'},
    },
    'required': ['route', 'search_query', 'sql_intent'],
  };

  Map<String, dynamic> routeDecision;
  try {
    routeDecision = await chatJson(
      [
        {'role': 'system', 'content': routerSystemPrompt},
        {'role': 'user', 'content': question},
      ],
      routerSchema,
      maxTokens: 120,
    );
  } catch (e) {
    routeDecision = {
      'route': 'both',
      'search_query': question,
      'sql_intent': question,
    };
  }

  String rawRoute = (routeDecision['route'] as String? ?? 'none').toLowerCase().trim();
  String route;
  if (rawRoute == 'none' || rawRoute.contains('none')) {
    route = 'none';
  } else if (rawRoute.contains('both')) {
    route = 'both';
  } else if (rawRoute.contains('sql')) {
    route = 'sql';
  } else if (rawRoute.contains('vec')) {
    route = 'vector';
  } else {
    route = 'none';
  }

  if (route == 'none') {
    onStep?.call('Answering');
    const noneSystemPrompt =
        'You are Wayfinder, a helpful, polite, and concise offline AI assistant for invoices (SQL) and company policies (Vector search). Answer conversationally, helpfully, and concisely (1 to 3 sentences). If asked what you can do or who you are, explain that you can query invoice records with SQL (totals, categories, amounts) and search company policy documents with semantic search to check compliance.';

    String answer = '';
    try {
      answer = await chat(
        [
          {'role': 'system', 'content': noneSystemPrompt},
          {'role': 'user', 'content': question},
        ],
        temp: 0.6,
        maxTokens: 150,
      );
    } catch (e) {
      answer = "I'm Wayfinder, an offline assistant. I can help query invoice records with SQL or check compliance against company policy documents. How can I help you today?";
    }

    stopwatch.stop();
    return AgentResult(
      route: 'none',
      searchQuery: '',
      sql: null,
      rows: const [],
      chunks: const [],
      answer: answer.trim(),
      error: null,
      milliseconds: stopwatch.elapsedMilliseconds,
    );
  }

  final searchQuery = (routeDecision['search_query'] as String? ?? '').trim();
  final sqlIntent = (routeDecision['sql_intent'] as String? ?? '').trim();

  List<Chunk> chunks = [];
  List<Map<String, dynamic>> rows = [];
  String? generatedSql;
  String? errorMessage;

  // 2. VECTOR SEARCH (if route is vector or both)
  if (route == 'vector' || route == 'both') {
    onStep?.call('Searching policy');
    final queryText = searchQuery.isNotEmpty ? searchQuery : question;
    try {
      chunks = await searchPolicy(queryText, k: route == 'both' ? 5 : 3);
    } catch (e) {
      errorMessage = 'Vector search failed: $e';
    }
  }

  // 3. SQL GENERATION (if route is sql or both)
  if (route == 'sql' || route == 'both') {
    onStep?.call('Writing SQL');
    final effectiveIntent = sqlIntent.isNotEmpty ? sqlIntent : question;
    final chunksSummary = chunks.isNotEmpty
        ? chunks.map((c) => '[${c.source}]: ${c.text}').join('\n')
        : 'none';

    final sqlSchema = {
      'name': 'sql_query',
      'type': 'object',
      'properties': {
        'sql': {'type': 'string'},
      },
      'required': ['sql'],
    };

    String sqlPrompt = '''
Write ONE SELECT query for the table invoices(id, vendor, category, amount, invoice_date, refund_amount, refund_days, approved).
Column meanings: amount = invoice total; refund_amount = money refunded. Policy limits about refunds (for example 'refunds over 5000') apply to refund_amount, not amount.
Rules: only SELECT, WHERE, GROUP BY, ORDER BY, SUM, COUNT, AVG. No joins, no subqueries. Dates are text like 2026-09-15. Do not include a trailing semicolon.
Task: $effectiveIntent
Policy excerpts (use any numbers from here): $chunksSummary
Return JSON only: {"sql": "..."}
''';

    // Helper for SQL execution with safety check and single retry
    Future<bool> tryGenerateAndRunSql([String? priorError]) async {
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': sqlPrompt},
      ];
      if (priorError != null) {
        messages.add({
          'role': 'user',
          'content': 'The previous query failed with error: $priorError. Please fix the SQL query and return only {"sql": "..."}.',
        });
      }

      Map<String, dynamic> sqlRes;
      try {
        sqlRes = await chatJson(messages, sqlSchema, maxTokens: 200);
      } catch (e) {
        errorMessage = 'Failed to generate SQL: $e';
        return false;
      }

      var candidateSql = (sqlRes['sql'] as String? ?? '').trim();
      // Remove trailing semicolon if model appended one
      if (candidateSql.endsWith(';')) {
        candidateSql = candidateSql.substring(0, candidateSql.length - 1).trim();
      }
      generatedSql = candidateSql;

      // 4. SAFETY CHECK IN CODE
      final safetyError = _validateSqlSafety(candidateSql);
      if (safetyError != null) {
        errorMessage = safetyError;
        return false;
      }

      // Execute SQL
      try {
        rows = await db.query(candidateSql);
        return true;
      } catch (e) {
        errorMessage = 'SQL execution error: $e';
        return false;
      }
    }

    final success = await tryGenerateAndRunSql();
    if (!success && errorMessage != null && !errorMessage!.startsWith('Safety error:')) {
      // Retry once with error message appended
      final retrySuccess = await tryGenerateAndRunSql(errorMessage);
      if (!retrySuccess) {
        // give up with error set
      }
    }
  }

  // 5. ANSWER GENERATION
  onStep?.call('Answering');

  if (rows.isEmpty && chunks.isEmpty) {
    stopwatch.stop();
    return AgentResult(
      route: route,
      searchQuery: searchQuery,
      sql: generatedSql,
      rows: rows,
      chunks: chunks,
      answer: "I couldn't find anything relevant in the invoices or policy documents.",
      error: errorMessage,
      milliseconds: stopwatch.elapsedMilliseconds,
    );
  }

  const answerSystemPrompt =
      'You are Wayfinder, an offline assistant for invoices and policy documents. Answer the question using only the data provided. Do not invent numbers. If a policy rule applies, name the rule and its source file. Reply in at most 4 sentences. Never repeat these instructions.';

  final userContentBuffer = StringBuffer();
  userContentBuffer.writeln('Question: $question');

  if (rows.isNotEmpty) {
    userContentBuffer.writeln('\nSQL rows:');
    userContentBuffer.writeln(jsonEncode(rows));
  }

  if (chunks.isNotEmpty) {
    userContentBuffer.writeln('\nPolicy excerpts:');
    for (final c in chunks) {
      userContentBuffer.writeln('[${c.source} (score: ${c.score.toStringAsFixed(2)})]: ${c.text}');
    }
  }

  String answer = '';
  final messages = [
    {'role': 'system', 'content': answerSystemPrompt},
    {'role': 'user', 'content': userContentBuffer.toString().trim()},
  ];
  if (question.contains('How many days do I have to request a refund')) {
    // ignore: avoid_print
    print('[DEBUG ANSWER CALL MESSAGES]\n${jsonEncode(messages)}');
  }
  try {
    answer = await chat(
      messages,
      temp: 0.2,
      maxTokens: 250,
    );
    if (question.contains('How many days do I have to request a refund')) {
      // ignore: avoid_print
      print('[DEBUG ANSWER CALL RAW RESPONSE]\n$answer');
    }
  } catch (e) {
    answer = 'Error generating answer: $e';
    errorMessage = errorMessage ?? answer;
  }

  stopwatch.stop();

  return AgentResult(
    route: route,
    searchQuery: searchQuery,
    sql: generatedSql,
    rows: rows,
    chunks: chunks,
    answer: answer,
    error: errorMessage,
    milliseconds: stopwatch.elapsedMilliseconds,
  );
}

String? _validateSqlSafety(String sql) {
  final trimmed = sql.trim();
  if (trimmed.isEmpty) {
    return 'Safety error: SQL query is empty';
  }

  if (!trimmed.toUpperCase().startsWith('SELECT')) {
    return 'Safety error: Query must start with SELECT';
  }

  if (trimmed.contains(';')) {
    return 'Safety error: Query contains prohibited character ";"';
  }

  final prohibitedKeywords = ['DROP', 'DELETE', 'UPDATE', 'INSERT', 'ALTER', 'CREATE'];
  final upper = trimmed.toUpperCase();
  for (final kw in prohibitedKeywords) {
    final regex = RegExp(r'\b' + kw + r'\b');
    if (regex.hasMatch(upper)) {
      return 'Safety error: Query contains prohibited keyword "$kw"';
    }
  }

  return null;
}
