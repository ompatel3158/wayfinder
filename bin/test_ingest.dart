import 'dart:io';
import 'package:wayfinder/db.dart';
import 'package:wayfinder/ingest.dart';

Future<void> main() async {
  stdout.writeln('Initializing database and ingesting data...');
  final db = AppDatabase.instance;
  await db.init();

  await ingestData();

  final invoiceCount = await db.countInvoices();
  final chunkCount = await db.countChunks();
  stdout.writeln('Ingested $invoiceCount invoices and $chunkCount policy chunks.');

  stdout.writeln('\nRunning checkpoint vector search for: "refund deadline"');
  final results = await searchPolicy('refund deadline', k: 3);

  stdout.writeln('\n--- VECTOR SEARCH RESULTS ---');
  for (int i = 0; i < results.length; i++) {
    final c = results[i];
    stdout.writeln('[${i + 1}] Source: ${c.source} | Score: ${c.score.toStringAsFixed(4)}');
    stdout.writeln('    Text: ${c.text}\n');
  }

  // Verify that top chunk is the refund deadline rule
  if (results.isNotEmpty &&
      results.first.source == 'refund_policy.txt' &&
      results.first.text.contains('30 days')) {
    stdout.writeln('CHECKPOINT PASSED: Top chunk correctly matches the refund deadline policy!');
  } else {
    stdout.writeln('CHECKPOINT FAILED: Unexpected top chunk.');
    exitCode = 1;
  }
}
