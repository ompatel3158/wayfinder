import 'dart:convert';

class TableColumnInfo {
  final String name;
  final String type; // 'INTEGER', 'REAL', 'TEXT'

  TableColumnInfo({
    required this.name,
    required this.type,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'type': type,
      };
}

class TableMetadata {
  final String tableName;
  final String sourceFileName;
  final List<TableColumnInfo> columns;
  final int rowCount;
  final List<Map<String, dynamic>> sampleRows;

  TableMetadata({
    required this.tableName,
    required this.sourceFileName,
    required this.columns,
    required this.rowCount,
    this.sampleRows = const [],
  });
}

class DocumentMetadata {
  final String sourceFileName;
  final int chunkCount;

  DocumentMetadata({
    required this.sourceFileName,
    required this.chunkCount,
  });
}

class DataRegistry {
  static final DataRegistry instance = DataRegistry._internal();
  DataRegistry._internal();

  final Map<String, TableMetadata> tables = {};
  final Map<String, DocumentMetadata> documents = {};

  void registerTable(TableMetadata meta) {
    tables[meta.tableName.toLowerCase()] = meta;
  }

  void unregisterTable(String tableName) {
    tables.remove(tableName.toLowerCase());
  }

  void registerDocument(DocumentMetadata meta) {
    documents[meta.sourceFileName] = meta;
  }

  void unregisterDocument(String sourceFileName) {
    documents.remove(sourceFileName);
  }

  bool hasTable(String tableName) =>
      tables.containsKey(tableName.toLowerCase());

  TableMetadata? getTable(String tableName) =>
      tables[tableName.toLowerCase()];

  int get totalSourcesCount => tables.length + documents.length;

  String buildSchemaPrompt() {
    if (tables.isEmpty) {
      return 'No SQL tables loaded.';
    }
    final buffer = StringBuffer();
    for (final table in tables.values) {
      buffer.writeln(
        'Table "${table.tableName}" (from ${table.sourceFileName}, ${table.rowCount} rows):',
      );
      final cols = table.columns.map((c) => '${c.name} ${c.type}').join(', ');
      buffer.writeln('  Columns: $cols');
      if (table.sampleRows.isNotEmpty) {
        buffer.writeln('  Sample rows: ${jsonEncode(table.sampleRows)}');
      }
    }
    return buffer.toString().trim();
  }

  String buildDocumentsPrompt() {
    if (documents.isEmpty) {
      return 'No policy or knowledge documents loaded.';
    }
    final buffer = StringBuffer();
    for (final doc in documents.values) {
      buffer.writeln('- "${doc.sourceFileName}" (${doc.chunkCount} chunks)');
    }
    return buffer.toString().trim();
  }
}
