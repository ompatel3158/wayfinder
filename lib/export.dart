import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'agent.dart';

String generateCsv(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return '';
  final headers = rows.first.keys.toList();
  final buffer = StringBuffer();

  // Header row
  buffer.writeln(headers.map(_escapeCsvValue).join(','));

  // Data rows
  for (final row in rows) {
    buffer.writeln(
      headers.map((h) => _escapeCsvValue(row[h]?.toString() ?? '')).join(','),
    );
  }
  return buffer.toString();
}

String _escapeCsvValue(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

Future<String> exportCsvToFile({
  required List<Map<String, dynamic>> rows,
  required String filePath,
}) async {
  final content = generateCsv(rows);
  final file = File(filePath);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
  return file.path;
}

Future<String?> saveCsv({
  required List<Map<String, dynamic>> rows,
  String fileName = 'wayfinder_results.csv',
}) async {
  if (rows.isEmpty) return null;
  final csvContent = generateCsv(rows);
  final bytes = Uint8List.fromList(utf8.encode(csvContent));

  final savedUri = await FilePicker.saveFile(
    dialogTitle: 'Export CSV',
    fileName: fileName,
    bytes: bytes,
    mimeType: 'text/csv',
  );

  if (savedUri == null) return null;

  try {
    return savedUri.toFilePath();
  } catch (_) {
    return savedUri.path;
  }
}

pw.Document buildPdfDocument({
  required String question,
  required AgentResult result,
}) {
  final pdf = pw.Document();
  final now = DateTime.now().toLocal();
  final timestampStr =
      "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";

  pw.Font? baseFont;
  pw.Font? monoFont;
  try {
    final interFile = File('assets/fonts/Inter.ttf');
    if (interFile.existsSync()) {
      baseFont = pw.Font.ttf(interFile.readAsBytesSync().buffer.asByteData());
    }
    final jbFile = File('assets/fonts/JetBrainsMono.ttf');
    if (jbFile.existsSync()) {
      monoFont = pw.Font.ttf(jbFile.readAsBytesSync().buffer.asByteData());
    }
  } catch (_) {}

  monoFont ??= pw.Font.courier();
  final pageTheme = baseFont != null
      ? pw.ThemeData.withFont(base: baseFont, bold: baseFont)
      : null;

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      theme: pageTheme,
      margin: const pw.EdgeInsets.all(32),
      footer: (pw.Context context) {
        return pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 16),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Generated offline by Wayfinder',
                style: const pw.TextStyle(color: PdfColors.grey700, fontSize: 9),
              ),
              pw.Text(
                'Page ${context.pageNumber} of ${context.pagesCount}',
                style: const pw.TextStyle(color: PdfColors.grey700, fontSize: 9),
              ),
            ],
          ),
        );
      },
      build: (pw.Context context) {
        return [
          // Title Header
          pw.Header(
            level: 0,
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Wayfinder report',
                  style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blueGrey900,
                  ),
                ),
                pw.Text(
                  timestampStr,
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey600,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 12),

          // Question & Route Box
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  children: [
                    pw.Text(
                      'Route: ',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    pw.Text(
                      result.route.toUpperCase(),
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.blue800,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Spacer(),
                    pw.Text(
                      '${result.milliseconds} ms',
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey600,
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'Question: $question',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),

          // Answer Box
          pw.Text(
            'Answer',
            style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(
              result.answer,
              style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 2),
            ),
          ),
          pw.SizedBox(height: 16),

          // SQL Box
          if (result.sql != null && result.sql!.isNotEmpty) ...[
            pw.Text(
              'SQL Query',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey200,
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Text(
                result.sql!,
                style: pw.TextStyle(font: monoFont, fontSize: 9.5),
              ),
            ),
            pw.SizedBox(height: 16),
          ],

          // Rows Table
          if (result.rows.isNotEmpty) ...[
            pw.Text(
              'Result Rows (${result.rows.length})',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              context: context,
              headers: result.rows.first.keys.toList(),
              data: result.rows
                  .map((r) => r.values.map((v) => v?.toString() ?? '').toList())
                  .toList(),
              headerStyle: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.blueGrey800),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignment: pw.Alignment.centerLeft,
              cellPadding:
                  const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              rowDecoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.grey200, width: 0.5),
                ),
              ),
            ),
            pw.SizedBox(height: 16),
          ],

          // Policy Chunks
          if (result.chunks.isNotEmpty) ...[
            pw.Text(
              'Policy Excerpts (${result.chunks.length})',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            ...result.chunks.map((chunk) {
              return pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 8),
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey50,
                  border: pw.Border.all(color: PdfColors.grey200),
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          chunk.source,
                          style: pw.TextStyle(
                            fontSize: 9,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.indigo900,
                          ),
                        ),
                        pw.Text(
                          'Score: ${(chunk.score * 100).toStringAsFixed(1)}%',
                          style: const pw.TextStyle(
                            fontSize: 8.5,
                            color: PdfColors.grey700,
                          ),
                        ),
                      ],
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      chunk.text,
                      style: const pw.TextStyle(
                        fontSize: 8.5,
                        color: PdfColors.black,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ];
      },
    ),
  );

  return pdf;
}

Future<String> exportPdfToFile({
  required String question,
  required AgentResult result,
  required String filePath,
}) async {
  final pdf = buildPdfDocument(question: question, result: result);
  final bytes = await pdf.save();
  final file = File(filePath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
  return file.path;
}

Future<String?> savePdfReport({
  required String question,
  required AgentResult result,
  String fileName = 'wayfinder_report.pdf',
}) async {
  final pdf = buildPdfDocument(question: question, result: result);
  final bytes = await pdf.save();

  final savedUri = await FilePicker.saveFile(
    dialogTitle: 'Export PDF Report',
    fileName: fileName,
    bytes: bytes,
    mimeType: 'application/pdf',
  );

  if (savedUri == null) return null;

  try {
    return savedUri.toFilePath();
  } catch (_) {
    return savedUri.path;
  }
}
