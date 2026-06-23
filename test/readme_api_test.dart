// Verifies every API snippet documented in README.md actually compiles and
// behaves as described. One test per README code block / bullet point.

import 'dart:async';
import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _pass = 'Knex_Test1!';

MssqlConnection? _sharedConn;
Future<MssqlConnection> openConn() => MssqlConnection.connect(
      host: _host, port: _port, user: _user, password: _pass,
      database: 'master', encrypt: false, trustServerCertificate: true,
    );

void main() {
  // ── MssqlConnection.connect params ─────────────────────────────────────────

  group('MssqlConnection.connect', () {
    test('all named params compile and connect', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _pass,
        database: 'master',
        encrypt: false,
        trustServerCertificate: true,
        timeout: const Duration(seconds: 30),
      );
      expect(conn.isOpen, isTrue);
      await conn.close();
    });

    test('connect without explicit port uses default 1433 signature', () async {
      // port is optional — verify it compiles without it. The connection will
      // fail (no server on 1433) but that's fine; we just need it to compile.
      try {
        await MssqlConnection.connect(
          host: '127.0.0.1', user: _user, password: _pass,
          timeout: const Duration(seconds: 2),
        );
      } catch (_) {
        // Expected — no server on 1433. Named params compiled fine.
      }
    });
  });

  // ── AzureAdAuth constructors ────────────────────────────────────────────────

  group('AzureAdAuth', () {
    test('AzureAdAuth.fromToken(token) is the correct factory', () {
      // README previously showed AzureAdAuth(bearerToken: token) — that's wrong.
      // The real API is AzureAdAuth.fromToken(token).
      final auth = AzureAdAuth.fromToken('fake-token');
      expect(auth.bearerToken, equals('fake-token'));
    });
  });

  // ── conn.query return value API ─────────────────────────────────────────────

  group('MssqlResult API', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('result[i] indexing returns MssqlRow', () async {
      final result = await conn.query("SELECT 1 AS id, 'Alice' AS name");
      expect(result[0], isA<MssqlRow>());
    });

    test('row["name"] — access by column name', () async {
      final result = await conn.query("SELECT 'Alice' AS name");
      expect(result[0]['name'], equals('Alice'));
    });

    test('row.valueAt(0) — access by zero-based index', () async {
      final result = await conn.query('SELECT 42 AS v');
      expect(result[0].valueAt(0), equals(42));
    });

    test('row.columnNames — List<String>', () async {
      final result = await conn.query('SELECT 1 AS id, 2 AS score');
      expect(result[0].columnNames, equals(['id', 'score']));
    });

    test('row.values — List<Object?>', () async {
      final result = await conn.query('SELECT 7 AS v');
      expect(result[0].values, equals([7]));
    });

    test('result.rows — List<MssqlRow>', () async {
      final result = await conn.query('SELECT 1 AS v UNION SELECT 2');
      expect(result.rows, isA<List<MssqlRow>>());
      expect(result.rows.length, equals(2));
    });

    test('result.rowsAffected — int', () async {
      await conn.execute('CREATE TABLE #raf (v INT)');
      final result = await conn.query('INSERT INTO #raf VALUES (1)');
      expect(result.rowsAffected, isA<int>());
    });

    test('result.length — row count', () async {
      final result = await conn.query(
          'SELECT 1 AS v UNION SELECT 2 UNION SELECT 3');
      expect(result.length, equals(3));
    });

    test('result.isEmpty — false when rows exist', () async {
      final result = await conn.query('SELECT 1 AS v');
      expect(result.isEmpty, isFalse);
    });

    test('result.isEmpty — true when no rows', () async {
      final result = await conn.query('SELECT 1 AS v WHERE 1=0');
      expect(result.isEmpty, isTrue);
    });

    test('named parameters with @name syntax', () async {
      final result = await conn.query(
        'SELECT @cust AS c, @flag AS f',
        {'cust': 'Acme', 'flag': true},
      );
      expect(result[0]['c'], equals('Acme'));
      expect(result[0]['f'], equals(true));
    });
  });

  // ── conn.execute ────────────────────────────────────────────────────────────

  group('conn.execute', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('returns rows affected as int', () async {
      await conn.execute('CREATE TABLE #exec_api (msg NVARCHAR(100))');
      final n = await conn.execute(
        'INSERT INTO #exec_api (msg) VALUES (@msg)',
        {'msg': 'hello'},
      );
      expect(n, equals(1));
    });
  });

  // ── conn.queryMultiple ──────────────────────────────────────────────────────

  group('conn.queryMultiple', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('multi.first — first result set', () async {
      final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
      expect(multi.first[0]['a'], equals(1));
    });

    test('multi.second — second result set', () async {
      final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
      expect(multi.second[0]['b'], equals(2));
    });

    test('multi.all — List<MssqlResult>', () async {
      final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
      expect(multi.all, isA<List<MssqlResult>>());
      expect(multi.all.length, equals(2));
    });

    test('multi[index] — index operator', () async {
      final multi = await conn.queryMultiple('SELECT 10 AS v; SELECT 20 AS v');
      expect(multi[0][0]['v'], equals(10));
      expect(multi[1][0]['v'], equals(20));
    });

    test('multi.length', () async {
      final multi = await conn.queryMultiple('SELECT 1; SELECT 2; SELECT 3');
      expect(multi.length, equals(3));
    });
  });

  // ── conn.queryStream ────────────────────────────────────────────────────────

  group('conn.queryStream', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('streams rows without parameters', () async {
      final rows = <int>[];
      await for (final row in conn.queryStream(
          'SELECT number AS v FROM master.dbo.spt_values '
          "WHERE type = 'P' AND number < 5 ORDER BY number")) {
        rows.add(row['v'] as int);
      }
      expect(rows, equals([0, 1, 2, 3, 4]));
    });

    test('streams rows with @name parameters', () async {
      final rows = <int>[];
      await for (final row in conn.queryStream(
        'SELECT number AS v FROM master.dbo.spt_values '
        "WHERE type = 'P' AND number < @limit ORDER BY number",
        {'limit': 3},
      )) {
        rows.add(row['v'] as int);
      }
      expect(rows, equals([0, 1, 2]));
    });

    test('MssqlRow from stream supports column-name access', () async {
      MssqlRow? first;
      await for (final row in conn.queryStream("SELECT 'hi' AS msg")) {
        first = row;
        break;
      }
      expect(first!['msg'], equals('hi'));
    });
  });

  // ── transactions ────────────────────────────────────────────────────────────

  group('transactions', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('callback form commits on success', () async {
      await conn.execute('CREATE TABLE #tx_cb (v INT)');
      await conn.transaction((c) async {
        await c.execute('INSERT INTO #tx_cb VALUES (1)');
        await c.execute('INSERT INTO #tx_cb VALUES (2)');
      });
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_cb');
      expect(r[0]['n'], equals(2));
    });

    test('callback form rolls back on exception', () async {
      await conn.execute('CREATE TABLE #tx_rb (v INT)');
      try {
        await conn.transaction((c) async {
          await c.execute('INSERT INTO #tx_rb VALUES (99)');
          throw Exception('boom');
        });
      } catch (_) {}
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_rb');
      expect(r[0]['n'], equals(0));
    });

    test('manual beginTransaction / commitTransaction', () async {
      await conn.execute('CREATE TABLE #tx_manual (v INT)');
      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_manual VALUES (7)');
      await conn.commitTransaction();
      final r = await conn.query('SELECT v FROM #tx_manual');
      expect(r[0]['v'], equals(7));
    });

    test('manual beginTransaction / rollbackTransaction', () async {
      await conn.execute('CREATE TABLE #tx_manual2 (v INT)');
      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_manual2 VALUES (7)');
      await conn.rollbackTransaction();
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_manual2');
      expect(r[0]['n'], equals(0));
    });
  });

  // ── conn.isOpen / conn.database / conn.close ────────────────────────────────

  group('connection state', () {
    test('isOpen is true after connect', () async {
      final conn = await openConn();
      expect(conn.isOpen, isTrue);
      await conn.close();
    });

    test('isOpen is false after close', () async {
      final conn = await openConn();
      await conn.close();
      expect(conn.isOpen, isFalse);
    });

    test('database returns current database name', () async {
      final conn = await openConn();
      expect(conn.database.toLowerCase(), equals('master'));
      await conn.close();
    });
  });

  // ── MssqlPool API ───────────────────────────────────────────────────────────

  group('MssqlPool', () {
    test('MssqlPoolConfig all documented params compile', () {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _pass,
        database: 'master',
        encrypt: false,
        trustServerCertificate: true,
        min: 1,
        max: 5,
        idleTimeout: const Duration(seconds: 30),
        acquireTimeout: const Duration(seconds: 15),
        connectionTimeout: const Duration(seconds: 30),
      ));
      expect(pool, isA<MssqlPool>());
      // Don't open — just verify the config compiles.
    });

    test('pool.open() pre-warms min connections', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
        min: 1, max: 3,
      ));
      await pool.open(); // documented as optional pre-warm
      final r = await pool.query('SELECT 1 AS v');
      expect(r[0]['v'], equals(1));
      await pool.close();
    });

    test('pool.query with named parameters', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      final result = await pool.query('SELECT @id AS v', {'id': 42});
      expect(result[0]['v'], equals(42));
      await pool.close();
    });

    test('pool.execute returns int', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      final n = await pool.execute('SELECT 1');
      expect(n, isA<int>());
      await pool.close();
    });

    test('pool.queryMultiple returns MssqlMultiResult', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      final multi = await pool.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
      expect(multi.first[0]['a'], equals(1));
      expect(multi.second[0]['b'], equals(2));
      await pool.close();
    });

    test('pool.queryStream streams rows', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      final rows = <int>[];
      await for (final row in pool.queryStream(
          'SELECT 1 AS v UNION SELECT 2 UNION SELECT 3')) {
        rows.add(row['v'] as int);
      }
      expect(rows.length, equals(3));
      await pool.close();
    });

    test('pool.transaction commits on success', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      await pool.execute(
          'IF OBJECT_ID(\'tempdb..##readme_tx\') IS NOT NULL DROP TABLE ##readme_tx');
      await pool.execute('CREATE TABLE ##readme_tx (v INT)');
      await pool.transaction((conn) async {
        await conn.execute('INSERT INTO ##readme_tx VALUES (1)');
      });
      final r = await pool.query('SELECT COUNT(*) AS n FROM ##readme_tx');
      expect(r[0]['n'], equals(1));
      await pool.execute('DROP TABLE ##readme_tx');
      await pool.close();
    });

    test('pool.acquire returns open connection', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      final conn = await pool.acquire();
      expect(conn.isOpen, isTrue);
      final r = await conn.query('SELECT 1 AS v');
      expect(r[0]['v'], equals(1));
      pool.release(conn);
      await pool.close();
    });

    test('pool.release — connection goes back to idle', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
        max: 1,
      ));
      final c1 = await pool.acquire();
      pool.release(c1);
      // Should be able to acquire again immediately.
      final c2 = await pool.acquire();
      expect(c2.isOpen, isTrue);
      pool.release(c2);
      await pool.close();
    });

    test('pool.close rejects subsequent acquires', () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false, trustServerCertificate: true,
      ));
      await pool.close();
      expect(() => pool.acquire(), throwsA(isA<StateError>()));
    });
  });

  // ── MssqlException API ──────────────────────────────────────────────────────

  group('MssqlException', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('message — String', () async {
      try {
        await conn.query('SELECT * FROM nonexistent_xyz');
      } on MssqlException catch (e) {
        expect(e.message, isA<String>());
        expect(e.message, isNotEmpty);
      }
    });

    test('errorCode — int (208 = invalid object name)', () async {
      try {
        await conn.query('SELECT * FROM nonexistent_xyz');
      } on MssqlException catch (e) {
        expect(e.errorCode, equals(208));
      }
    });

    test('severity — nullable int', () async {
      try {
        await conn.query('SELECT 1/0');
      } on MssqlException catch (e) {
        // severity is int? per README; may be null or a value
        expect(e.severity, anyOf(isNull, isA<int>()));
      }
    });

    test('precedingErrors — list populated for multi-error batch', () async {
      try {
        await conn.query(
            "RAISERROR(N'err1', 16, 1); RAISERROR(N'err2', 16, 1)");
      } on MssqlException catch (e) {
        expect(e.precedingErrors, isA<List<MssqlException>>());
        expect(e.precedingErrors.length, equals(2));
      }
    });
  });

  // ── Parameter type mappings ─────────────────────────────────────────────────

  group('parameter types', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() => conn.close());

    test('int param → BIGINT', () async {
      final r = await conn.query('SELECT @v AS v', {'v': 123});
      expect(r[0]['v'], equals(123));
    });

    test('double param → FLOAT', () async {
      final r = await conn.query('SELECT @v AS v', {'v': 1.5});
      expect((r[0]['v'] as double), closeTo(1.5, 0.001));
    });

    test('bool param → BIT', () async {
      final r = await conn.query('SELECT @v AS v', {'v': true});
      expect(r[0]['v'], equals(true));
    });

    test('String param → NVARCHAR', () async {
      final r = await conn.query('SELECT @v AS v', {'v': 'hello'});
      expect(r[0]['v'], equals('hello'));
    });

    test('List<int> param → VARBINARY', () async {
      final r = await conn.query('SELECT @v AS v', {'v': [0xDE, 0xAD]});
      expect(r[0]['v'], equals([0xDE, 0xAD]));
    });

    test('DateTime param → DATETIME2', () async {
      final dt = DateTime.utc(2024, 6, 15, 10, 30, 0);
      final r  = await conn.query('SELECT @v AS v', {'v': dt});
      final back = r[0]['v'] as DateTime;
      expect(back.year,  equals(2024));
      expect(back.month, equals(6));
      expect(back.day,   equals(15));
    });

    test('null param → NULL', () async {
      final r = await conn.query('SELECT @v AS v', {'v': null});
      expect(r[0]['v'], isNull);
    });
  });

  // ── TLS / encryption ────────────────────────────────────────────────────────

  group('TLS encryption', () {
    test('encrypt:false connects to local container', () async {
      final conn = await MssqlConnection.connect(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master', encrypt: false,
      );
      expect(conn.isOpen, isTrue);
      await conn.close();
    });

    test('encrypt:true + trustServerCertificate:true connects', () async {
      final conn = await MssqlConnection.connect(
        host: _host, port: _port, user: _user, password: _pass,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      expect(conn.isOpen, isTrue);
      await conn.close();
    });
  });
}
