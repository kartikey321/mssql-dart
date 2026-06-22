import 'tds/token_stream.dart';

/// A row returned by a query, accessible by column name or index.
class MssqlRow {
  final List<ColumnMeta> _columns;
  final List<Object?> _values;

  MssqlRow(this._columns, this._values);

  /// Access a column by name (case-insensitive).
  Object? operator [](Object key) {
    if (key is int) return _values[key];
    final name = key as String;
    final idx = _columns.indexWhere(
      (c) => c.name.toLowerCase() == name.toLowerCase(),
    );
    if (idx < 0) throw ArgumentError('Column "$name" not found');
    return _values[idx];
  }

  /// Returns the value at [index].
  Object? valueAt(int index) => _values[index];

  /// Returns all column names.
  List<String> get columnNames => _columns.map((c) => c.name).toList();

  /// Returns all values in column order.
  List<Object?> get values => List.unmodifiable(_values);

  int get length => _values.length;

  @override
  String toString() {
    final pairs = [
      for (int i = 0; i < _columns.length; i++) '${_columns[i].name}: ${_values[i]}'
    ];
    return '{${pairs.join(', ')}}';
  }
}

/// The result of a query execution.
class MssqlResult {
  /// Columns in the order returned by the server.
  final List<ColumnMeta> columns;

  /// All rows.
  final List<MssqlRow> rows;

  /// Number of rows affected (for INSERT / UPDATE / DELETE).
  final int rowsAffected;

  MssqlResult({
    required QueryResult internal,
  })  : columns = internal.columns,
        rows = [
          for (int i = 0; i < internal.rows.length; i++)
            MssqlRow(internal.columns, internal.rows[i])
        ],
        rowsAffected = internal.rowsAffected;

  bool get isEmpty => rows.isEmpty;
  int get length => rows.length;

  /// Convenience: iterate rows directly.
  MssqlRow operator [](int index) => rows[index];

  @override
  String toString() => 'MssqlResult(${rows.length} rows, $rowsAffected affected)';
}
