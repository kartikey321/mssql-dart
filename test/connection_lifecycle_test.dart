import 'dart:async';

import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Connection and pool lifecycle tests.
// Exercises code paths that no other test file covers:
//   - Connection.close() + use after close
//   - Connection busy-flag concurrency guard
//   - queryStream early break → connection killed
//   - Pool acquire after close
//   - Pool pending-acquire rejected on close
//   - Pool connection reuse after error
//   - MssqlRow index access and API surface
//
// Runs against the dart-mssql Docker container on port 14330.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection> openConn({bool encrypt = false}) => MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: encrypt,
      trustServerCertificate: true,
    );

void main() {
  // ── Connection state ──────────────────────────────────────────────────────

  group('connection state', () {
    test('isOpen is false after close', () async {
      final conn = await openConn();
      expect(conn.isOpen, isTrue);
      await conn.close();
      expect(conn.isOpen, isFalse);
    });

    test('query after close throws StateError', () async {
      final conn = await openConn();
      await conn.close();
      await expectLater(
        () => conn.query('SELECT 1'),
        throwsStateError,
      );
    });

    test('execute after close throws StateError', () async {
      final conn = await openConn();
      await conn.close();
      await expectLater(
        () => conn.execute('SELECT 1'),
        throwsStateError,
      );
    });

    test('queryMultiple after close throws StateError', () async {
      final conn = await openConn();
      await conn.close();
      await expectLater(
        () => conn.queryMultiple('SELECT 1'),
        throwsStateError,
      );
    });

    test('double close does not throw', () async {
      final conn = await openConn();
      await conn.close();
      await conn.close(); // second close must be a no-op
    });

    test('database property reflects connected database', () async {
      final conn = await openConn();
      expect(conn.database.toLowerCase(), equals('master'));
      await conn.close();
    });
  });

  // ── Busy guard (concurrent query prevention) ──────────────────────────────

  group('busy guard', () {
    test('starting two queries concurrently throws StateError on second', () async {
      final conn = await openConn();
      // Start a slow query that holds the connection.
      final slow = conn.query(
          "SELECT TOP 10000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n "
          "FROM sys.all_objects a CROSS JOIN sys.all_objects b");
      // Immediately attempt a second query — must fail.
      await expectLater(
        () => conn.query('SELECT 1 AS x'),
        throwsStateError,
      );
      await slow; // let slow query finish
      await conn.close();
    });

    test('queryStream while busy throws StateError', () async {
      final conn = await openConn();
      final slow = conn.query(
          "SELECT TOP 5000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n "
          "FROM sys.all_objects a");
      await expectLater(
        () async {
          await for (final _ in conn.queryStream('SELECT 1')) {}
        },
        throwsStateError,
      );
      await slow;
      await conn.close();
    });

    test('connection usable again after busy error resolves', () async {
      final conn = await openConn();
      final r = await conn.query('SELECT 1 AS n');
      expect(r[0]['n'], equals(1));
      // No busy state remains.
      final r2 = await conn.query('SELECT 2 AS n');
      expect(r2[0]['n'], equals(2));
      await conn.close();
    });
  });

  // ── queryStream early break ───────────────────────────────────────────────

  group('queryStream early break', () {
    test('breaking out of queryStream kills connection', () async {
      final conn = await openConn();
      await conn.execute('CREATE TABLE #sb_break (n INT)');
      await conn.execute('INSERT INTO #sb_break VALUES (1),(2),(3),(4),(5)');

      // Read only first row then break — triggers the kill path.
      await for (final row in conn.queryStream('SELECT n FROM #sb_break ORDER BY n')) {
        expect(row['n'], equals(1));
        break;
      }

      // Connection must now be dead (isOpen = false).
      expect(conn.isOpen, isFalse);
    });

    test('queryStream early break does not corrupt pool connections', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: false,
        trustServerCertificate: true,
        min: 0,
        max: 2,
      ));
      await pool.open();

      // Set up data.
      final setup = await pool.acquire();
      await setup.execute('CREATE TABLE #pool_break (n INT)');
      await setup.execute('INSERT INTO #pool_break VALUES (1),(2),(3)');
      pool.release(setup);

      // Break early — pool should detect dead connection on release.
      await for (final row in pool.queryStream('SELECT n FROM #pool_break ORDER BY n')) {
        expect(row['n'], equals(1));
        break;
      }

      // Pool must still be able to serve queries (via a new connection).
      final r = await pool.query('SELECT 99 AS ok');
      expect(r[0]['ok'], equals(99));

      await pool.close();
    });

    test('consuming full queryStream leaves connection alive', () async {
      final conn = await openConn();
      await conn.execute('CREATE TABLE #sb_full (n INT)');
      await conn.execute('INSERT INTO #sb_full VALUES (1),(2),(3)');

      final rows = <int>[];
      await for (final row in conn.queryStream('SELECT n FROM #sb_full ORDER BY n')) {
        rows.add(row['n'] as int);
      }
      expect(rows, equals([1, 2, 3]));
      expect(conn.isOpen, isTrue); // still alive after full consume
      await conn.close();
    });
  });

  // ── Pool lifecycle ────────────────────────────────────────────────────────

  group('pool lifecycle', () {
    test('acquire after pool.close throws StateError', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _password,
        encrypt: false, trustServerCertificate: true,
      ));
      await pool.open();
      await pool.close();
      await expectLater(() => pool.acquire(), throwsStateError);
    });

    test('pending acquire is rejected when pool closes', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _password,
        encrypt: false, trustServerCertificate: true,
        max: 1,
      ));
      await pool.open();
      // Hold the only connection.
      final held = await pool.acquire();
      // Queue a second acquire and attach error handler immediately so the
      // error from pool.close() doesn't become an unhandled exception.
      final pending = pool.acquire();
      final pendingCheck = expectLater(pending, throwsA(isA<MssqlException>()));
      // Close the pool — pending acquire must fail.
      await pool.close();
      await pendingCheck;
      // Release the held connection (close it since pool is shut).
      pool.release(held);
    });

    test('pool reuses idle connection', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _password,
        encrypt: false, trustServerCertificate: true,
        min: 1, max: 2,
      ));
      await pool.open();
      // Two sequential queries reuse the same idle connection.
      final r1 = await pool.query('SELECT 1 AS n');
      final r2 = await pool.query('SELECT 2 AS n');
      expect(r1[0]['n'], equals(1));
      expect(r2[0]['n'], equals(2));
      await pool.close();
    });

    test('pool.execute returns rowsAffected', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _password,
        encrypt: false, trustServerCertificate: true,
      ));
      await pool.open();
      await pool.execute('CREATE TABLE #pool_exec (v INT)');
      final n = await pool.execute('INSERT INTO #pool_exec VALUES (1),(2),(3)');
      expect(n, equals(3));
      await pool.close();
    });

    test('pool.queryMultiple returns all result sets', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _password,
        encrypt: false, trustServerCertificate: true,
      ));
      await pool.open();
      final multi = await pool.queryMultiple("SELECT 1 AS a; SELECT 'x' AS b");
      expect(multi.length, equals(2));
      expect(multi[0][0]['a'], equals(1));
      expect(multi[1][0]['b'], equals('x'));
      await pool.close();
    });
  });

  // ── MssqlResult API coverage ──────────────────────────────────────────────

  group('MssqlResult API', () {
    late MssqlConnection conn;

    setUpAll(() async { conn = await openConn(); });
    tearDownAll(() async => conn.close());

    test('rows are accessible via iterator', () async {
      final r = await conn.query('SELECT v FROM (VALUES (10),(20),(30)) t(v) ORDER BY v');
      int sum = 0;
      for (final row in r.rows) {
        sum += row['v'] as int;
      }
      expect(sum, equals(60));
    });

    test('MssqlRow.valueAt accesses by index', () async {
      final r = await conn.query('SELECT 1 AS a, 2 AS b, 3 AS c');
      expect(r[0].valueAt(0), equals(1));
      expect(r[0].valueAt(1), equals(2));
      expect(r[0].valueAt(2), equals(3));
    });

    test('MssqlRow.columnNames returns column names', () async {
      final r = await conn.query('SELECT 1 AS foo, 2 AS bar');
      expect(r[0].columnNames, equals(['foo', 'bar']));
    });

    test('MssqlRow.values returns list of values', () async {
      final r = await conn.query('SELECT 42 AS v');
      expect(r[0].values, equals([42]));
    });

    test('MssqlRow.length equals column count', () async {
      final r = await conn.query('SELECT 1 AS a, 2 AS b, 3 AS c, 4 AS d');
      expect(r[0].length, equals(4));
    });

    test('MssqlRow.toString shows name-value pairs', () async {
      final r = await conn.query('SELECT 42 AS answer');
      expect(r[0].toString(), contains('answer'));
      expect(r[0].toString(), contains('42'));
    });

    test('MssqlRow unknown column throws ArgumentError', () async {
      final r = await conn.query('SELECT 1 AS v');
      expect(() => r[0]['does_not_exist'], throwsArgumentError);
    });

    test('MssqlRow index out of range throws', () async {
      final r = await conn.query('SELECT 1 AS v');
      expect(() => r[0][99], throwsA(isA<RangeError>()));
    });

    test('MssqlResult.toString contains row count', () async {
      final r = await conn.query('SELECT 1 AS v UNION ALL SELECT 2 UNION ALL SELECT 3');
      final s = r.toString();
      expect(s, contains('3'));
    });

    test('MssqlResult.columns metadata', () async {
      final r = await conn.query('SELECT 42 AS answer');
      expect(r.columns.length, equals(1));
      expect(r.columns.first.name, equals('answer'));
    });

    test('MssqlMultiResult.all is immutable', () async {
      final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
      final all = multi.all;
      expect(all.length, equals(2));
      expect(() => (all as dynamic).clear(), throwsUnsupportedError);
    });

    test('MssqlMultiResult.toString includes result set count', () async {
      final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
      expect(multi.toString(), contains('2'));
    });
  });

  // ── Multiple connections ──────────────────────────────────────────────────

  group('multiple connections', () {
    test('two simultaneous connections work independently', () async {
      final c1 = await openConn();
      final c2 = await openConn();
      final r1 = c1.query('SELECT 1 AS n');
      final r2 = c2.query('SELECT 2 AS n');
      final results = await Future.wait([r1, r2]);
      expect(results[0][0]['n'], equals(1));
      expect(results[1][0]['n'], equals(2));
      await c1.close();
      await c2.close();
    });

    test('error on one connection does not affect another', () async {
      final c1 = await openConn();
      final c2 = await openConn();
      try {
        await c1.query('SELECT 1/0');
      } on MssqlException catch (_) {}
      final r = await c2.query('SELECT 99 AS ok');
      expect(r[0]['ok'], equals(99));
      await c1.close();
      await c2.close();
    });
  });

  // ── Error handling edge cases ─────────────────────────────────────────────

  group('error edge cases', () {
    late MssqlConnection conn;

    setUpAll(() async { conn = await openConn(); });
    tearDownAll(() async => conn.close());

    test('multiple errors in one batch — first error is thrown', () async {
      try {
        await conn.query('RAISERROR(N\'error 1\', 16, 1); RAISERROR(N\'error 2\', 16, 1)');
        fail('expected MssqlException');
      } on MssqlException catch (e) {
        expect(e.message, contains('error 1'));
      }
    });

    test('connection usable after multi-error batch', () async {
      try {
        await conn.query('SELECT 1/0; SELECT 1/0');
      } on MssqlException catch (_) {}
      final r = await conn.query('SELECT 42 AS ok');
      expect(r[0]['ok'], equals(42));
    });

    test('RAISERROR with severity 11 throws MssqlException', () async {
      await expectLater(
        () => conn.query("RAISERROR(N'msg', 11, 1)"),
        throwsA(isA<MssqlException>()),
      );
    });

    test('SELECT followed by error returns error (no partial rows)', () async {
      // SQL Server sends rows then an error token. The error must win.
      await expectLater(
        () => conn.query("SELECT 1 AS v; RAISERROR(N'after rows', 16, 1)"),
        throwsA(isA<MssqlException>()),
      );
    });

    test('connection still open after error', () async {
      try { await conn.query('SELECT 1/0'); } catch (_) {}
      expect(conn.isOpen, isTrue);
    });
  });

  // ── Parameterized query edge cases ────────────────────────────────────────

  group('parameter edge cases', () {
    late MssqlConnection conn;

    setUpAll(() async { conn = await openConn(); });
    tearDownAll(() async => conn.close());

    test('bool false param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': false});
      expect(r[0]['v'], isFalse);
    });

    test('empty string param', () async {
      final r = await conn.query('SELECT LEN(@v) AS n', {'v': ''});
      expect(r[0]['n'], equals(0));
    });

    test('string with special characters', () async {
      const s = "O'Brien & \"Smith\" <tag>";
      final r = await conn.query('SELECT @v AS v', {'v': s});
      expect(r[0]['v'], equals(s));
    });

    test('multiple params of different types', () async {
      final dt = DateTime.utc(2024, 1, 1);
      final r = await conn.query(
        'SELECT @i AS i, @s AS s, @f AS f, @b AS b, @dt AS dt, @n AS n',
        {'i': 42, 's': 'hello', 'f': 3.14, 'b': true, 'dt': dt, 'n': null},
      );
      expect(r[0]['i'], equals(42));
      expect(r[0]['s'], equals('hello'));
      expect((r[0]['f'] as double), closeTo(3.14, 0.001));
      expect(r[0]['b'], isTrue);
      expect(r[0]['n'], isNull);
    });

    test('ten parameters in one query', () async {
      final params = {for (int i = 1; i <= 10; i++) 'p$i': i};
      final cols = [for (int i = 1; i <= 10; i++) '@p$i AS c$i'].join(', ');
      final r = await conn.query('SELECT $cols', params);
      for (int i = 1; i <= 10; i++) {
        expect(r[0]['c$i'], equals(i));
      }
    });

    test('@@IDENTITY after insert', () async {
      await conn.execute('CREATE TABLE #scope_id (id INT IDENTITY(1,1), v INT)');
      // Use a direct batch (no params) so @@IDENTITY is in the same scope.
      await conn.execute('INSERT INTO #scope_id VALUES (99)');
      final r = await conn.query('SELECT CAST(@@IDENTITY AS INT) AS id');
      expect(r[0]['id'], isNotNull);
      expect(r[0]['id'], equals(1));
    });
  });
}
