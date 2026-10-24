import 'dart:io';
import 'db.dart';
import 'llm.dart';

Future<void> ingestData({String dataDir = 'assets/data'}) async {
  final db = AppDatabase.instance;
  if (!db.isInitialized) {
    await db.init();
  }

  // 1. Ingest Invoices CSV
  final csvFile = File('$dataDir/invoices.csv');
  if (await csvFile.exists()) {
    final lines = await csvFile.readAsLines();
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length >= 8) {
        await db.insertInvoice(
          id: parts[0].trim(),
          vendor: parts[1].trim(),
          category: parts[2].trim(),
          amount: double.tryParse(parts[3].trim()) ?? 0.0,
          invoiceDate: parts[4].trim(),
          refundAmount: double.tryParse(parts[5].trim()) ?? 0.0,
          refundDays: int.tryParse(parts[6].trim()) ?? 0,
          approved: int.tryParse(parts[7].trim()) ?? 0,
        );
      }
    }
  }

  // 2. Ingest Policy Documents
  final policyFiles = [
    'refund_policy.txt',
    'expense_policy.txt',
    'vendor_terms.txt',
  ];

  int chunkId = 1;
  for (final filename in policyFiles) {
    final file = File('$dataDir/$filename');
    if (!await file.exists()) continue;

    final content = await file.readAsString();
    final chunks = _splitIntoChunks(content);

    for (final chunk in chunks) {
      final embedding = await embed(chunk);
      await db.insertChunk(
        id: chunkId++,
        content: chunk,
        source: filename,
        embedding: embedding,
      );
    }
  }
}

List<String> _splitIntoChunks(String text) {
  // Split by double line-breaks into cohesive 3-sentence paragraphs
  final paragraphs = text
      .split(RegExp(r'\r?\n\s*\r?\n'))
      .map((p) => p.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((p) => p.isNotEmpty)
      .toList();
  return paragraphs;
}

Future<List<Chunk>> searchPolicy(String query, {int k = 3}) async {
  final queryVec = await embed(query);
  return await AppDatabase.instance.searchPolicyChunks(queryVec, k: k);
}
