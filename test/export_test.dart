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
    final db = AppDatabase.instance;
    if (!db.isInitialized) {
      await db.init();
      await ingestData();
      await warmup();
    }

    const question = 'Which invoices break the refund policy?';
    final result = await ask(question);

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
    // ignore: avoid_print
    print('CSV size: ${await csvFile.length()} bytes');
    // ignore: avoid_print
    print('PDF size: ${await pdfFile.length()} bytes');
  });
}
