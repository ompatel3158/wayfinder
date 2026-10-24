import 'dart:convert';
import 'dart:io';
import 'db.dart';
import 'llm.dart';
import 'registry.dart';

String sanitizeIdentifier(String raw) {
  var s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
  s = s.replaceAll(RegExp(r'_+'), '_').trim();
  if (s.startsWith('_')) s = s.substring(1);
  if (s.endsWith('_')) s = s.substring(0, s.length - 1);
  if (RegExp(r'^[0-9]').hasMatch(s)) s = 't_$s';
  if (s.isEmpty) s = 'col';
  return s;
}

Future<void> ingestData({String dataDir = 'assets/data'}) async {
  final db = AppDatabase.instance;
  if (!db.isInitialized) {
    await db.init();
  }

  // 1. Ingest Invoices CSV
  final csvFile = File('$dataDir/invoices.csv');
  final sampleInvoices = <Map<String, dynamic>>[];
  int invoiceCount = 0;

  if (await csvFile.exists()) {
    final lines = await csvFile.readAsLines();
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length >= 8) {
        final id = parts[0].trim();
        final vendor = parts[1].trim();
        final category = parts[2].trim();
        final amount = double.tryParse(parts[3].trim()) ?? 0.0;
        final invoiceDate = parts[4].trim();
        final refundAmount = double.tryParse(parts[5].trim()) ?? 0.0;
        final refundDays = int.tryParse(parts[6].trim()) ?? 0;
        final approved = int.tryParse(parts[7].trim()) ?? 0;

        await db.insertInvoice(
          id: id,
          vendor: vendor,
          category: category,
          amount: amount,
          invoiceDate: invoiceDate,
          refundAmount: refundAmount,
          refundDays: refundDays,
          approved: approved,
        );
        invoiceCount++;
        if (sampleInvoices.length < 3) {
          sampleInvoices.add({
            'id': id,
            'vendor': vendor,
            'category': category,
            'amount': amount,
            'invoice_date': invoiceDate,
            'refund_amount': refundAmount,
            'refund_days': refundDays,
            'approved': approved,
          });
        }
      }
    }
  }

  // Register invoices table in DataRegistry
  DataRegistry.instance.registerTable(TableMetadata(
    tableName: 'invoices',
    sourceFileName: 'invoices.csv',
    columns: [
      TableColumnInfo(name: 'id', type: 'TEXT'),
      TableColumnInfo(name: 'vendor', type: 'TEXT'),
      TableColumnInfo(name: 'category', type: 'TEXT'),
      TableColumnInfo(name: 'amount', type: 'REAL'),
      TableColumnInfo(name: 'invoice_date', type: 'TEXT'),
      TableColumnInfo(name: 'refund_amount', type: 'REAL'),
      TableColumnInfo(name: 'refund_days', type: 'INTEGER'),
      TableColumnInfo(name: 'approved', type: 'INTEGER'),
    ],
    rowCount: invoiceCount,
    sampleRows: sampleInvoices,
  ));

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

    DataRegistry.instance.registerDocument(DocumentMetadata(
      sourceFileName: filename,
      chunkCount: chunks.length,
    ));
  }
}

