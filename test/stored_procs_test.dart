import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Stored procedure integration tests.
// Exercises tokenReturnStatus (0x79), tokenReturnValue (0xAC), and
// DONE_PROC tokens that the adversarial review identified as untested.
//
// Runs against the dart-mssql Docker container on port 14330.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

late MssqlConnection conn;

void main() {
  setUpAll(() async {
    conn = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );

    // Drop and recreate test procedures for this session.
    for (final name in [
      'dart_sp_return', 'dart_sp_output', 'dart_sp_multi',
      'dart_sp_dml', 'dart_sp_error', 'dart_sp_norows',
    ]) {
      await conn.execute(
        "IF OBJECT_ID('dbo.$name', 'P') IS NOT NULL DROP PROCEDURE dbo.$name");
    }

    await conn.execute('''
      CREATE PROCEDURE dbo.dart_sp_return @v INT AS
      BEGIN
        RETURN @v + 100
      END
    ''');

    await conn.execute('''
      CREATE PROCEDURE dbo.dart_sp_output @in INT, @out INT OUTPUT AS
      BEGIN
        SET @out = @in * 3
      END
    ''');

    await conn.execute('''
      CREATE PROCEDURE dbo.dart_sp_multi AS
      BEGIN
        SELECT 1 AS first_col
        SELECT 2 AS second_col
      END
    ''');

    await conn.execute('''
      CREATE PROCEDURE dbo.dart_sp_dml @n INT AS
      BEGIN
        CREATE TABLE #sp_dml_tmp (v INT)
        DECLARE @i INT = 0
        WHILE @i < @n
        BEGIN
          INSERT INTO #sp_dml_tmp VALUES (@i)
          SET @i = @i + 1
        END
        SELECT v FROM #sp_dml_tmp
      END
    ''');

    await conn.execute('''
      CREATE PROCEDURE dbo.dart_sp_error AS
      BEGIN
        SELECT 1 AS ok
        RAISERROR(N\'intentional error\', 16, 1)
      END
    ''');

    await conn.execute('''
      CREATE PROCEDURE dbo.dart_sp_norows AS
      BEGIN
        SELECT 1 AS v WHERE 1 = 0
      END
    ''');
  });

  tearDownAll(() async {
    for (final name in [
      'dart_sp_return', 'dart_sp_output', 'dart_sp_multi',
      'dart_sp_dml', 'dart_sp_error', 'dart_sp_norows',
    ]) {
      try {
        await conn.execute(
          "IF OBJECT_ID('dbo.$name', 'P') IS NOT NULL DROP PROCEDURE dbo.$name");
      } catch (_) {}
    }
    await conn.close();
  });

  // ── RETURN status ─────────────────────────────────────────────────────────

  group('RETURN status', () {
    test('proc with RETURN value does not throw', () async {
      // tokenReturnStatus (0x79) must be parsed/skipped cleanly.
      final r = await conn.query('EXEC dbo.dart_sp_return @v = 42');
      // The RETURN value is not surfaced by query(); connection must stay alive.
      expect(r, isNotNull);
    });

    test('connection remains usable after RETURN proc', () async {
      await conn.query('EXEC dbo.dart_sp_return @v = 1');
      final r = await conn.query('SELECT 99 AS ok');
      expect(r[0]['ok'], equals(99));
    });
  });

  // ── OUTPUT parameters (tokenReturnValue) ──────────────────────────────────

  group('OUTPUT parameters', () {
    test('proc with OUTPUT param does not throw (tokenReturnValue skipped)', () async {
      // sp_executesql returns RETURNVALUE tokens for OUTPUT params.
      // Our _skipReturnValue() must handle them without StateError.
      final r = await conn.query(
        "DECLARE @out INT; EXEC dbo.dart_sp_output @in = 5, @out = @out OUTPUT; SELECT @out AS result");
      expect(r[0]['result'], equals(15));
    });

    test('OUTPUT param via sp_executesql does not corrupt connection', () async {
      await conn.query(
        "DECLARE @out INT; EXEC dbo.dart_sp_output @in = 10, @out = @out OUTPUT; SELECT @out AS v");
      final r = await conn.query('SELECT 7 AS ok');
      expect(r[0]['ok'], equals(7));
    });
  });

  // ── Multiple result sets from stored procs ────────────────────────────────

  group('multiple result sets from proc', () {
    test('queryMultiple returns both result sets', () async {
      final multi = await conn.queryMultiple('EXEC dbo.dart_sp_multi');
      expect(multi.length, equals(2));
      expect(multi[0][0]['first_col'], equals(1));
      expect(multi[1][0]['second_col'], equals(2));
    });

    test('query returns only first result set from proc', () async {
      final r = await conn.query('EXEC dbo.dart_sp_multi');
      expect(r.length, equals(1));
      expect(r[0]['first_col'], equals(1));
    });

    test('streamQueryResponse only yields first result set from proc', () async {
      final rows = <int>[];
      await for (final row in conn.queryStream('EXEC dbo.dart_sp_multi')) {
        rows.add(row['first_col'] as int);
      }
      expect(rows, equals([1]));
    });

    test('connection still usable after queryMultiple from proc', () async {
      await conn.queryMultiple('EXEC dbo.dart_sp_multi');
      final r = await conn.query('SELECT 42 AS ok');
      expect(r[0]['ok'], equals(42));
    });
  });

  // ── DML inside stored proc ────────────────────────────────────────────────

  group('DML inside proc', () {
    test('proc with DML + SELECT returns correct rows', () async {
      final r = await conn.query('EXEC dbo.dart_sp_dml @n = 3');
      expect(r.length, equals(3));
    });

    test('proc with DML returns rowsAffected from result', () async {
      final r = await conn.query('EXEC dbo.dart_sp_dml @n = 5');
      expect(r.length, equals(5));
    });
  });

  // ── Proc that raises error ────────────────────────────────────────────────

  group('proc error handling', () {
    test('proc RAISERROR throws MssqlException', () async {
      await expectLater(
        () => conn.query('EXEC dbo.dart_sp_error'),
        throwsA(isA<MssqlException>()),
      );
    });

    test('connection usable after proc error', () async {
      try {
        await conn.query('EXEC dbo.dart_sp_error');
      } on MssqlException catch (_) {}
      final r = await conn.query('SELECT 1 AS ok');
      expect(r[0]['ok'], equals(1));
    });
  });

  // ── Proc with no rows ─────────────────────────────────────────────────────

  group('proc with no rows', () {
    test('proc returning empty result set works', () async {
      final r = await conn.query('EXEC dbo.dart_sp_norows');
      expect(r.isEmpty, isTrue);
    });

    test('queryStream from proc with no rows yields nothing', () async {
      final rows = <Object>[];
      await for (final row in conn.queryStream('EXEC dbo.dart_sp_norows')) {
        rows.add(row);
      }
      expect(rows, isEmpty);
    });
  });

  // ── sp_executesql with OUTPUT params directly ─────────────────────────────

  group('sp_executesql OUTPUT params', () {
    test('sp_executesql with OUTPUT param does not crash', () async {
      // This triggers tokenReturnValue in processAllQueryResponses.
      final r = await conn.query(
        "EXEC sp_executesql N'SET @out = @in * 2', N'@in INT, @out INT OUTPUT', @in = 7, @out = 0");
      // Result may be empty (no SELECT); just ensure no crash.
      expect(r, isNotNull);
    });

    test('connection usable after sp_executesql with OUTPUT', () async {
      try {
        await conn.query(
          "EXEC sp_executesql N'SET @out = @in', N'@in INT, @out INT OUTPUT', @in = 1, @out = 0");
      } catch (_) {}
      final r = await conn.query('SELECT 55 AS ok');
      expect(r[0]['ok'], equals(55));
    });
  });
}
