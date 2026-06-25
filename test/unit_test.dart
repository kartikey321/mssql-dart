import 'package:test/test.dart';
import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:mssql/src/tds/type_info.dart';

// Pure unit tests — no live SQL Server required.
// Exercises result.dart and exception.dart APIs directly.

void main() {
  // ── MssqlException ────────────────────────────────────────────────────────

  group('MssqlException', () {
    test('toString includes error code and message', () {
      final e = MssqlException('syntax error near FROM', errorCode: 102);
      final s = e.toString();
      expect(s, contains('102'));
      expect(s, contains('syntax error near FROM'));
    });

    test('default errorCode is 0', () {
      final e = MssqlException('connection refused');
      expect(e.errorCode, equals(0));
      expect(e.toString(), contains('0'));
      expect(e.toString(), contains('connection refused'));
    });

    test('is an Exception', () {
      expect(MssqlException('x'), isA<Exception>());
    });

    test('severity field', () {
      final e = MssqlException('serious error', errorCode: 911, severity: 16);
      expect(e.severity, equals(16));
    });
  });

  // ── MssqlRow ──────────────────────────────────────────────────────────────

  group('MssqlRow', () {
    late MssqlRow row;

    setUp(() {
      final cols = [
        ColumnMeta(
          name: 'id',
          typeInfo: TypeInfo(typeId: 0x26, size: 4),
          userType: 0,
          flags: 0,
        ),
        ColumnMeta(
          name: 'Name',
          typeInfo: TypeInfo(typeId: 0xE7, size: 100),
          userType: 0,
          flags: 0,
        ),
        ColumnMeta(
          name: 'score',
          typeInfo: TypeInfo(typeId: 0x6D, size: 8),
          userType: 0,
          flags: 0,
        ),
      ];
      row = MssqlRow(cols, [42, 'Alice', 9.5]);
    });

    test('access by column name (case-insensitive)', () {
      expect(row['id'], equals(42));
      expect(row['ID'], equals(42));
      expect(row['Name'], equals('Alice'));
      expect(row['name'], equals('Alice'));
      expect(row['NAME'], equals('Alice'));
    });

    test('access by index', () {
      expect(row[0], equals(42));
      expect(row[1], equals('Alice'));
      expect(row[2], equals(9.5));
    });

    test('valueAt', () {
      expect(row.valueAt(0), equals(42));
      expect(row.valueAt(1), equals('Alice'));
      expect(row.valueAt(2), equals(9.5));
    });

    test('columnNames returns ordered names', () {
      expect(row.columnNames, equals(['id', 'Name', 'score']));
    });

    test('values returns unmodifiable list', () {
      expect(row.values, equals([42, 'Alice', 9.5]));
      expect(() => (row.values as dynamic).add(1), throwsUnsupportedError);
    });

    test('length equals column count', () {
      expect(row.length, equals(3));
    });

    test('toString contains column/value pairs', () {
      final s = row.toString();
      expect(s, contains('id'));
      expect(s, contains('42'));
      expect(s, contains('Alice'));
    });

    test('unknown column name throws ArgumentError', () {
      expect(() => row['nonexistent'], throwsArgumentError);
    });

    test('nullable value is accessible', () {
      final cols = [
        ColumnMeta(name: 'v', typeInfo: TypeInfo(typeId: 0x26, size: 4), userType: 0, flags: 1),
      ];
      final r = MssqlRow(cols, [null]);
      expect(r['v'], isNull);
      expect(r.valueAt(0), isNull);
    });
  });

  // ── MssqlResult ───────────────────────────────────────────────────────────

  group('MssqlResult', () {
    late MssqlResult emptyResult;
    late MssqlResult dmlResult;
    late MssqlResult selectResult;

    setUp(() {
      final emptyCols = <ColumnMeta>[];
      final cols = [
        ColumnMeta(name: 'n', typeInfo: TypeInfo(typeId: 0x26, size: 4), userType: 0, flags: 0),
      ];

      emptyResult = MssqlResult(
        internal: QueryResult(columns: emptyCols, rows: [], rowsAffected: 0),
      );
      dmlResult = MssqlResult(
        internal: QueryResult(columns: emptyCols, rows: [], rowsAffected: 5),
      );
      selectResult = MssqlResult(
        internal: QueryResult(columns: cols, rows: [[1], [2], [3]], rowsAffected: 3),
      );
    });

    test('isEmpty', () {
      expect(emptyResult.isEmpty, isTrue);
      expect(selectResult.isEmpty, isFalse);
    });

    test('length', () {
      expect(emptyResult.length, equals(0));
      expect(selectResult.length, equals(3));
    });

    test('rowsAffected', () {
      expect(dmlResult.rowsAffected, equals(5));
      expect(selectResult.rowsAffected, equals(3));
    });

    test('columns', () {
      expect(emptyResult.columns, isEmpty);
      expect(selectResult.columns.length, equals(1));
      expect(selectResult.columns.first.name, equals('n'));
    });

    test('index operator', () {
      expect(selectResult[0]['n'], equals(1));
      expect(selectResult[1]['n'], equals(2));
      expect(selectResult[2]['n'], equals(3));
    });

    test('toString', () {
      final s = selectResult.toString();
      expect(s, contains('3'));
    });
  });

  // ── MssqlMultiResult ──────────────────────────────────────────────────────

  group('MssqlMultiResult', () {
    late MssqlMultiResult multi;

    setUp(() {
      final colA = [
        ColumnMeta(name: 'a', typeInfo: TypeInfo(typeId: 0x26, size: 4), userType: 0, flags: 0),
      ];
      final colB = [
        ColumnMeta(name: 'b', typeInfo: TypeInfo(typeId: 0xE7, size: 20), userType: 0, flags: 0),
      ];
      multi = MssqlMultiResult([
        QueryResult(columns: colA, rows: [[1]], rowsAffected: 1),
        QueryResult(columns: colB, rows: [['x']], rowsAffected: 1),
      ]);
    });

    test('length', () {
      expect(multi.length, equals(2));
    });

    test('first', () {
      expect(multi.first[0]['a'], equals(1));
    });

    test('second', () {
      expect(multi.second[0]['b'], equals('x'));
    });

    test('index operator', () {
      expect(multi[0][0]['a'], equals(1));
      expect(multi[1][0]['b'], equals('x'));
    });

    test('all returns immutable list of all sets', () {
      final all = multi.all;
      expect(all.length, equals(2));
      expect(() => (all as dynamic).clear(), throwsUnsupportedError);
    });

    test('toString', () {
      expect(multi.toString(), contains('2'));
    });
  });

  // ── ColumnMeta ────────────────────────────────────────────────────────────

  group('ColumnMeta', () {
    test('nullable flag from flags bit 0', () {
      final nullable = ColumnMeta(
          name: 'v', typeInfo: TypeInfo(typeId: 0x26, size: 4), userType: 0, flags: 1);
      final notNull = ColumnMeta(
          name: 'v', typeInfo: TypeInfo(typeId: 0x26, size: 4), userType: 0, flags: 0);
      expect(nullable.nullable, isTrue);
      expect(notNull.nullable, isFalse);
    });
  });
}
