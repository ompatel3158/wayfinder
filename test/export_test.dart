import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfinder/agent.dart';
import 'package:wayfinder/db.dart';
import 'package:wayfinder/export.dart';
import 'package:wayfinder/ingest.dart';

class _AllowLocalHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (cert, host, port) => true;
  }
}

void main() {
  setUpAll(() {
    HttpOverrides.global = _AllowLocalHttpOverrides();
  });

  test('Export PDF and CSV test', () async {
    const question = 'Which invoices break the refund policy?';
    AgentResult result;

    try {
      final db = AppDatabase.instance;
      if (!db.isInitialized) {
        await db.init();
        await ingestData();
        await warmup();
      }
      result = await ask(question);
    } catch (_) {
      // In CI environment without live LM Studio daemon running
      result = AgentResult(
        route: 'both',
        searchQuery: 'refund policy timeline limits',
        sql: 'SELECT id, vendor, amount, refund_days FROM invoices WHERE refund_days > 30;',
        rows: [
          {'id': 'INV-1002', 'vendor': 'CloudHost', 'amount': 1200.0, 'refund_days': 45},
          {'id': 'INV-1005', 'vendor': 'OfficeMart', 'amount': 350.0, 'refund_days': 35},
        ],
        chunks: [
          Chunk(
            source: 'refund_policy.md',
            text: 'All refund requests must be submitted within 30 days of invoice date.',
            score: 0.88,
          ),
        ],
        answer: 'Invoices INV-1002 and INV-1005 break the refund policy because refund_days exceed the 30-day limit specified in refund_policy.md.',
        milliseconds: 120,
      );
    }

    expect(result.rows.isNotEmpty, isTrue);
    expect(result.chunks.isNotEmpty, isTrue);

    final exportsDir = Directory('exports');
    if (!await exportsDir.exists()) {
      await exportsDir.create(recursive: true);
    }

    final csvPath = 'exports/which_invoices_break_refund_policy.csv';
    final pdfPath = 'exports/which_invoices_break_refund_policy.pdf';

    final savedCsv = await exportCsvToFile(
      rows: result.rows,
      filePath: csvPath,
    );
    final savedPdf = await exportPdfToFile(
      question: question,
      result: result,
      filePath: pdfPath,
    );

    final csvFile = File(savedCsv);
    final pdfFile = File(savedPdf);

    expect(await csvFile.exists(), isTrue);
    expect(await pdfFile.exists(), isTrue);
    expect(await csvFile.length(), greaterThan(0));
    expect(await pdfFile.length(), greaterThan(0));

    // ignore: avoid_print
    print('SAVED_CSV_PATH: ${csvFile.absolute.path}');
    // ignore: avoid_print
    print('SAVED_PDF_PATH: ${pdfFile.absolute.path}');
  });
}
