import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Behavioural / scenario tests: transactions, errors, execute(), edge cases.
// Runs against the dart-mssql Docker container on port 14330.

late MssqlConnection conn;

void main() {
  setUpAll(() async {
    conn = await MssqlConnection.connect(
      host: '127.0.0.1',
      port: 14330,
      user: 'sa',
      password: 'Knex_Test1!',
      database: 'master',
      trustServerCertificate: true,
    );
  });

  tearDownAll(() async => conn.close());

  // ── Connection state ─────────────────────────────────────────────────────────

  group('connection', () {
    test('isOpen is true after connect', () {
      expect(conn.isOpen, isTrue);
    });

    test('database property is set', () {
      expect(conn.database.toLowerCase(), equals('master'));
    });

    test('second connection can be opened independently', () async {
      final conn2 = await MssqlConnection.connect(
        host: '127.0.0.1',
        port: 14330,
        user: 'sa',
        password: 'Knex_Test1!',
        database: 'master',
        trustServerCertificate: true,
      );
      expect(conn2.isOpen, isTrue);
      final r = await conn2.query('SELECT 1 AS v');
      expect(r[0]['v'], equals(1));
      await conn2.close();
      expect(conn2.isOpen, isFalse);
    });
  });

  // ── Error handling ────────────────────────────────────────────────────────────

  group('errors', () {
    test('SQL syntax error throws MssqlException', () async {
      await expectLater(
        () => conn.query('SELECT FROM'),
        throwsA(isA<MssqlException>()),
      );
    });

    test('divide by zero throws MssqlException with error code 8134', () async {
      try {
        await conn.query('SELECT 1/0 AS v');
        fail('expected MssqlException');
      } on MssqlException catch (e) {
        expect(e.errorCode, equals(8134));
        expect(e.message, contains('zero'));
      }
    });

    test('invalid object name throws MssqlException', () async {
      try {
        await conn.query('SELECT * FROM nonexistent_table_xyz');
        fail('expected MssqlException');
      } on MssqlException catch (e) {
        expect(e.errorCode, equals(208)); // "Invalid object name"
      }
    });

    test('connection is still usable after a query error', () async {
      try {
        await conn.query('SELECT 1/0');
      } catch (_) {}
      final r = await conn.query('SELECT 42 AS v');
      expect(r[0]['v'], equals(42));
    });
  });

  // ── execute() ────────────────────────────────────────────────────────────────

  group('execute', () {
    test('INSERT rowsAffected', () async {
      await conn.execute('CREATE TABLE #exec_test (id INT)');
      final n = await conn.execute('INSERT INTO #exec_test VALUES (1),(2),(3)');
      expect(n, equals(3));
    });

    test('UPDATE rowsAffected', () async {
      await conn.execute('CREATE TABLE #upd_test (v INT)');
      await conn.execute('INSERT INTO #upd_test VALUES (0),(0),(0)');
      final n = await conn.execute('UPDATE #upd_test SET v = 1');
      expect(n, equals(3));
    });

    test('DELETE rowsAffected', () async {
      await conn.execute('CREATE TABLE #del_test (v INT)');
      await conn.execute('INSERT INTO #del_test VALUES (1),(2)');
      final n = await conn.execute('DELETE FROM #del_test');
      expect(n, equals(2));
    });

    test('SELECT rowsAffected reflects row count', () async {
      // SQL Server reports SELECT row count in DONE; this is expected behaviour.
      final result = await conn.query('SELECT 1 AS v');
      expect(result.rowsAffected, equals(1));
    });
  });

  // ── Transactions ─────────────────────────────────────────────────────────────

  group('transactions', () {
    test('commit persists data', () async {
      await conn.execute('CREATE TABLE #tx_commit (v INT)');
      await conn.transaction((c) async {
        await c.execute('INSERT INTO #tx_commit VALUES (42)');
      });
      final r = await conn.query('SELECT v FROM #tx_commit');
      expect(r.length, equals(1));
      expect(r[0]['v'], equals(42));
    });

    test('rollback on exception reverts data', () async {
      await conn.execute('CREATE TABLE #tx_rollback (v INT)');
      await expectLater(
        () => conn.transaction((c) async {
          await c.execute('INSERT INTO #tx_rollback VALUES (99)');
          throw Exception('force rollback');
        }),
        throwsException,
      );
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_rollback');
      expect(r[0]['n'], equals(0));
    });

    test('manual begin/commit', () async {
      await conn.execute('CREATE TABLE #tx_manual (v INT)');
      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_manual VALUES (7)');
      await conn.commitTransaction();
      final r = await conn.query('SELECT v FROM #tx_manual');
      expect(r[0]['v'], equals(7));
    });

    test('manual begin/rollback', () async {
      await conn.execute('CREATE TABLE #tx_manual2 (v INT)');
      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_manual2 VALUES (7)');
      await conn.rollbackTransaction();
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_manual2');
      expect(r[0]['n'], equals(0));
    });
  });

  // ── Large data and edge cases ─────────────────────────────────────────────────

  group('large data', () {
    test('100-row result set', () async {
      final r = await conn.query(
          'SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n '
          'FROM sys.all_columns');
      expect(r.length, equals(100));
      expect(r[0]['n'], equals(1));
      expect(r[99]['n'], equals(100));
    });

    test('many columns (20) in one row', () async {
      final r = await conn.query(
          'SELECT 1 AS c1, 2 AS c2, 3 AS c3, 4 AS c4, 5 AS c5, '
          '6 AS c6, 7 AS c7, 8 AS c8, 9 AS c9, 10 AS c10, '
          '11 AS c11, 12 AS c12, 13 AS c13, 14 AS c14, 15 AS c15, '
          '16 AS c16, 17 AS c17, 18 AS c18, 19 AS c19, 20 AS c20');
      expect(r[0].length, equals(20));
      expect(r[0]['c1'], equals(1));
      expect(r[0]['c20'], equals(20));
    });

    test('query spanning multiple TDS packets', () async {
      // Generate a 10000-char string to force multi-packet TDS response
      final r = await conn.query(
          "SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 10000) AS v");
      expect((r[0]['v'] as String).length, equals(10000));
    });

    test('zero rows returns empty result', () async {
      final r = await conn.query('SELECT 1 AS v WHERE 1 = 0');
      expect(r.isEmpty, isTrue);
      expect(r.length, equals(0));
    });
  });

  // ── CREATE / INSERT / SELECT round-trip ──────────────────────────────────────

  group('round-trip', () {
    test('temp table create, insert, select, drop', () async {
      await conn.execute(
          'CREATE TABLE #rt (id INT PRIMARY KEY, name NVARCHAR(100))');
      await conn.execute(
          "INSERT INTO #rt VALUES (1, N'Alice'), (2, N'Bob')");
      final r = await conn.query('SELECT id, name FROM #rt ORDER BY id');
      expect(r.length, equals(2));
      expect(r[0]['id'], equals(1));
      expect(r[0]['name'], equals('Alice'));
      expect(r[1]['name'], equals('Bob'));
    });

    test('parameterised INSERT then SELECT', () async {
      await conn.execute('CREATE TABLE #pi (v NVARCHAR(200))');
      await conn.execute('INSERT INTO #pi VALUES (@v)', {'v': 'hello param'});
      final r = await conn.query('SELECT v FROM #pi');
      expect(r[0]['v'], equals('hello param'));
    });

    test('large string param persists correctly', () async {
      final big = 'Z' * 5000;
      await conn.execute('CREATE TABLE #ls (v NVARCHAR(MAX))');
      await conn.execute('INSERT INTO #ls VALUES (@v)', {'v': big});
      final r = await conn.query('SELECT LEN(v) AS n FROM #ls');
      expect(r[0]['n'], equals(5000));
    });
  });
}
