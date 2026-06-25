import 'dart:async';
import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Targeted tests to cover specific uncovered branches identified by lcov.
// Each group is annotated with which source lines it exercises.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection> openConn() => MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );

MssqlPool openPool({int max = 3, Duration? acquireTimeout}) => MssqlPool(
      MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: false,
        trustServerCertificate: true,
        min: 0,
        max: max,
        acquireTimeout: acquireTimeout ?? const Duration(seconds: 5),
      ),
    );

void main() {
  // ── Login error path (token_stream.dart:81-82) ────────────────────────────
  // Wrong credentials → server sends tokenError during login response.

  group('login error', () {
    test('wrong password throws MssqlException', () async {
      await expectLater(
        MssqlConnection.connect(
          host: _host,
          port: _port,
          user: _user,
          password: 'definitely_wrong_password!',
          database: 'master',
          encrypt: false,
          trustServerCertificate: true,
        ),
        throwsA(isA<MssqlException>()),
      );
    });

    test('wrong user throws MssqlException', () async {
      await expectLater(
        MssqlConnection.connect(
          host: _host,
          port: _port,
          user: 'no_such_user',
          password: _password,
          database: 'master',
          encrypt: false,
          trustServerCertificate: true,
        ),
        throwsA(isA<MssqlException>()),
      );
    });
  });

  // ── INFO token in query response (token_stream.dart:159) ─────────────────
  // PRINT statements send tokenInfo (0xAB) before the result.

  group('tokenInfo in query response', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('PRINT before SELECT does not crash (tokenInfo skipped)', () async {
      final r = await conn.query("PRINT 'hi'; SELECT 42 AS v");
      expect(r[0]['v'], equals(42));
    });

    test('connection usable after PRINT query', () async {
      await conn.query("PRINT 'test'");
      final r = await conn.query('SELECT 1 AS ok');
      expect(r[0]['ok'], equals(1));
    });
  });

  // ── tokenInfo in queryStream (token_stream.dart:232) ─────────────────────

  group('tokenInfo in queryStream', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('PRINT before SELECT in queryStream does not crash', () async {
      final rows = <int>[];
      await for (final row
          in conn.queryStream("PRINT 'stream'; SELECT 99 AS v")) {
        rows.add(row['v'] as int);
      }
      expect(rows, equals([99]));
    });
  });

  // ── envChange in queryStream (token_stream.dart:226) ──────────────────────
  // BEGIN TRANSACTION sends an envChange token inside the response stream.

  group('envChange in queryStream', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('batch with BEGIN/COMMIT TRAN in queryStream emits envChange',
        () async {
      final rows = <int>[];
      await for (final row in conn.queryStream(
          'BEGIN TRANSACTION; SELECT 5 AS v; COMMIT TRANSACTION')) {
        rows.add(row['v'] as int);
      }
      expect(rows, equals([5]));
    });
  });

  // ── NUMERIC type (type_info.dart:213) ────────────────────────────────────
  // typeNumericN is the case label just before return _decodeDecimal().

  group('numeric type', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('NUMERIC(5,2) returns correct double', () async {
      final r = await conn.query("SELECT CAST(3.14 AS numeric(5,2)) AS v");
      expect((r[0]['v'] as double), closeTo(3.14, 0.001));
    });

    test('NUMERIC(10,4) negative value', () async {
      final r =
          await conn.query("SELECT CAST(-1234.5678 AS numeric(10,4)) AS v");
      expect((r[0]['v'] as double), closeTo(-1234.5678, 0.001));
    });

    test('NULL NUMERIC is returned as null', () async {
      final r = await conn.query('SELECT CAST(NULL AS numeric(5,2)) AS v');
      expect(r[0]['v'], isNull);
    });
  });

  // ── Pool acquire timeout (pool.dart:128-132) ──────────────────────────────

  group('pool acquire timeout', () {
    test('acquire timeout throws MssqlException when pool full', () async {
      final pool =
          openPool(max: 1, acquireTimeout: const Duration(milliseconds: 200));
      final conn = await pool.acquire();
      try {
        // Pool is full; next acquire must timeout.
        await expectLater(
          pool.acquire(),
          throwsA(isA<MssqlException>()
              .having((e) => e.message, 'message', contains('timeout'))),
        );
      } finally {
        pool.release(conn);
        await pool.close();
      }
    });
  });

  // ── Pool pending handoff (pool.dart:151-153) ──────────────────────────────
  // release() should directly hand a connection to the next pending waiter.

  group('pool pending handoff', () {
    test('release hands off to pending waiter directly', () async {
      final pool = openPool(max: 1);
      final conn = await pool.acquire();

      // Queue a second acquire while pool is at capacity.
      final pending = pool.acquire();

      // Release triggers the handoff path (pool.dart:151-153).
      pool.release(conn);

      final conn2 = await pending;
      expect(conn2.isOpen, isTrue);
      pool.release(conn2);
      await pool.close();
    });
  });

  // ── Pool dead idle connection (pool.dart:103) ─────────────────────────────
  // If a connection dies while idle, acquire() must skip it and create a new one.

  group('pool dead idle connection', () {
    test('pool creates new connection when idle one is dead', () async {
      final pool = openPool(max: 2);

      final conn = await pool.acquire();
      pool.release(conn); // conn is alive and goes to idle list

      // Close the connection directly — it's now dead in the idle list.
      await conn.close();

      // acquire() should detect isOpen=false and open a fresh connection.
      final conn2 = await pool.acquire();
      expect(conn2.isOpen, isTrue);
      final r = await conn2.query('SELECT 1 AS v');
      expect(r[0]['v'], equals(1));
      pool.release(conn2);
      await pool.close();
    });
  });

  // ── pool.queryStream (covers pool stream delegation) ─────────────────────

  group('pool queryStream', () {
    late MssqlPool pool;
    setUpAll(() async => pool = openPool());
    tearDownAll(() async => pool.close());

    test('pool.queryStream returns rows', () async {
      final rows = <int>[];
      await for (final row
          in pool.queryStream('SELECT 1 AS v UNION SELECT 2')) {
        rows.add(row['v'] as int);
      }
      expect(rows, containsAll([1, 2]));
    });
  });

  // ── Large VARCHAR(MAX) via PLP (type_info.dart:290-291) ──────────────────
  // BigVarChar returned through PLP path returns String via fromCharCodes(data).

  group('VARCHAR(MAX) large content', () {
    late MssqlConnection conn;
    setUpAll(() async {
      conn = await openConn();
      await conn.execute('CREATE TABLE #vmax_t (v VARCHAR(MAX))');
      // 5000 'A' chars — spans PLP chunks and triggers BigVarChar PLP path.
      await conn.execute(
          "INSERT INTO #vmax_t VALUES (REPLICATE(CAST('A' AS varchar(max)), 5000))");
    });
    tearDownAll(() async => conn.close());

    test('VARCHAR(MAX) with 5000 chars returned as String', () async {
      final r = await conn.query('SELECT v FROM #vmax_t');
      expect((r[0]['v'] as String).length, equals(5000));
    });

    test('VARCHAR(MAX) content is correct', () async {
      final r = await conn.query('SELECT v FROM #vmax_t');
      expect(r[0]['v'], equals('A' * 5000));
    });
  });

  // ── Error in queryStream (token_stream.dart:234-235) ─────────────────────

  group('error in queryStream', () {
    test('queryStream propagates server error', () async {
      final conn = await openConn();
      try {
        await expectLater(
          conn.queryStream("SELECT 1/0 AS v").toList(),
          throwsA(isA<MssqlException>()),
        );
      } finally {
        await conn.close();
      }
    });
  });
}
