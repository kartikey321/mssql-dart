import 'buf.dart';
import 'bulk.dart';
import 'constants.dart';

/// Table-valued parameter for RPC / `sp_executesql` (TDS type 0xF3).
///
/// Requires a user-defined table type on the server, e.g.
/// `CREATE TYPE dbo.IdList AS TABLE (Id BIGINT);`.
///
/// ```dart
/// await conn.query(
///   'SELECT Id FROM @ids',
///   {
///     'ids': MssqlTvp(
///       typeName: 'dbo.IdList',
///       columns: [BulkColumn('Id', BulkColumnType.bigInt)],
///       rows: [[1], [2], [3]],
///     ),
///   },
/// );
/// ```
///
/// Wire layout: go-mssqldb `TVP.encode` / ms-tds §2.2.5.5.5.
class MssqlTvp {
  /// `schema.name` or `name` (brackets optional).
  final String typeName;
  final List<BulkColumn> columns;
  final List<List<Object?>> rows;

  const MssqlTvp({
    required this.typeName,
    required this.columns,
    this.rows = const [],
  });

  /// Infers column types from [rows] (same rules as [BulkLoad.inferColumns]).
  factory MssqlTvp.infer({
    required String typeName,
    required List<String> columnNames,
    required List<List<Object?>> rows,
  }) {
    return MssqlTvp(
      typeName: typeName,
      columns: BulkLoad.inferColumns(columnNames, rows),
      rows: rows,
    );
  }

  /// Declaration fragment for `@params` (`dbo.IdList READONLY`).
  String get readonlyDecl {
    final (schema, name) = splitTypeName(typeName);
    if (schema.isEmpty) return '$name READONLY';
    return '$schema.$name READONLY';
  }

  /// Splits `dbo.MyType` / `[dbo].[MyType]` → `(schema, name)`.
  static (String schema, String name) splitTypeName(String typeName) {
    var s = typeName.trim();
    if (s.isEmpty) {
      throw ArgumentError('TVP typeName must not be empty');
    }
    s = s.replaceAll('[', '').replaceAll(']', '');
    final dot = s.indexOf('.');
    if (dot < 0) return ('', s);
    if (s.indexOf('.', dot + 1) >= 0) {
      throw ArgumentError('TVP typeName must be schema.name or name: "$typeName"');
    }
    return (s.substring(0, dot), s.substring(dot + 1));
  }

  /// Writes TVP_TYPE_INFO body after [typeTvp] byte (name already written by RPC).
  void writeTypeAndValue(TdsBuffer buf) {
    if (columns.isEmpty) {
      throw ArgumentError('TVP columns must not be empty');
    }
    for (final row in rows) {
      if (row.length != columns.length) {
        throw ArgumentError(
          'TVP row has ${row.length} values, expected ${columns.length}',
        );
      }
    }

    buf.writeByte(typeTvp);

    final (schema, name) = splitTypeName(typeName);
    // DbName MUST be zero-length (ms-tds); schema + type name follow.
    _writeBVarChar(buf, '');
    _writeBVarChar(buf, schema);
    _writeBVarChar(buf, name);

    // TVP_COLMETADATA — count + columns (no 0x81 token).
    buf.writeUint16LE(columns.length);
    for (final col in columns) {
      buf.writeUint32LE(0); // userType
      buf.writeUint16LE(0x01); // fNullable
      BulkLoad.writeTypeInfo(buf, col);
      _writeBVarChar(buf, ''); // ColName often empty for TVP
    }
    buf.writeByte(tvpEndToken);

    for (final row in rows) {
      buf.writeByte(tvpRowToken);
      for (var i = 0; i < columns.length; i++) {
        BulkLoad.writeCell(buf, columns[i], row[i]);
      }
    }
    buf.writeByte(tvpEndToken);
  }

  static void _writeBVarChar(TdsBuffer buf, String s) {
    final out = List<int>.filled(s.length * 2, 0);
    for (var i = 0; i < s.length; i++) {
      out[i * 2] = s.codeUnitAt(i) & 0xFF;
      out[i * 2 + 1] = (s.codeUnitAt(i) >> 8) & 0xFF;
    }
    buf.writeByte(s.length);
    buf.writeBytes(out);
  }
}
