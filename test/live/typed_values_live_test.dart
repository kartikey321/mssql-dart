import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live round-trips for typed SQL binders (GUID / money / DTO / decimal /
/// varchar / date / time / datetime / xml / varbinary / nvarchar / binary).
///
/// Skips when 127.0.0.1:14330 is unreachable.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<MssqlConnection?> tryOpen() async {
  try {
    return await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 5),
    );
  } catch (_) {
    return null;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  late MssqlConnection conn;
  var available = false;

  setUpAll(() async {
    final c = await tryOpen();
    if (c == null) return;
    conn = c;
    available = true;
  });

  tearDownAll(() async {
    if (available) await conn.close();
  });

  test('MssqlGuid round-trip via uniqueidentifier param', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    const g = '6F9619FF-8B86-D011-B42D-00C04FC964FF';
    final r = await conn.query(
      'SELECT @g AS v',
      {'g': const MssqlGuid(g)},
    );
    expect((r[0]['v'] as String).toUpperCase(), equals(g));
  });

  test('MssqlMoney / MssqlSmallMoney round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @m AS m, @s AS s',
      {
        'm': MssqlMoney(1234.56),
        's': MssqlSmallMoney(-99.99),
      },
    );
    expect((r[0]['m'] as MssqlMoney).toDouble(), closeTo(1234.56, 0.001));
    expect((r[0]['s'] as MssqlSmallMoney).toDouble(), closeTo(-99.99, 0.001));
  });

  test('MssqlDateTimeOffset UTC round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final dt = DateTime.utc(2024, 3, 15, 10, 30, 0);
    final r = await conn.query(
      'SELECT @d AS v',
      {'d': MssqlDateTimeOffset(dt)},
    );
    final out = r[0]['v'] as DateTime;
    expect(out.year, equals(2024));
    expect(out.month, equals(3));
    expect(out.day, equals(15));
    expect(out.hour, equals(10));
    expect(out.minute, equals(30));
  });

  test('MssqlDateTimeOffset encodes offset minutes', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    // Instant UTC 04:30 with display offset +05:30 (330 minutes).
    final r = await conn.query(
      'SELECT DATEPART(tzoffset, @d) AS mins, @d AS v',
      {
        'd': MssqlDateTimeOffset(
          DateTime.utc(2024, 1, 1, 4, 30),
          offset: const Duration(hours: 5, minutes: 30),
        ),
      },
    );
    expect(r[0]['mins'], equals(330));
    final v = r[0]['v'] as DateTime;
    expect(v.hour, equals(4));
    expect(v.minute, equals(30));
  });

  test('MssqlDecimal round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @d AS d, @n AS n',
      {
        'd': MssqlDecimal(1234.56, precision: 10, scale: 2),
        'n': MssqlDecimal.parse(
          '-99.9900',
          precision: 10,
          scale: 4,
          asNumeric: true,
        ),
      },
    );
    expect((r[0]['d'] as MssqlDecimal).toDouble(), closeTo(1234.56, 0.001));
    expect((r[0]['n'] as MssqlDecimal).toDouble(), closeTo(-99.99, 0.0001));
  });

  test('MssqlVarchar / MssqlDate / MssqlTime round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @v AS v, @d AS d, @t AS t, '
      "SQL_VARIANT_PROPERTY(CAST(@v AS sql_variant), 'BaseType') AS vb, "
      "SQL_VARIANT_PROPERTY(CAST(@d AS sql_variant), 'BaseType') AS db, "
      "SQL_VARIANT_PROPERTY(CAST(@t AS sql_variant), 'BaseType') AS tb",
      {
        'v': const MssqlVarchar('lan-ascii'),
        'd': MssqlDate(2024, 7, 24),
        't': MssqlTime(hour: 14, minute: 30, second: 45, microsecond: 123000),
      },
    );
    expect(r[0]['v'], equals('lan-ascii'));
    expect((r[0]['vb'] as String).toLowerCase(), equals('varchar'));
    expect((r[0]['db'] as String).toLowerCase(), equals('date'));
    expect((r[0]['tb'] as String).toLowerCase(), equals('time'));

    final d = r[0]['d'] as DateTime;
    expect(d.year, equals(2024));
    expect(d.month, equals(7));
    expect(d.day, equals(24));

    final t = r[0]['t'] as DateTime;
    expect(t.hour, equals(14));
    expect(t.minute, equals(30));
    expect(t.second, equals(45));
  });

  test('MssqlVarchar into varchar column avoids nvarchar mismatch', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    await conn.execute(
      'IF OBJECT_ID(\'tempdb..#vt\') IS NOT NULL DROP TABLE #vt;'
      'CREATE TABLE #vt (name varchar(32) NOT NULL);',
    );
    await conn.execute(
      'INSERT INTO #vt (name) VALUES (@n)',
      {'n': const MssqlVarchar('bob')},
    );
    final r = await conn.query('SELECT name FROM #vt');
    expect(r[0]['name'], equals('bob'));
  });

  test('MssqlDateTime / MssqlSmallDateTime round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @dt AS dt, @sd AS sd, '
      "SQL_VARIANT_PROPERTY(CAST(@dt AS sql_variant), 'BaseType') AS dtb, "
      "SQL_VARIANT_PROPERTY(CAST(@sd AS sql_variant), 'BaseType') AS sdb",
      {
        'dt': MssqlDateTime(DateTime.utc(2024, 3, 15, 10, 30, 0)),
        'sd': MssqlSmallDateTime(DateTime.utc(2024, 3, 15, 10, 30, 45)),
      },
    );
    expect((r[0]['dtb'] as String).toLowerCase(), equals('datetime'));
    expect((r[0]['sdb'] as String).toLowerCase(), equals('smalldatetime'));
    final dt = r[0]['dt'] as DateTime;
    expect(dt.year, equals(2024));
    expect(dt.month, equals(3));
    expect(dt.day, equals(15));
    expect(dt.hour, equals(10));
    expect(dt.minute, equals(30));

    // 45s rounds to next minute for smalldatetime
    final sd = r[0]['sd'] as DateTime;
    expect(sd.hour, equals(10));
    expect(sd.minute, equals(31));
    expect(sd.second, equals(0));
  });

  test('MssqlXml / MssqlVarbinary round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @x AS x, @b AS b, '
      "SQL_VARIANT_PROPERTY(CAST(@b AS sql_variant), 'BaseType') AS bb, "
      "SQL_VARIANT_PROPERTY(CAST(@b AS sql_variant), 'MaxLength') AS bl",
      {
        'x': const MssqlXml('<root id="1">lan</root>'),
        'b': MssqlVarbinary([0xDE, 0xAD, 0xBE, 0xEF], length: 16),
      },
    );
    expect(r[0]['x'], equals('<root id="1">lan</root>'));
    expect(r[0]['b'], equals([0xDE, 0xAD, 0xBE, 0xEF]));
    expect((r[0]['bb'] as String).toLowerCase(), equals('varbinary'));
    expect(r[0]['bl'], equals(16));
  });

  test('MssqlXml into xml column', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    await conn.execute(
      'IF OBJECT_ID(\'tempdb..#xt\') IS NOT NULL DROP TABLE #xt;'
      'CREATE TABLE #xt (doc xml NOT NULL);',
    );
    await conn.execute(
      'INSERT INTO #xt (doc) VALUES (@x)',
      {'x': const MssqlXml('<a><b>1</b></a>')},
    );
    final r =
        await conn.query('SELECT CAST(doc AS nvarchar(max)) AS s FROM #xt');
    expect(r[0]['s'], contains('<a>'));
    expect(r[0]['s'], contains('<b>1</b>'));
  });

  test('MssqlVarbinary into varbinary(n) column', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    await conn.execute(
      'IF OBJECT_ID(\'tempdb..#bt\') IS NOT NULL DROP TABLE #bt;'
      'CREATE TABLE #bt (blob varbinary(8) NOT NULL);',
    );
    await conn.execute(
      'INSERT INTO #bt (blob) VALUES (@b)',
      {
        'b': MssqlVarbinary([1, 2, 3, 4], length: 8),
      },
    );
    final r = await conn.query('SELECT blob FROM #bt');
    expect(r[0]['blob'], equals([1, 2, 3, 4]));
  });

  test('MssqlNVarchar / MssqlNChar / MssqlBinary round-trip', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final r = await conn.query(
      'SELECT @n AS n, @c AS c, @b AS b, '
      "SQL_VARIANT_PROPERTY(CAST(@n AS sql_variant), 'MaxLength') AS nl, "
      "SQL_VARIANT_PROPERTY(CAST(@b AS sql_variant), 'BaseType') AS bb",
      {
        'n': const MssqlNVarchar('lan', length: 16),
        'c': MssqlNChar('xy', length: 4),
        'b': MssqlBinary([0x01, 0x02], length: 4),
      },
    );
    expect(r[0]['n'], equals('lan'));
    expect(
        r[0]['nl'], equals(32)); // nvarchar MaxLength is bytes (16 chars × 2)
    expect((r[0]['c'] as String).startsWith('xy'), isTrue);
    expect(r[0]['b'], equals([0x01, 0x02, 0x00, 0x00]));
    expect((r[0]['bb'] as String).toLowerCase(), equals('binary'));
  });

  test('MssqlRowVersion WHERE against rowversion column', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    await conn.execute(
      'IF OBJECT_ID(\'tempdb..#rv\') IS NOT NULL DROP TABLE #rv;'
      'CREATE TABLE #rv (id int NOT NULL, ver rowversion);'
      'INSERT INTO #rv (id) VALUES (1);',
    );
    final cur = await conn.query('SELECT ver FROM #rv WHERE id = 1');
    final bytes = List<int>.from(cur[0]['ver'] as List<int>);
    final rv = MssqlRowVersion(bytes);
    final hit = await conn.query(
      'SELECT id FROM #rv WHERE ver = @v',
      {'v': rv},
    );
    expect(hit[0]['id'], equals(1));
    final miss = await conn.query(
      'SELECT id FROM #rv WHERE ver = @v',
      {'v': MssqlRowVersion.parse('0x0000000000000000')},
    );
    expect(miss.isEmpty, isTrue);
  });
}
