import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Tests for legacy and less-common SQL Server types.
// Exercises the _readLongLen branches in type_info.dart:
//   typeText, typeNText, typeImage, typeVariant
// Also covers edge cases for decimal, integer, and date boundaries.
//
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
      encrypt: false,
      trustServerCertificate: true,
    );
  });

  tearDownAll(() async => conn.close());

  // ── Legacy string types: TEXT / NTEXT ─────────────────────────────────────
  //
  // Text/NText/Image must be tested using real table columns (not computed
  // CAST expressions) because only table-backed columns include the TableName
  // field in COLMETADATA and the text-pointer format in ROW data.

  group('TEXT and NTEXT (legacy)', () {
    setUpAll(() async {
      await conn.execute('CREATE TABLE #text_t (v TEXT, n NTEXT)');
      await conn.execute("INSERT INTO #text_t VALUES ('hello legacy text', N'unicode 日本語')");
      await conn.execute("INSERT INTO #text_t VALUES (NULL, NULL)");
    });

    test('TEXT value from table column is returned as String', () async {
      final r = await conn.query('SELECT v FROM #text_t WHERE v IS NOT NULL');
      expect(r[0]['v'], equals('hello legacy text'));
    });

    test('NTEXT value from table column is returned as String', () async {
      final r = await conn.query('SELECT n FROM #text_t WHERE n IS NOT NULL');
      expect(r[0]['n'], equals('unicode 日本語'));
    });

    test('NULL TEXT from table column is returned as null', () async {
      final r = await conn.query('SELECT v FROM #text_t WHERE v IS NULL');
      expect(r[0]['v'], isNull);
    });

    test('NULL NTEXT from table column is returned as null', () async {
      final r = await conn.query('SELECT n FROM #text_t WHERE n IS NULL');
      expect(r[0]['n'], isNull);
    });

    test('TEXT column can hold long content', () async {
      await conn.execute("CREATE TABLE #text_long (v TEXT)");
      await conn.execute("INSERT INTO #text_long VALUES (REPLICATE('x', 1000))");
      final r = await conn.query('SELECT v FROM #text_long');
      expect((r[0]['v'] as String).length, equals(1000));
    });
  });

  // ── Legacy binary type: IMAGE ─────────────────────────────────────────────

  group('IMAGE (legacy binary)', () {
    setUpAll(() async {
      await conn.execute('CREATE TABLE #img_t (v IMAGE)');
      await conn.execute('INSERT INTO #img_t VALUES (0xDEADBEEF)');
      await conn.execute('INSERT INTO #img_t VALUES (NULL)');
      await conn.execute('INSERT INTO #img_t VALUES (0xFF)');
    });

    test('IMAGE value from table column is returned as List<int>', () async {
      // DATALENGTH works on IMAGE; LEN does not.
      final r = await conn.query('SELECT v FROM #img_t WHERE DATALENGTH(v) = 4');
      expect(r[0]['v'], equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('NULL IMAGE from table column is returned as null', () async {
      final r = await conn.query('SELECT v FROM #img_t WHERE v IS NULL');
      expect(r[0]['v'], isNull);
    });

    test('IMAGE with single byte', () async {
      final r = await conn.query('SELECT v FROM #img_t WHERE DATALENGTH(v) = 1');
      expect(r[0]['v'], equals([0xFF]));
    });
  });

  // ── sql_variant ───────────────────────────────────────────────────────────

  group('sql_variant', () {
    test('sql_variant with INT value is consumed without crash', () async {
      // sql_variant bytes are consumed but returned as raw List<int> (opaque).
      final r = await conn.query('SELECT CAST(42 AS sql_variant) AS v');
      // Must not throw; value may be List<int> (raw bytes) or a decoded type.
      expect(r[0]['v'], isNotNull);
    });

    test('sql_variant with VARCHAR value is consumed without crash', () async {
      final r = await conn.query("SELECT CAST('hello' AS sql_variant) AS v");
      expect(r[0]['v'], isNotNull);
    });

    test('NULL sql_variant is returned as null', () async {
      final r = await conn.query('SELECT CAST(NULL AS sql_variant) AS v');
      expect(r[0]['v'], isNull);
    });

    test('connection usable after sql_variant query', () async {
      await conn.query('SELECT CAST(1 AS sql_variant) AS v');
      final r = await conn.query('SELECT 99 AS ok');
      expect(r[0]['ok'], equals(99));
    });
  });

  // ── Date boundary values ──────────────────────────────────────────────────

  group('date boundary values', () {
    test('DATE year 0001 (SQL Server minimum)', () async {
      final r = await conn.query("SELECT CAST('0001-01-01' AS date) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(1));
      expect(d.month, equals(1));
      expect(d.day, equals(1));
    });

    test('DATE year 9999 (SQL Server maximum)', () async {
      final r = await conn.query("SELECT CAST('9999-12-31' AS date) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(9999));
      expect(d.month, equals(12));
      expect(d.day, equals(31));
    });

    test('DATETIME2 year 0001 minimum', () async {
      final r = await conn.query(
          "SELECT CAST('0001-01-01 00:00:00.0000000' AS datetime2(7)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(1));
      expect(d.month, equals(1));
      expect(d.day, equals(1));
    });

    test('DATETIME2 year 9999 maximum', () async {
      final r = await conn.query(
          "SELECT CAST('9999-12-31 23:59:59.9999999' AS datetime2(7)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(9999));
      expect(d.month, equals(12));
      expect(d.day, equals(31));
    });

    test('DATETIME minimum (1753-01-01)', () async {
      final r = await conn.query(
          "SELECT CAST('1753-01-01 00:00:00' AS datetime) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(1753));
      expect(d.month, equals(1));
      expect(d.day, equals(1));
    });
  });

  // ── DateTime parameter round-trips ────────────────────────────────────────

  group('DateTime parameter round-trip', () {
    test('UTC DateTime param preserves date and time', () async {
      final dt = DateTime.utc(2024, 6, 15, 10, 30, 45);
      final r = await conn.query(
        'SELECT YEAR(@v) AS yr, MONTH(@v) AS mo, DAY(@v) AS dy, '
        'DATEPART(hour, @v) AS hr, DATEPART(minute, @v) AS mn, '
        'DATEPART(second, @v) AS sc',
        {'v': dt},
      );
      expect(r[0]['yr'], equals(2024));
      expect(r[0]['mo'], equals(6));
      expect(r[0]['dy'], equals(15));
      expect(r[0]['hr'], equals(10));
      expect(r[0]['mn'], equals(30));
      expect(r[0]['sc'], equals(45));
    });

    test('local DateTime param preserves date component', () async {
      final dt = DateTime(2023, 11, 20, 8, 15, 0);
      final r = await conn.query(
        'SELECT YEAR(@v) AS yr, MONTH(@v) AS mo, DAY(@v) AS dy',
        {'v': dt},
      );
      expect(r[0]['yr'], equals(2023));
      expect(r[0]['mo'], equals(11));
      expect(r[0]['dy'], equals(20));
    });

    test('year-1 local DateTime param', () async {
      final dt = DateTime.utc(1, 1, 2, 0, 0, 0);
      final r = await conn.query(
        'SELECT YEAR(@v) AS yr, MONTH(@v) AS mo, DAY(@v) AS dy',
        {'v': dt},
      );
      expect(r[0]['yr'], equals(1));
    });
  });

  // ── Integer boundary values ───────────────────────────────────────────────

  group('integer boundaries', () {
    test('TINYINT max (255)', () async {
      final r = await conn.query('SELECT CAST(255 AS tinyint) AS v');
      expect(r[0]['v'], equals(255));
    });

    test('TINYINT min (0)', () async {
      final r = await conn.query('SELECT CAST(0 AS tinyint) AS v');
      expect(r[0]['v'], equals(0));
    });

    test('SMALLINT max (32767)', () async {
      final r = await conn.query('SELECT CAST(32767 AS smallint) AS v');
      expect(r[0]['v'], equals(32767));
    });

    test('INT max (2147483647)', () async {
      final r = await conn.query('SELECT CAST(2147483647 AS int) AS v');
      expect(r[0]['v'], equals(2147483647));
    });

    test('BIGINT min (-9223372036854775808)', () async {
      final r = await conn.query(
          'SELECT CAST(-9223372036854775808 AS bigint) AS v');
      expect(r[0]['v'], equals(-9223372036854775808));
    });

    test('BIGINT max (9223372036854775807)', () async {
      final r = await conn.query(
          'SELECT CAST(9223372036854775807 AS bigint) AS v');
      expect(r[0]['v'], equals(9223372036854775807));
    });
  });

  // ── Decimal edge cases ────────────────────────────────────────────────────

  group('decimal edge cases', () {
    test('DECIMAL(1,0) — smallest', () async {
      final r = await conn.query('SELECT CAST(0 AS decimal(1,0)) AS v');
      expect((r[0]['v'] as double), closeTo(0.0, 0.0001));
    });

    test('DECIMAL scale-only zero', () async {
      final r = await conn.query("SELECT CAST('0.00' AS decimal(9,2)) AS v");
      expect((r[0]['v'] as double), closeTo(0.0, 0.0001));
    });

    test('DECIMAL negative zero-point-five', () async {
      final r = await conn.query("SELECT CAST('-0.5' AS decimal(3,1)) AS v");
      expect((r[0]['v'] as double), closeTo(-0.5, 0.001));
    });
  });

  // ── FLOAT edge cases ──────────────────────────────────────────────────────

  group('float edge cases', () {
    test('FLOAT zero', () async {
      final r = await conn.query('SELECT CAST(0.0 AS float) AS v');
      expect((r[0]['v'] as double), closeTo(0.0, 0.0));
    });

    test('FLOAT negative', () async {
      final r = await conn.query('SELECT CAST(-2.718 AS float) AS v');
      expect((r[0]['v'] as double), closeTo(-2.718, 0.001));
    });

    test('REAL infinity approximation (max REAL)', () async {
      final r = await conn.query('SELECT CAST(3.4e38 AS real) AS v');
      expect(r[0]['v'], isA<double>());
    });
  });

  // ── Multi-statement DML rowcount accumulation ─────────────────────────────

  group('multi-statement DML rowcount', () {
    test('two INSERTs in one batch accumulate rowsAffected', () async {
      await conn.execute('CREATE TABLE #multi_dml (v INT)');
      // Both inserts in one batch — should total 5 affected rows.
      final n = await conn.execute(
        'INSERT INTO #multi_dml VALUES (1),(2),(3); '
        'INSERT INTO #multi_dml VALUES (4),(5)');
      expect(n, equals(5));
    });

    test('UPDATE + DELETE in one batch accumulates rowsAffected', () async {
      await conn.execute('CREATE TABLE #multi_ud (v INT)');
      await conn.execute('INSERT INTO #multi_ud VALUES (1),(2),(3),(4)');
      final n = await conn.execute(
        'UPDATE #multi_ud SET v = v + 10 WHERE v <= 2; '
        'DELETE FROM #multi_ud WHERE v > 10');
      // 2 updated (1→11, 2→12) + 2 deleted (11, 12 > 10) = 4
      expect(n, equals(4));
    });
  });

  // ── Large parameters ──────────────────────────────────────────────────────

  group('large parameters', () {
    test('binary param >8000 bytes (PLP path)', () async {
      final big = List<int>.generate(9000, (i) => i & 0xFF);
      final r = await conn.query('SELECT LEN(@v) AS n', {'v': big});
      expect(r[0]['n'], equals(9000));
    });

    test('string param exactly 4000 chars (boundary)', () async {
      final s = 'A' * 4000;
      final r = await conn.query('SELECT LEN(@v) AS n', {'v': s});
      expect(r[0]['n'], equals(4000));
    });

    test('string param 4001 chars (triggers nvarchar(max))', () async {
      final s = 'B' * 4001;
      final r = await conn.query('SELECT LEN(@v) AS n', {'v': s});
      expect(r[0]['n'], equals(4001));
    });

    test('null binary param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': null});
      expect(r[0]['v'], isNull);
    });
  });

  // ── XML column edge cases ─────────────────────────────────────────────────

  group('xml edge cases', () {
    test('large XML value', () async {
      // Forces PLP encoding for XML
      final r = await conn.query(
          "SELECT CAST(REPLICATE(CAST('<x/>' AS nvarchar(max)), 100) AS xml) AS v");
      expect((r[0]['v'] as String).length, greaterThan(100));
    });

    test('XML with attributes', () async {
      final r = await conn.query(
          "SELECT CAST('<root id=\"1\">hello</root>' AS xml) AS v");
      expect(r[0]['v'], equals('<root id="1">hello</root>'));
    });
  });
}
