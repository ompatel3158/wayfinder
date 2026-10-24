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

Future<AgentResult> ask(String question) async {
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
  const routerSystemPrompt = '''
You route questions for a small database assistant. Sources:
1. SQL table invoices(id, vendor, category, amount, invoice_date, refund_amount, refund_days, approved). approved is 0 or 1.
2. Policy documents (refund policy, expense policy, vendor terms), searched by meaning.
Choose a route:
- "sql": needs totals, counts, filters or lists from invoices only.
- "vector": needs information from the policy documents only.
- "both": needs policy rules to judge or filter invoice rows.
Return JSON only: {"route": "...", "search_query": "rules and limits for [topic], empty if route is sql", "sql_intent": "one sentence on what to compute from invoices, empty if route is vector"}
''';

  final routerSchema = {
    'name': 'router_decision',
    'type': 'object',
    'properties': {
      'route': {
        'type': 'string',
        'description': 'One of: sql, vector, both',
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

  String rawRoute = (routeDecision['route'] as String? ?? 'both').toLowerCase().trim();
  String route;
  if (rawRoute.contains('both')) {
    route = 'both';
  } else if (rawRoute.contains('sql')) {
    route = 'sql';
  } else if (rawRoute.contains('vec')) {
    route = 'vector';
  } else {
    route = 'both';
  }

  final searchQuery = (routeDecision['search_query'] as String? ?? '').trim();
  final sqlIntent = (routeDecision['sql_intent'] as String? ?? '').trim();

  List<Chunk> chunks = [];
  List<Map<String, dynamic>> rows = [];
  String? generatedSql;
  String? errorMessage;

  // 2. VECTOR SEARCH (if route is vector or both)
  if (route == 'vector' || route == 'both') {
    final queryText = searchQuery.isNotEmpty ? searchQuery : question;
    try {
      chunks = await searchPolicy(queryText, k: route == 'both' ? 5 : 3);
    } catch (e) {
      errorMessage = 'Vector search failed: $e';
    }
  }

  // 3. SQL GENERATION (if route is sql or both)
  if (route == 'sql' || route == 'both') {
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
  final rowsSummary = rows.isNotEmpty
      ? jsonEncode(rows)
      : 'none';
  final chunksSummary = chunks.isNotEmpty
      ? chunks.map((c) => '[${c.source} (score: ${c.score.toStringAsFixed(2)})]: ${c.text}').join('\n')
      : 'none';

  final answerPrompt = '''
Answer the question using ONLY the data below. Do not invent numbers.
If neither the SQL rows nor policy excerpts contain matching information, say nothing matched.
If SQL rows are provided, list each invoice ID and state which policy rule it breaks.
If you used a policy rule, name it. Maximum 4 sentences.
Question: $question
SQL rows: $rowsSummary
Policy excerpts: $chunksSummary
''';

  String answer = '';
  try {
    answer = await chat(
      [
        {'role': 'user', 'content': answerPrompt},
      ],
      temp: 0.2,
      maxTokens: 250,
    );
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
