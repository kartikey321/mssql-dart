import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live pool validate-on-acquire against Docker SQL Edge (LAN half-open sockets).
///
/// Kills a pooled session from another connection, then verifies acquire
/// discards the dead connection and returns a working one.
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

  test('validate() returns true on a live connection', () async {
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
    expect(await c.validate(), isTrue);
    expect(c.isOpen, isTrue);
  });

  test('pool validateOnAcquire replaces KILL-ed idle connection', () async {
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
      max: 2,
      validateOnAcquire: true,
    ));
    await pool.open();
    addTearDown(pool.close);

    final victim = await pool.acquire();
    final spid = (await victim.query('SELECT @@SPID AS id'))[0]['id'] as int;
    await pool.release(victim);

    // Kill the idle session from a separate connection.
    final killer = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );
    try {
      await killer.execute('KILL $spid');
    } finally {
      await killer.close();
    }

    // Give the server a moment to tear down the session / TCP.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Acquire must not hand back a dead session (validate probes SELECT 1).
    // SPID numbers can be recycled — only assert the connection works.
    final fresh = await pool.acquire();
    try {
      expect(fresh.isOpen, isTrue);
      final r = await fresh.query('SELECT 41 AS n');
      expect(r[0]['n'], equals(41));
    } finally {
      await pool.release(fresh);
    }
  });

  test('validate() returns false after client close', () async {
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
    await c.close();
    expect(await c.validate(), isFalse);
    expect(c.isOpen, isFalse);
  });

  test('MssqlPoolConfig.validateOnAcquire defaults true', () {
    const c = MssqlPoolConfig(
      host: '10.0.0.1',
      user: 'sa',
      password: 'x',
    );
    expect(c.validateOnAcquire, isTrue);
  });
}
