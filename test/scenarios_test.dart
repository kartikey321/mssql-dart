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

  // ── Multiple result sets ─────────────────────────────────────────────────────

  group('multiple result sets', () {
    test('queryMultiple returns two result sets', () async {
      final multi = await conn.queryMultiple(
          "SELECT 1 AS a, 2 AS b; SELECT 'x' AS c, 'y' AS d");
      expect(multi.length, equals(2));
      expect(multi.first.columns.map((c) => c.name).toList(),
          equals(['a', 'b']));
      expect(multi[0][0]['a'], equals(1));
      expect(multi[0][0]['b'], equals(2));
      expect(multi.second.columns.map((c) => c.name).toList(),
          equals(['c', 'd']));
      expect(multi[1][0]['c'], equals('x'));
    });

    test('queryMultiple with params returns correct result sets', () async {
      final multi = await conn.queryMultiple(
          'SELECT @v AS n; SELECT @v * 2 AS doubled', {'v': 7});
      expect(multi[0][0]['n'], equals(7));
      expect(multi[1][0]['doubled'], equals(14));
    });

    test('queryMultiple single SELECT still works', () async {
      final multi = await conn.queryMultiple('SELECT 42 AS val');
      expect(multi.length, equals(1));
      expect(multi.first[0]['val'], equals(42));
    });
  });

  // ── Streaming rows ───────────────────────────────────────────────────────────

  group('streaming', () {
    test('queryStream yields all rows', () async {
      await conn.execute('CREATE TABLE #stream (n INT)');
      await conn.execute(
          'INSERT INTO #stream VALUES (1),(2),(3),(4),(5)');
      final rows = <int>[];
      await for (final row in conn.queryStream(
          'SELECT n FROM #stream ORDER BY n')) {
        rows.add(row['n'] as int);
      }
      expect(rows, equals([1, 2, 3, 4, 5]));
    });

    test('queryStream with params filters correctly', () async {
      await conn.execute('CREATE TABLE #sfilt (n INT)');
      await conn.execute(
          'INSERT INTO #sfilt VALUES (10),(20),(30)');
      final rows = <int>[];
      await for (final row
          in conn.queryStream('SELECT n FROM #sfilt WHERE n > @min ORDER BY n',
              {'min': 15})) {
        rows.add(row['n'] as int);
      }
      expect(rows, equals([20, 30]));
    });

    test('queryStream empty result yields no rows', () async {
      final rows = <Object>[];
      await for (final row in conn.queryStream('SELECT 1 WHERE 1=0')) {
        rows.add(row);
      }
      expect(rows, isEmpty);
    });
  });

  // ── Connection pool ──────────────────────────────────────────────────────────

  group('pool', () {
    late MssqlPool pool;

    setUp(() async {
      pool = MssqlPool(const MssqlPoolConfig(
        host: '127.0.0.1',
        port: 14330,
        user: 'sa',
        password: 'Knex_Test1!',
        database: 'master',
        trustServerCertificate: true,
        min: 1,
        max: 3,
      ));
      await pool.open();
    });

    tearDown(() => pool.close());

    test('pool.query returns results', () async {
      final r = await pool.query('SELECT 1 AS n');
      expect(r[0]['n'], equals(1));
    });

    test('pool.execute returns rowsAffected', () async {
      await pool.execute('CREATE TABLE #pe (v INT)');
      final affected = await pool.execute('INSERT INTO #pe VALUES (1),(2)');
      expect(affected, equals(2));
    });

    test('pool handles concurrent queries', () async {
      final results = await Future.wait([
        pool.query('SELECT 1 AS n'),
        pool.query('SELECT 2 AS n'),
        pool.query('SELECT 3 AS n'),
      ]);
      final values = results.map((r) => r[0]['n']).toSet();
      expect(values, containsAll([1, 2, 3]));
    });

    test('pool releases connection after error', () async {
      try {
        await pool.query('SELECT 1/0');
      } catch (_) {}
      // Connection should be released — next query must succeed.
      final r = await pool.query('SELECT 42 AS ok');
      expect(r[0]['ok'], equals(42));
    });

    test('pool.transaction commits on success', () async {
      await pool.execute('CREATE TABLE #ptran (n INT)');
      await pool.transaction((c) async {
        await c.execute('INSERT INTO #ptran VALUES (99)');
      });
      final r = await pool.query('SELECT n FROM #ptran');
      expect(r[0]['n'], equals(99));
    });

    test('pool.transaction rolls back on error', () async {
      await pool.execute('CREATE TABLE #proll (n INT)');
      try {
        await pool.transaction((c) async {
          await c.execute('INSERT INTO #proll VALUES (1)');
          throw Exception('forced');
        });
      } catch (_) {}
      final r = await pool.query('SELECT COUNT(*) AS cnt FROM #proll');
      expect(r[0]['cnt'], equals(0));
    });

    test('acquire timeout throws when pool exhausted', () async {
      final tinyPool = MssqlPool(const MssqlPoolConfig(
        host: '127.0.0.1',
        port: 14330,
        user: 'sa',
        password: 'Knex_Test1!',
        trustServerCertificate: true,
        max: 1,
        acquireTimeout: Duration(milliseconds: 200),
      ));
      await tinyPool.open();
      final held = await tinyPool.acquire();
      // Pool is at max=1 — this acquire must time out (never release held).
      await expectLater(
        tinyPool.acquire(),
        throwsA(isA<MssqlException>()),
      );
      tinyPool.release(held);
      await tinyPool.close();
    });
  });
}
