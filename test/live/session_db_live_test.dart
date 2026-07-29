import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live USE / ENVCHANGE + TDS RESETCONNECTION pool reset.
///
/// Requires `dart-mssql` on 127.0.0.1:14330. Skips when unreachable.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<bool> sqlUp() async {
  try {
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 5),
    );
    await c.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  late bool available;

  setUpAll(() async {
    available = await sqlUp();
  });

  test('USE updates conn.database; resetDatabase restores login DB', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(c.close);

    expect(c.database.toLowerCase(), 'master');
    expect(c.initialDatabase.toLowerCase(), 'master');

    await c.query('USE tempdb');
    expect(c.database.toLowerCase(), 'tempdb');

    expect(await c.resetDatabase(), isTrue);
    expect(c.database.toLowerCase(), 'master');
  });

  test('pool resetOnRelease undoes USE before next acquire', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: true,
      resetOnRelease: true,
    ));
    await pool.open();
    addTearDown(pool.close);

    final a = await pool.acquire();
    await a.query('USE tempdb');
    expect(a.database.toLowerCase(), 'tempdb');
    await pool.release(a);

    final b = await pool.acquire();
    expect(identical(a, b), isTrue);
    expect(b.database.toLowerCase(), 'master');
    final name = await b.query('SELECT DB_NAME() AS db');
    expect((name[0]['db'] as String).toLowerCase(), 'master');
    await pool.release(b);
  });

  test('resetOnRelease false leaves switched database', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: false,
      resetOnRelease: false,
    ));
    await pool.open();
    addTearDown(pool.close);

    final a = await pool.acquire();
    await a.query('USE tempdb');
    await pool.release(a);

    final b = await pool.acquire();
    expect(b.database.toLowerCase(), 'tempdb');
    await pool.release(b);
  });

  test('resetSession clears temp table and restores database', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(c.close);

    await c.query('USE tempdb');
    // Temp tables need a SQL batch (not sp_executesql) for session scope.
    await c.query(
      'CREATE TABLE #reset_probe (id INT); INSERT INTO #reset_probe VALUES (1)',
    );
    final before = await c.query('SELECT id FROM #reset_probe');
    expect(before[0]['id'], 1);

    expect(await c.resetSession(), isTrue);
    expect(c.database.toLowerCase(), 'master');

    await expectLater(
      c.query('SELECT id FROM #reset_probe'),
      throwsA(isA<MssqlException>()),
    );
  });

  test('pool resetOnRelease clears temp table for next borrower', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final pool = MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: 0,
      max: 1,
      validateOnAcquire: false,
      resetOnRelease: true,
    ));
    await pool.open();
    addTearDown(pool.close);

    final a = await pool.acquire();
    await a.query(
      'CREATE TABLE #pool_probe (id INT); INSERT INTO #pool_probe VALUES (42)',
    );
    await pool.release(a);

    final b = await pool.acquire();
    expect(identical(a, b), isTrue);
    await expectLater(
      b.query('SELECT id FROM #pool_probe'),
      throwsA(isA<MssqlException>()),
    );
    await pool.release(b);
  });
}
