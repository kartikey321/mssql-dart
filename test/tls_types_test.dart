import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Tests for TLS connection path and additional SQL types not covered elsewhere.
// Covers: encrypt=true + trustServerCertificate, transaction helpers, money,
// smallmoney, smalldatetime, uniqueidentifier, time, datetimeoffset types.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection> openConn({bool encrypt = false}) =>
    MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: encrypt,
      trustServerCertificate: true,
    );

void main() {
  // ── TLS connection ─────────────────────────────────────────────────────────

  group('TLS connection', () {
    test('connects with encrypt=true and trustServerCertificate', () async {
      final conn = await openConn(encrypt: true);
      final r = await conn.query('SELECT 1 AS v');
      expect(r[0]['v'], equals(1));
      await conn.close();
    });

    test('TLS connection can query after connect', () async {
      final conn = await openConn(encrypt: true);
      final r = await conn.query("SELECT 'hello' AS v");
      expect(r[0]['v'], equals('hello'));
      await conn.close();
    });

    test('TLS connection execute works', () async {
      final conn = await openConn(encrypt: true);
      final n = await conn.execute('SELECT 1');
      expect(n, isA<int>());
      await conn.close();
    });
  });

  // ── Transaction helpers ────────────────────────────────────────────────────

  group('connection transactions', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('beginTransaction / commitTransaction', () async {
      await conn.execute('CREATE TABLE #tx_commit (v INT)');
      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_commit VALUES (1)');
      await conn.commitTransaction();
      final r = await conn.query('SELECT v FROM #tx_commit');
      expect(r[0]['v'], equals(1));
    });

    test('beginTransaction / rollbackTransaction discards changes', () async {
      await conn.execute('CREATE TABLE #tx_rollback (v INT)');
      await conn.beginTransaction();
      await conn.execute('INSERT INTO #tx_rollback VALUES (99)');
      await conn.rollbackTransaction();
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_rollback');
      expect(r[0]['n'], equals(0));
    });

    test('transaction() commits on success', () async {
      await conn.execute('CREATE TABLE #tx_fn (v INT)');
      await conn.transaction((c) async {
        await c.execute('INSERT INTO #tx_fn VALUES (42)');
      });
      final r = await conn.query('SELECT v FROM #tx_fn');
      expect(r[0]['v'], equals(42));
    });

    test('transaction() rolls back on error', () async {
      await conn.execute('CREATE TABLE #tx_err (v INT)');
      try {
        await conn.transaction((c) async {
          await c.execute('INSERT INTO #tx_err VALUES (7)');
          throw Exception('intentional');
        });
      } catch (_) {}
      final r = await conn.query('SELECT COUNT(*) AS n FROM #tx_err');
      expect(r[0]['n'], equals(0));
    });
  });

  // ── Pool transaction ───────────────────────────────────────────────────────

  group('pool transaction', () {
    late MssqlPool pool;
    setUpAll(() async {
      pool = MssqlPool(MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: false,
        trustServerCertificate: true,
        min: 1,
        max: 3,
      ));
    });
    tearDownAll(() async => pool.close());

    test('pool.transaction commits on success', () async {
      await pool.execute('CREATE TABLE #pool_tx (v INT)');
      await pool.transaction((c) async {
        await c.execute('INSERT INTO #pool_tx VALUES (11)');
      });
      final r = await pool.query('SELECT v FROM #pool_tx');
      expect(r[0]['v'], equals(11));
    });

    test('pool.transaction rolls back on error', () async {
      await pool.execute('CREATE TABLE #pool_tx_err (v INT)');
      try {
        await pool.transaction((c) async {
          await c.execute('INSERT INTO #pool_tx_err VALUES (5)');
          throw Exception('boom');
        });
      } catch (_) {}
      final r = await pool.query('SELECT COUNT(*) AS n FROM #pool_tx_err');
      expect(r[0]['n'], equals(0));
    });
  });

  // ── Money types ───────────────────────────────────────────────────────────

  group('money types', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('MONEY value is returned as double', () async {
      final r = await conn.query("SELECT CAST(1234.56 AS money) AS v");
      expect((r[0]['v'] as double), closeTo(1234.56, 0.01));
    });

    test('SMALLMONEY value is returned as double', () async {
      final r = await conn.query("SELECT CAST(99.99 AS smallmoney) AS v");
      expect((r[0]['v'] as double), closeTo(99.99, 0.01));
    });

    test('MONEY zero', () async {
      final r = await conn.query("SELECT CAST(0 AS money) AS v");
      expect((r[0]['v'] as double), closeTo(0.0, 0.0001));
    });

    test('MONEY negative', () async {
      final r = await conn.query("SELECT CAST(-500.25 AS money) AS v");
      expect((r[0]['v'] as double), closeTo(-500.25, 0.01));
    });

    test('NULL MONEY is returned as null', () async {
      final r = await conn.query("SELECT CAST(NULL AS money) AS v");
      expect(r[0]['v'], isNull);
    });
  });

  // ── SmallDateTime type ────────────────────────────────────────────────────

  group('smalldatetime type', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('SMALLDATETIME returns correct date and time', () async {
      final r = await conn
          .query("SELECT CAST('2023-06-15 10:30:00' AS smalldatetime) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2023));
      expect(d.month, equals(6));
      expect(d.day, equals(15));
      expect(d.hour, equals(10));
      expect(d.minute, equals(30));
    });

    test('NULL SMALLDATETIME is returned as null', () async {
      final r = await conn.query('SELECT CAST(NULL AS smalldatetime) AS v');
      expect(r[0]['v'], isNull);
    });
  });

  // ── UniqueIdentifier (GUID) ───────────────────────────────────────────────

  group('uniqueidentifier type', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('UNIQUEIDENTIFIER is returned as String in GUID format', () async {
      final r = await conn.query(
          "SELECT CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS v");
      final v = r[0]['v'] as String;
      // GUID format: 8-4-4-4-12 hex chars separated by dashes
      expect(
          v,
          matches(RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')));
    });

    test('NEWID() returns a GUID string', () async {
      final r = await conn.query('SELECT NEWID() AS v');
      final v = r[0]['v'] as String;
      expect(v.length, equals(36));
      expect(v.split('-').length, equals(5));
    });

    test('NULL UNIQUEIDENTIFIER is returned as null', () async {
      final r = await conn.query('SELECT CAST(NULL AS uniqueidentifier) AS v');
      expect(r[0]['v'], isNull);
    });
  });

  // ── Time type ─────────────────────────────────────────────────────────────

  group('time type', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('TIME returns a DateTime with correct hour/minute/second', () async {
      final r = await conn.query("SELECT CAST('12:30:45' AS time) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.hour, equals(12));
      expect(d.minute, equals(30));
      expect(d.second, equals(45));
    });

    test('TIME midnight is returned correctly', () async {
      final r = await conn.query("SELECT CAST('00:00:00' AS time) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.hour, equals(0));
      expect(d.minute, equals(0));
      expect(d.second, equals(0));
    });

    test('NULL TIME is returned as null', () async {
      final r = await conn.query("SELECT CAST(NULL AS time) AS v");
      expect(r[0]['v'], isNull);
    });
  });

  // ── DateTimeOffset type ───────────────────────────────────────────────────

  group('datetimeoffset type', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('DATETIMEOFFSET returns UTC DateTime', () async {
      // SQL Server stores UTC on the wire; offset is display-only.
      final r = await conn.query(
          "SELECT CAST('2024-03-15 10:00:00 +00:00' AS datetimeoffset) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(3));
      expect(d.day, equals(15));
      expect(d.hour, equals(10));
    });

    test('DATETIMEOFFSET with positive offset is stored as UTC', () async {
      // +05:30 means local is 10:00, UTC is 04:30
      final r = await conn.query(
          "SELECT CAST('2024-01-01 10:00:00 +05:30' AS datetimeoffset) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(1));
      expect(d.day, equals(1));
      expect(d.hour, equals(4));
      expect(d.minute, equals(30));
    });

    test('NULL DATETIMEOFFSET is returned as null', () async {
      final r = await conn.query("SELECT CAST(NULL AS datetimeoffset) AS v");
      expect(r[0]['v'], isNull);
    });
  });

  // ── CHAR / BINARY fixed-width short types ─────────────────────────────────

  group('fixed-width short types', () {
    late MssqlConnection conn;
    setUpAll(() async => conn = await openConn());
    tearDownAll(() async => conn.close());

    test('CHAR(10) right-padded value is returned as String', () async {
      final r = await conn.query("SELECT CAST('hi' AS char(10)) AS v");
      final v = r[0]['v'] as String;
      expect(v.trimRight(), equals('hi'));
      expect(v.length, equals(10));
    });

    test('NCHAR(5) is returned as String', () async {
      final r = await conn.query("SELECT CAST(N'abc' AS nchar(5)) AS v");
      final v = r[0]['v'] as String;
      expect(v.trimRight(), equals('abc'));
    });

    test('BINARY(4) is returned as List<int>', () async {
      final r = await conn.query("SELECT CAST(0xDEAD AS binary(4)) AS v");
      final v = r[0]['v'];
      expect(v, isA<List<int>>());
    });
  });
}
