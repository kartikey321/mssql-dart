import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Runs against the dart-mssql Docker container on port 14330.
// Start with:
//   docker run -d --name dart-mssql --cap-add SYS_PTRACE \
//     -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD='Knex_Test1!' \
//     -p 127.0.0.1:14330:1433 mcr.microsoft.com/azure-sql-edge:latest

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

  // ── Integers ────────────────────────────────────────────────────────────────

  group('integers', () {
    test('TINYINT', () async {
      final r = await conn.query('SELECT CAST(255 AS tinyint) AS v');
      expect(r[0]['v'], equals(255));
    });

    test('SMALLINT', () async {
      final r = await conn.query('SELECT CAST(-32768 AS smallint) AS v');
      expect(r[0]['v'], equals(-32768));
    });

    test('INT', () async {
      final r = await conn.query('SELECT CAST(-2147483648 AS int) AS v');
      expect(r[0]['v'], equals(-2147483648));
    });

    test('BIGINT positive', () async {
      final r = await conn.query('SELECT CAST(9223372036854775807 AS bigint) AS v');
      expect(r[0]['v'], equals(9223372036854775807));
    });

    test('BIGINT negative', () async {
      final r = await conn.query('SELECT CAST(-1 AS bigint) AS v');
      expect(r[0]['v'], equals(-1));
    });

    test('BIT true', () async {
      final r = await conn.query('SELECT CAST(1 AS bit) AS v');
      expect(r[0]['v'], isTrue);
    });

    test('BIT false', () async {
      final r = await conn.query('SELECT CAST(0 AS bit) AS v');
      expect(r[0]['v'], isFalse);
    });
  });

  // ── Floating point ──────────────────────────────────────────────────────────

  group('floats', () {
    test('REAL', () async {
      final r = await conn.query('SELECT CAST(3.14 AS real) AS v');
      expect((r[0]['v'] as double), closeTo(3.14, 0.001));
    });

    test('FLOAT', () async {
      final r = await conn.query('SELECT CAST(3.141592653589793 AS float) AS v');
      expect((r[0]['v'] as double), closeTo(3.141592653589793, 1e-12));
    });
  });

  // ── Decimal / Numeric ───────────────────────────────────────────────────────

  group('decimal', () {
    test('DECIMAL(9,2) positive', () async {
      final r = await conn.query("SELECT CAST('1234567.89' AS decimal(9,2)) AS v");
      expect((r[0]['v'] as double), closeTo(1234567.89, 0.001));
    });

    test('DECIMAL(9,2) negative', () async {
      final r = await conn.query("SELECT CAST('-1234567.89' AS decimal(9,2)) AS v");
      expect((r[0]['v'] as double), closeTo(-1234567.89, 0.001));
    });

    test('DECIMAL(18,4) large', () async {
      final r = await conn.query("SELECT CAST('99999999999999.9999' AS decimal(18,4)) AS v");
      expect((r[0]['v'] as double), closeTo(99999999999999.9999, 0.01));
    });

    test('DECIMAL(38,10) very large', () async {
      final r = await conn.query("SELECT CAST('1234567890.1234567890' AS decimal(38,10)) AS v");
      expect((r[0]['v'] as double), closeTo(1234567890.123456789, 0.001));
    });

    test('NUMERIC(5,2)', () async {
      final r = await conn.query("SELECT CAST('999.99' AS numeric(5,2)) AS v");
      expect((r[0]['v'] as double), closeTo(999.99, 0.001));
    });
  });

  // ── Strings ─────────────────────────────────────────────────────────────────

  group('strings', () {
    test('NVARCHAR', () async {
      final r = await conn.query("SELECT N'hello world' AS v");
      expect(r[0]['v'], equals('hello world'));
    });

    test('NVARCHAR unicode', () async {
      final r = await conn.query("SELECT N'日本語テスト' AS v");
      expect(r[0]['v'], equals('日本語テスト'));
    });

    test('NVARCHAR(MAX) short', () async {
      final r = await conn.query("SELECT CAST(N'hello max' AS nvarchar(max)) AS v");
      expect(r[0]['v'], equals('hello max'));
    });

    test('NVARCHAR(MAX) long', () async {
      // Input to REPLICATE must be nvarchar(max) to avoid 4000-char truncation.
      final r = await conn.query("SELECT REPLICATE(CAST(N'a' AS nvarchar(max)), 5000) AS v");
      expect(r[0]['v'], equals('a' * 5000));
    });

    test('NCHAR', () async {
      final r = await conn.query("SELECT CAST(N'hi' AS nchar(5)) AS v");
      expect((r[0]['v'] as String).trim(), equals('hi'));
    });

    test('VARCHAR', () async {
      final r = await conn.query("SELECT CAST('ascii text' AS varchar(50)) AS v");
      expect(r[0]['v'], equals('ascii text'));
    });

    test('VARCHAR(MAX)', () async {
      final r = await conn.query("SELECT CAST('big string' AS varchar(max)) AS v");
      expect(r[0]['v'], equals('big string'));
    });

    test('CHAR', () async {
      final r = await conn.query("SELECT CAST('abc' AS char(5)) AS v");
      expect((r[0]['v'] as String).trim(), equals('abc'));
    });

    test('empty NVARCHAR', () async {
      final r = await conn.query("SELECT N'' AS v");
      expect(r[0]['v'], equals(''));
    });
  });

  // ── Binary ──────────────────────────────────────────────────────────────────

  group('binary', () {
    test('VARBINARY', () async {
      final r = await conn.query("SELECT CAST(0x0102030405 AS varbinary(10)) AS v");
      expect(r[0]['v'], equals([1, 2, 3, 4, 5]));
    });

    test('VARBINARY(MAX)', () async {
      final r = await conn.query("SELECT CAST(0xDEADBEEF AS varbinary(max)) AS v");
      expect(r[0]['v'], equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('BINARY', () async {
      // SQL right-pads binary literals: 0xFF as binary(3) → [0xFF, 0x00, 0x00]
      final r = await conn.query("SELECT CAST(0xFF AS binary(3)) AS v");
      expect(r[0]['v'], equals([0xFF, 0x00, 0x00]));
    });

    test('VARBINARY(MAX) large (>4KB PLP)', () async {
      // 5000 bytes = 'A' (0x41) — forces PLP to span multiple TDS packets
      final r = await conn.query(
          "SELECT CONVERT(varbinary(max), REPLICATE(CAST('A' AS varchar(max)), 5000)) AS v");
      final bytes = r[0]['v'] as List<int>;
      expect(bytes.length, equals(5000));
      expect(bytes.every((b) => b == 0x41), isTrue);
    });

    test('empty VARBINARY', () async {
      final r = await conn.query("SELECT CAST(0x AS varbinary(10)) AS v");
      expect(r[0]['v'], equals(<int>[]));
    });
  });

  // ── GUID ────────────────────────────────────────────────────────────────────

  group('guid', () {
    test('UNIQUEIDENTIFIER round-trip', () async {
      final r = await conn.query(
        "SELECT CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS v");
      expect((r[0]['v'] as String).toLowerCase(),
          equals('6f9619ff-8b86-d011-b42d-00c04fc964ff'));
    });
  });

  // ── Money ───────────────────────────────────────────────────────────────────

  group('money', () {
    test('MONEY positive', () async {
      final r = await conn.query("SELECT CAST(1234567.89 AS money) AS v");
      expect((r[0]['v'] as double), closeTo(1234567.89, 0.01));
    });

    test('MONEY negative', () async {
      final r = await conn.query("SELECT CAST(-1.0000 AS money) AS v");
      expect((r[0]['v'] as double), closeTo(-1.0, 0.0001));
    });

    test('SMALLMONEY positive', () async {
      final r = await conn.query("SELECT CAST(9999.99 AS smallmoney) AS v");
      expect((r[0]['v'] as double), closeTo(9999.99, 0.001));
    });

    test('SMALLMONEY negative', () async {
      final r = await conn.query("SELECT CAST(-214748.3647 AS smallmoney) AS v");
      expect((r[0]['v'] as double), closeTo(-214748.3647, 0.001));
    });

    test('NULL money', () async {
      final r = await conn.query('SELECT CAST(NULL AS money) AS v');
      expect(r[0]['v'], isNull);
    });
  });

  // ── Date / Time ─────────────────────────────────────────────────────────────

  group('date and time', () {
    test('DATE', () async {
      final r = await conn.query("SELECT CAST('2024-03-15' AS date) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(3));
      expect(d.day, equals(15));
    });

    test('DATETIME', () async {
      final r = await conn.query("SELECT CAST('2024-06-01 12:30:00' AS datetime) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(6));
      expect(d.day, equals(1));
      expect(d.hour, equals(12));
      expect(d.minute, equals(30));
    });

    test('DATETIME2', () async {
      final r = await conn.query("SELECT CAST('2024-06-01 12:30:45.123' AS datetime2(3)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(6));
      expect(d.day, equals(1));
      expect(d.hour, equals(12));
      expect(d.minute, equals(30));
      expect(d.second, equals(45));
      expect(d.millisecond, equals(123));
    });

    test('DATETIME2(7) max scale', () async {
      final r = await conn.query("SELECT CAST('2024-06-01 00:00:01.0000000' AS datetime2(7)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.second, equals(1));
    });

    test('DATETIME2(7) microsecond precision', () async {
      // 123456 microseconds = 123ms + 456µs; scale 7 preserves to 100ns (1µs truncated)
      final r = await conn.query(
          "SELECT CAST('2024-06-01 12:00:00.1234560' AS datetime2(7)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.hour, equals(12));
      expect(d.millisecond, equals(123));
      expect(d.microsecond, equals(456));
    });

    test('SMALLDATETIME', () async {
      final r = await conn.query("SELECT CAST('2024-01-15 10:20:00' AS smalldatetime) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(1));
      expect(d.day, equals(15));
    });

    test('TIME(3)', () async {
      final r = await conn.query("SELECT CAST('14:30:45.123' AS time(3)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.hour, equals(14));
      expect(d.minute, equals(30));
      expect(d.second, equals(45));
      expect(d.millisecond, equals(123));
    });

    test('TIME(0) seconds only', () async {
      final r = await conn.query("SELECT CAST('09:05:30' AS time(0)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.hour, equals(9));
      expect(d.minute, equals(5));
      expect(d.second, equals(30));
    });

    test('DATETIMEOFFSET positive offset', () async {
      // +05:30 = UTC 07:00 when local is 12:30
      final r = await conn.query(
          "SELECT CAST('2024-06-01 12:30:00 +05:30' AS datetimeoffset(0)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.isUtc, isTrue);
      expect(d.year, equals(2024));
      expect(d.month, equals(6));
      expect(d.day, equals(1));
      expect(d.hour, equals(7));
      expect(d.minute, equals(0));
    });

    test('DATETIMEOFFSET UTC', () async {
      final r = await conn.query(
          "SELECT CAST('2024-01-01 00:00:00 +00:00' AS datetimeoffset(0)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.isUtc, isTrue);
      expect(d.year, equals(2024));
      expect(d.hour, equals(0));
    });

    test('DATETIMEOFFSET negative offset', () async {
      // -05:00 = UTC 17:30 when local is 12:30
      final r = await conn.query(
          "SELECT CAST('2024-06-01 12:30:00 -05:00' AS datetimeoffset(0)) AS v");
      final d = r[0]['v'] as DateTime;
      expect(d.isUtc, isTrue);
      expect(d.hour, equals(17));
      expect(d.minute, equals(30));
    });

    test('NULL time', () async {
      final r = await conn.query('SELECT CAST(NULL AS time) AS v');
      expect(r[0]['v'], isNull);
    });

    test('NULL datetimeoffset', () async {
      final r = await conn.query('SELECT CAST(NULL AS datetimeoffset) AS v');
      expect(r[0]['v'], isNull);
    });
  });

  // ── XML ──────────────────────────────────────────────────────────────────────

  group('xml', () {
    test('XML value', () async {
      final r = await conn.query(
          "SELECT CAST('<root><item>hello</item></root>' AS xml) AS v");
      expect(r[0]['v'], equals('<root><item>hello</item></root>'));
    });

    test('NULL xml', () async {
      final r = await conn.query('SELECT CAST(NULL AS xml) AS v');
      expect(r[0]['v'], isNull);
    });
  });

  // ── NULL handling ───────────────────────────────────────────────────────────

  group('nulls', () {
    test('NULL int', () async {
      final r = await conn.query('SELECT CAST(NULL AS int) AS v');
      expect(r[0]['v'], isNull);
    });

    test('NULL nvarchar', () async {
      final r = await conn.query('SELECT CAST(NULL AS nvarchar(50)) AS v');
      expect(r[0]['v'], isNull);
    });

    test('NULL nvarchar(max)', () async {
      final r = await conn.query('SELECT CAST(NULL AS nvarchar(max)) AS v');
      expect(r[0]['v'], isNull);
    });

    test('NULL decimal', () async {
      final r = await conn.query('SELECT CAST(NULL AS decimal(18,4)) AS v');
      expect(r[0]['v'], isNull);
    });

    test('NULL date', () async {
      final r = await conn.query('SELECT CAST(NULL AS date) AS v');
      expect(r[0]['v'], isNull);
    });

    test('NULL uniqueidentifier', () async {
      final r = await conn.query('SELECT CAST(NULL AS uniqueidentifier) AS v');
      expect(r[0]['v'], isNull);
    });

    test('mixed NULLs in same row (NBCROW)', () async {
      final r = await conn.query('SELECT NULL AS a, 1 AS b, NULL AS c, 2 AS d');
      expect(r[0]['a'], isNull);
      expect(r[0]['b'], equals(1));
      expect(r[0]['c'], isNull);
      expect(r[0]['d'], equals(2));
    });

    test('9-column NBCROW (bitmap byte boundary)', () async {
      // Columns 0-7 = bitmap byte 0; column 8 = bitmap byte 1. Null/non-null
      // pattern spans the byte boundary to exercise the full bitmap logic.
      final r = await conn.query(
          'SELECT NULL AS a, 1 AS b, NULL AS c, 2 AS d, '
          'NULL AS e, 3 AS f, NULL AS g, 4 AS h, NULL AS i');
      expect(r[0]['a'], isNull);
      expect(r[0]['b'], equals(1));
      expect(r[0]['c'], isNull);
      expect(r[0]['d'], equals(2));
      expect(r[0]['e'], isNull);
      expect(r[0]['f'], equals(3));
      expect(r[0]['g'], isNull);
      expect(r[0]['h'], equals(4));
      expect(r[0]['i'], isNull);
    });
  });

  // ── Parameterised queries ───────────────────────────────────────────────────

  group('parameters', () {
    test('int param', () async {
      final r = await conn.query('SELECT @v * 3 AS v', {'v': 7});
      expect(r[0]['v'], equals(21));
    });

    test('string param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': 'hello'});
      expect(r[0]['v'], equals('hello'));
    });

    test('null param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': null});
      expect(r[0]['v'], isNull);
    });

    test('bool param true', () async {
      final r = await conn.query('SELECT @v AS v', {'v': true});
      expect(r[0]['v'], isTrue);
    });

    test('float param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': 3.14});
      expect((r[0]['v'] as double), closeTo(3.14, 0.001));
    });

    test('DateTime param', () async {
      final dt = DateTime.utc(2024, 6, 15, 10, 30, 45);
      final r = await conn.query('SELECT YEAR(@v) AS yr, MONTH(@v) AS mo', {'v': dt});
      expect(r[0]['yr'], equals(2024));
      expect(r[0]['mo'], equals(6));
    });

    test('binary param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': [0xDE, 0xAD, 0xBE, 0xEF]});
      expect(r[0]['v'], equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('negative int param', () async {
      final r = await conn.query('SELECT @v AS v', {'v': -9223372036854775808});
      expect(r[0]['v'], equals(-9223372036854775808));
    });
  });

  // ── Multiple rows ───────────────────────────────────────────────────────────

  group('result sets', () {
    test('multiple rows', () async {
      final r = await conn.query(
        'SELECT v FROM (VALUES (1),(2),(3)) t(v) ORDER BY v');
      expect(r.length, equals(3));
      expect(r[0]['v'], equals(1));
      expect(r[1]['v'], equals(2));
      expect(r[2]['v'], equals(3));
    });

    test('multiple columns', () async {
      final r = await conn.query('SELECT 1 AS a, 2 AS b, 3 AS c');
      expect(r[0]['a'], equals(1));
      expect(r[0]['b'], equals(2));
      expect(r[0]['c'], equals(3));
    });

    test('zero rows', () async {
      final r = await conn.query('SELECT 1 AS v WHERE 1=0');
      expect(r.length, equals(0));
    });
  });
}
