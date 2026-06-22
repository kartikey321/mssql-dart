import 'tds/token_stream.dart';

/// A row returned by a query, accessible by column name or index.
class MssqlRow {
  final List<ColumnMeta> _columns;
  final List<Object?> _values;

  MssqlRow(this._columns, this._values);

  /// Access a column by name (case-insensitive) or by zero-based index.
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

/// The result of a single SELECT (or DML) statement.
class MssqlResult {
  /// Columns in the order returned by the server.
  final List<ColumnMeta> columns;

  /// All rows (buffered).
  final List<MssqlRow> rows;

  /// Number of rows affected (for INSERT / UPDATE / DELETE).
  final int rowsAffected;

  MssqlResult.fromInternal(QueryResult internal)
      : columns = internal.columns,
        rows = [
          for (int i = 0; i < internal.rows.length; i++)
            MssqlRow(internal.columns, internal.rows[i])
        ],
        rowsAffected = internal.rowsAffected;

  /// Named constructor kept for backward compatibility.
  MssqlResult({required QueryResult internal}) : this.fromInternal(internal);

  bool get isEmpty => rows.isEmpty;
  int get length => rows.length;

  MssqlRow operator [](int index) => rows[index];

  @override
  String toString() => 'MssqlResult(${rows.length} rows, $rowsAffected affected)';
}

/// Holds all result sets returned by a batch or stored procedure.
///
/// Most queries return a single result set. Stored procedures that execute
/// multiple SELECT statements return one [MssqlResult] per SELECT.
///
/// ```dart
/// final multi = await conn.queryMultiple('EXEC dbo.MyProc');
/// final first  = multi.first;   // first SELECT
/// final second = multi.second;  // second SELECT (if any)
/// ```
class MssqlMultiResult {
  final List<MssqlResult> _sets;

  MssqlMultiResult(List<QueryResult> internals)
      : _sets = [for (final i in internals) MssqlResult.fromInternal(i)];

  /// All result sets in order.
  List<MssqlResult> get all => List.unmodifiable(_sets);

  /// The first result set (throws if empty).
  MssqlResult get first => _sets.first;

  /// The second result set (throws if fewer than 2).
  MssqlResult get second => _sets[1];

  /// The result set at [index].
  MssqlResult operator [](int index) => _sets[index];

  int get length => _sets.length;

  @override
  String toString() => 'MssqlMultiResult(${_sets.length} result sets)';
}
