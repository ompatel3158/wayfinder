import 'dart:io';
import 'package:wayfinder/agent.dart';
import 'package:wayfinder/db.dart';
import 'package:wayfinder/ingest.dart';

Future<void> main(List<String> args) async {
  stdout.writeln('==============================================');
  stdout.writeln('  Wayfinder CLI - Local Offline AI Agent');
  stdout.writeln('==============================================');

  final db = AppDatabase.instance;
  if (!db.isInitialized) {
    stdout.write('Initializing database and ingesting data... ');
    await db.init();
    await ingestData();
    stdout.writeln('Ready.');
    stdout.write('Warming up local LLM... ');
    await warmup();
    stdout.writeln('Ready.');
  }

  if (args.contains('--test')) {
    final testQuestions = [
      'What is the total refund amount for Travel?',
      'How many days do I have to request a refund?',
      'Which invoices break the refund policy?',
      'who are you',
      'hello',
    ];

    for (int i = 0; i < testQuestions.length; i++) {
      stdout.writeln('\n----------------------------------------------');
      stdout.writeln('TEST QUESTION ${i + 1}: "${testQuestions[i]}"');
      stdout.writeln('----------------------------------------------');
      await _handleQuestion(testQuestions[i]);
    }
    return;
  }

  stdout.writeln('\nEnter questions (or type "exit" to quit):\n');

  while (true) {
    stdout.write('Question> ');
    final line = stdin.readLineSync();
    if (line == null || line.trim().toLowerCase() == 'exit') {
      stdout.writeln('Goodbye!');
      break;
    }
    final q = line.trim();
    if (q.isEmpty) continue;

    await _handleQuestion(q);
    stdout.writeln();
  }
}

Future<void> _handleQuestion(String question) async {
  final result = await ask(question);

  stdout.writeln('Route:        ${result.route.toUpperCase()}');
  if (result.searchQuery.isNotEmpty) {
    stdout.writeln('Search Query: "${result.searchQuery}"');
  }
  if (result.sql != null) {
    stdout.writeln('SQL:          ${result.sql}');
  }
  if (result.rows.isNotEmpty) {
    stdout.writeln('Rows (${result.rows.length}):');
    for (final row in result.rows) {
      stdout.writeln('  - $row');
    }
  } else if (result.sql != null) {
    stdout.writeln('Rows:         (0 rows)');
  }

  if (result.chunks.isNotEmpty) {
    stdout.writeln('Chunks (${result.chunks.length}):');
    for (int idx = 0; idx < result.chunks.length; idx++) {
      final chunk = result.chunks[idx];
      stdout.writeln(
        '  - [Rank #${idx + 1} | ${chunk.source} | Score: ${chunk.score.toStringAsFixed(4)}] ${chunk.text}',
      );
    }
  }

  if (result.error != null) {
    stdout.writeln('Error:        ${result.error}');
  }

  stdout.writeln('Answer:       ${result.answer}');
  stdout.writeln('Elapsed:      ${result.milliseconds} ms');
}