List<String> _splitIntoChunks(String text) {
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

Future<String> ingestCustomFile(
  File file, {
  void Function(double progress, String status)? onProgress,
}) async {
  final db = AppDatabase.instance;
  if (!db.isInitialized) {
    await db.init();
  }

  final fileName = file.uri.pathSegments.last;
  final ext =
      fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';

  if (ext != 'csv' && ext != 'json' && ext != 'txt' && ext != 'md') {
    throw UnsupportedError(
      'Unsupported file type: .$ext. Supported: CSV, JSON, TXT, MD.',
    );
  }

  onProgress?.call(0.1, 'Reading $fileName...');

  if (ext == 'csv') {
    return await _ingestCsv(file, fileName, onProgress);
  } else if (ext == 'json') {
    return await _ingestJson(file, fileName, onProgress);
  } else {
    return await _ingestText(file, fileName, onProgress);
  }
}

Future<String> _ingestCsv(
  File file,
  String fileName,
  void Function(double progress, String status)? onProgress,
) async {
  final db = AppDatabase.instance;
  final lines = await file.readAsLines();
  if (lines.isEmpty) throw StateError('CSV file is empty');

  // Parse header
  final rawHeaders = lines.first.split(',').map((h) => h.trim()).toList();
  if (rawHeaders.isEmpty) throw StateError('CSV has no columns');

  final maxCols = rawHeaders.length > 50 ? 50 : rawHeaders.length;
  final headers = <String>[];
  final seenHeaders = <String>{};

  for (int i = 0; i < maxCols; i++) {
    var sanitized = sanitizeIdentifier(rawHeaders[i]);
    if (sanitized.isEmpty) sanitized = 'col_$i';
    var uniqueName = sanitized;
    int suffix = 1;
    while (seenHeaders.contains(uniqueName)) {
      uniqueName = '${sanitized}_$suffix';
      suffix++;
    }
    seenHeaders.add(uniqueName);
    headers.add(uniqueName);
  }

  // Parse rows (cap at 5000)
  final rawDataLines =
      lines.skip(1).where((l) => l.trim().isNotEmpty).take(5000).toList();
  final parsedRows = <List<dynamic>>[];

  for (final line in rawDataLines) {
    final parts = line.split(',');
    final row = <dynamic>[];
    for (int i = 0; i < maxCols; i++) {
      if (i < parts.length) {
        final val = parts[i].trim();
        row.add(val);
      } else {
        row.add('');
      }
    }
    parsedRows.add(row);
  }

  // Infer types
  final colTypes = <String>[];
  for (int c = 0; c < maxCols; c++) {
    bool allInt = true;
    bool allReal = true;
    int nonEmptyCount = 0;

    for (final r in parsedRows) {
      final v = r[c]?.toString().trim() ?? '';
      if (v.isEmpty) continue;
      nonEmptyCount++;
      if (int.tryParse(v) == null) allInt = false;
      if (double.tryParse(v) == null) allReal = false;
    }

    if (nonEmptyCount > 0 && allInt) {
      colTypes.add('INTEGER');
    } else if (nonEmptyCount > 0 && allReal) {
      colTypes.add('REAL');
    } else {
      colTypes.add('TEXT');
    }
  }

  // Sanitize Table Name
  final baseName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  var tableName = sanitizeIdentifier(baseName);
  if (tableName.isEmpty) tableName = 't_table';

  onProgress?.call(0.4, 'Creating table $tableName...');
  await db.dropTable(tableName);

  final colDefs = <String>[];
  for (int i = 0; i < headers.length; i++) {
    colDefs.add('${headers[i]} ${colTypes[i]}');
  }

  await db.executeScript('CREATE TABLE $tableName (${colDefs.join(', ')});');

  onProgress?.call(
      0.6, 'Inserting ${parsedRows.length} rows into $tableName...');

  // Convert row values based on types
  final typedRows = <List<dynamic>>[];
  for (final row in parsedRows) {
    final typedRow = <dynamic>[];
    for (int i = 0; i < headers.length; i++) {
      final raw = row[i]?.toString().trim() ?? '';
      if (raw.isEmpty) {
        typedRow.add(null);
      } else if (colTypes[i] == 'INTEGER') {
        typedRow.add(int.tryParse(raw) ?? 0);
      } else if (colTypes[i] == 'REAL') {
        typedRow.add(double.tryParse(raw) ?? 0.0);
      } else {
        typedRow.add(raw);
      }
    }
    typedRows.add(typedRow);
  }

  await db.insertCustomRows(tableName, headers, typedRows);

  // Sample rows for registry
  final sampleRows = <Map<String, dynamic>>[];
  for (int i = 0; i < typedRows.length && i < 3; i++) {
    final map = <String, dynamic>{};
    for (int j = 0; j < headers.length; j++) {
      map[headers[j]] = typedRows[i][j];
    }
    sampleRows.add(map);
  }

  DataRegistry.instance.registerTable(TableMetadata(
    tableName: tableName,
    sourceFileName: fileName,
    columns: [
      for (int i = 0; i < headers.length; i++)
        TableColumnInfo(name: headers[i], type: colTypes[i]),
    ],
    rowCount: typedRows.length,
    sampleRows: sampleRows,
  ));

  onProgress?.call(
      1.0, 'Imported table $tableName (${typedRows.length} rows).');
  return 'Table "$tableName" created with ${typedRows.length} rows.';
}

Future<String> _ingestJson(
  File file,
  String fileName,
  void Function(double progress, String status)? onProgress,
) async {
  final content = await file.readAsString();
  final decoded = jsonDecode(content);
  if (decoded is! List) {
    throw const FormatException('JSON file must contain an array of objects.');
  }

  final rawObjects = decoded.whereType<Map>().take(5000).toList();
  if (rawObjects.isEmpty) throw StateError('No JSON objects found in array.');

  // Collect all unique keys
  final seenKeys = <String>{};
  for (final obj in rawObjects) {
    for (final k in obj.keys) {
      seenKeys.add(k.toString());
    }
  }

  final rawHeaders = seenKeys.take(50).toList();
  final headers = <String>[];

  for (final rk in rawHeaders) {
    var sanitized = sanitizeIdentifier(rk);
    if (sanitized.isEmpty) sanitized = 'col';
    var unique = sanitized;
    int suffix = 1;
    while (headers.contains(unique)) {
      unique = '${sanitized}_$suffix';
      suffix++;
    }
    headers.add(unique);
  }

  // Infer types
  final colTypes = <String>[];
  for (final rk in rawHeaders) {
    bool allInt = true;
    bool allReal = true;
    int count = 0;
    for (final obj in rawObjects) {
      final val = obj[rk];
      if (val == null) continue;
      count++;
      if (val is! int) allInt = false;
      if (val is! num) allReal = false;
    }

    if (count > 0 && allInt) {
      colTypes.add('INTEGER');
    } else if (count > 0 && allReal) {
      colTypes.add('REAL');
    } else {
      colTypes.add('TEXT');
    }
  }

  final baseName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  var tableName = sanitizeIdentifier(baseName);
  if (tableName.isEmpty) tableName = 't_json';

  final db = AppDatabase.instance;
  await db.dropTable(tableName);

  final colDefs = <String>[];
  for (int i = 0; i < headers.length; i++) {
    colDefs.add('${headers[i]} ${colTypes[i]}');
  }
  await db.executeScript('CREATE TABLE $tableName (${colDefs.join(', ')});');

  final typedRows = <List<dynamic>>[];
  for (final obj in rawObjects) {
    final row = <dynamic>[];
    for (int i = 0; i < rawHeaders.length; i++) {
      final val = obj[rawHeaders[i]];
      if (val == null) {
        row.add(null);
      } else if (colTypes[i] == 'INTEGER') {
        row.add(val is num ? val.toInt() : (int.tryParse(val.toString()) ?? 0));
      } else if (colTypes[i] == 'REAL') {
        row.add(val is num
            ? val.toDouble()
            : (double.tryParse(val.toString()) ?? 0.0));
      } else {
        row.add(val.toString());
      }
    }
    typedRows.add(row);
  }

  await db.insertCustomRows(tableName, headers, typedRows);

  final sampleRows = <Map<String, dynamic>>[];
  for (int i = 0; i < typedRows.length && i < 3; i++) {
    final map = <String, dynamic>{};
    for (int j = 0; j < headers.length; j++) {
      map[headers[j]] = typedRows[i][j];
    }
    sampleRows.add(map);
  }

  DataRegistry.instance.registerTable(TableMetadata(
    tableName: tableName,
    sourceFileName: fileName,
    columns: [
      for (int i = 0; i < headers.length; i++)
        TableColumnInfo(name: headers[i], type: colTypes[i]),
    ],
    rowCount: typedRows.length,
    sampleRows: sampleRows,
  ));

  onProgress?.call(
      1.0, 'Imported table $tableName (${typedRows.length} rows).');
  return 'Table "$tableName" created with ${typedRows.length} rows.';
}

Future<String> _ingestText(
  File file,
  String fileName,
  void Function(double progress, String status)? onProgress,
) async {
  final content = await file.readAsString();
  final chunks = _splitIntoChunks(content);
  if (chunks.isEmpty) throw StateError('Document has no readable text chunks.');

  final db = AppDatabase.instance;
  await db.deleteChunksBySource(fileName);

  final chunkBaseId = DateTime.now().millisecondsSinceEpoch % 1000000;

  for (int i = 0; i < chunks.length; i++) {
    final chunk = chunks[i];
    final progressVal = 0.2 + ((i + 1) / chunks.length) * 0.75;
    onProgress?.call(
      progressVal,
      'Embedding chunk ${i + 1} of ${chunks.length}...',
    );
    final embedding = await embed(chunk);
    await db.insertChunk(
      id: chunkBaseId + i,
      content: chunk,
      source: fileName,
      embedding: embedding,
    );
  }

  DataRegistry.instance.registerDocument(DocumentMetadata(
    sourceFileName: fileName,
    chunkCount: chunks.length,
  ));

  onProgress?.call(1.0, 'Embedded ${chunks.length} chunks from $fileName.');
  return 'Document "$fileName" embedded with ${chunks.length} chunks.';
}
