import 'dart:math';
import 'package:ultsql/ultsql.dart';

class Chunk {
  final String text;
  final String source;
  final double score;

  Chunk({
    required this.text,
    required this.source,
    required this.score,
  });

  Map<String, dynamic> toMap() => {
        'text': text,
        'source': source,
        'score': score,
      };

  @override
  String toString() =>
      'Chunk(source: $source, score: ${score.toStringAsFixed(4)}, text: $text)';
}

class _ChunkEmbedding {
  final int id;
  final String text;
  final String source;
  final List<double> embedding;

  _ChunkEmbedding({
    required this.id,
    required this.text,
    required this.source,
    required this.embedding,
  });
}

class AppDatabase {
  static final AppDatabase instance = AppDatabase._internal();
  AppDatabase._internal();

  Database? _db;
  Interpreter? _interpreter;
  bool _initialized = false;

  // In-memory list for 768-dimension chunk embeddings (fallback for vectors exceeding 4KB slotted page)
  final List<_ChunkEmbedding> _chunkEmbeddings = [];

  bool get isInitialized => _initialized;

  Future<void> init({String path = ':memory:'}) async {
    if (_initialized) return;

    final db = Database(path, useWal: false);
    await db.init();
    final interp = Interpreter(db);

    _db = db;
    _interpreter = interp;

    // Create invoices table
    await interp.executeScript('''
      CREATE TABLE invoices (
        id TEXT PRIMARY KEY,
        vendor TEXT,
        category TEXT,
        amount DOUBLE,
        invoice_date TEXT,
        refund_amount DOUBLE,
        refund_days INT,
        approved INT
      );
    ''');

    // Create policy_chunks metadata table in ULTSQL
    await interp.executeScript('''
      CREATE TABLE policy_chunks (
        id INT PRIMARY KEY,
        content TEXT,
        source TEXT
      );
    ''');

    _chunkEmbeddings.clear();
    _initialized = true;
  }

  Future<QueryResult> executeScript(String sql) async {
    if (!_initialized || _interpreter == null) {
      throw StateError('Database not initialized');
    }
    return await _interpreter!.executeScript(sql);
  }

  Future<List<Map<String, dynamic>>> query(String sql) async {
    final result = await executeScript(sql);
    final list = <Map<String, dynamic>>[];
    for (final row in result.rows) {
      final map = <String, dynamic>{};
      for (int i = 0; i < result.columns.length && i < row.length; i++) {
        map[result.columns[i]] = row[i].value;
      }
      list.add(map);
    }
    return list;
  }

  Future<void> insertInvoice({
    required String id,
    required String vendor,
    required String category,
    required double amount,
    required String invoiceDate,
    required double refundAmount,
    required int refundDays,
    required int approved,
  }) async {
    final cleanId = id.replaceAll("'", "''");
    final cleanVendor = vendor.replaceAll("'", "''");
    final cleanCat = category.replaceAll("'", "''");
    final cleanDate = invoiceDate.replaceAll("'", "''");

    final sql = '''
      INSERT INTO invoices VALUES (
        '$cleanId', '$cleanVendor', '$cleanCat', $amount, '$cleanDate', $refundAmount, $refundDays, $approved
      );
    ''';
    await executeScript(sql);
  }

  Future<void> insertChunk({
    required int id,
    required String content,
    required String source,
    required List<double> embedding,
  }) async {
    // 1. Store metadata in ULTSQL policy_chunks table
    final cleanContent = content.replaceAll("'", "''");
    final cleanSource = source.replaceAll("'", "''");
    final sql = '''
      INSERT INTO policy_chunks VALUES ($id, '$cleanContent', '$cleanSource');
    ''';
    await executeScript(sql);

    // 2. Keep 768-dim embeddings in memory for cosine similarity search
    _chunkEmbeddings.add(_ChunkEmbedding(
      id: id,
      text: content,
      source: source,
      embedding: embedding,
    ));
  }

  Future<List<Chunk>> searchPolicyChunks(List<double> queryVec, {int k = 3}) async {
    if (_chunkEmbeddings.isEmpty) return [];

    final scored = <MapEntry<_ChunkEmbedding, double>>[];
    for (final item in _chunkEmbeddings) {
      final sim = _cosineSimilarity(queryVec, item.embedding);
      scored.add(MapEntry(item, sim));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));

    return scored.take(k).map((e) {
      return Chunk(
        text: e.key.text,
        source: e.key.source,
        score: e.value,
      );
    }).toList();
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  Future<int> countInvoices() async {
    final res = await query('SELECT COUNT(*) AS total FROM invoices;');
    if (res.isNotEmpty && res.first.containsKey('total')) {
      final total = res.first['total'];
      if (total is num) return total.toInt();
    }
    return 0;
  }

  Future<int> countChunks() async {
    final res = await query('SELECT COUNT(*) AS total FROM policy_chunks;');
    if (res.isNotEmpty && res.first.containsKey('total')) {
      final total = res.first['total'];
      if (total is num) return total.toInt();
    }
    return 0;
  }

  Future<void> dropTable(String tableName) async {
    await executeScript('DROP TABLE IF EXISTS $tableName;');
  }

  Future<void> deleteChunksBySource(String source) async {
    await executeScript(
        "DELETE FROM policy_chunks WHERE source = '${source.replaceAll("'", "''")}';");
    _chunkEmbeddings.removeWhere((item) => item.source == source);
  }

  Future<void> insertCustomRows(
    String tableName,
    List<String> columns,
    List<List<dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    final colsStr = columns.join(', ');
    final buffer = StringBuffer();
    for (final row in rows) {
      final valuesStr = row.map((val) {
        if (val == null) return 'NULL';
        if (val is num) return val.toString();
        if (val is bool) return val ? '1' : '0';
        final str = val.toString().replaceAll("'", "''");
        return "'$str'";
      }).join(', ');
      buffer.writeln('INSERT INTO $tableName ($colsStr) VALUES ($valuesStr);');
    }
    await executeScript(buffer.toString());
  }

  Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
      _interpreter = null;
      _initialized = false;
    }
    _chunkEmbeddings.clear();
  }
}
