import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Always On / HA connect options against a normal (non-AG) SQL Server.
///
/// Without an AG listener, ApplicationIntent=ReadOnly still logs in (bit set
/// but no ENVCHANGE routing). FailoverPartner is exercised only when primary
/// is unreachable. Skips when 127.0.0.1:14330 is down.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<bool> _sqlUp() async {
  try {
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: liveTestConfig.encrypt,
      trustServerCertificate: liveTestConfig.trustServerCertificate,
      timeout: const Duration(seconds: 3),
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
    available = await _sqlUp();
  });

  test('readOnlyIntent connects to standalone SQL (no routing)', () async {
    if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final conn = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: liveTestConfig.encrypt,
      trustServerCertificate: liveTestConfig.trustServerCertificate,
      readOnlyIntent: true,
      timeout: const Duration(seconds: 5),
    );
    try {
      final r = await conn.query('SELECT DB_NAME() AS db');
      expect(r[0]['db'], equals('master'));
    } finally {
      await conn.close();
    }
  });

  test('readOnlyIntent without database throws', () {
    expect(
      () => MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        encrypt: false,
        readOnlyIntent: true,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('FailoverPartner used when primary host is unreachable', () async {
    if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    // 127.0.0.1:1 refuses quickly; partner is the live Docker instance.
    final conn = await MssqlConnection.connect(
      host: '127.0.0.1',
      port: 1,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: liveTestConfig.encrypt,
      trustServerCertificate: liveTestConfig.trustServerCertificate,
      failoverPartner: _host,
      failoverPort: _port,
      timeout: const Duration(seconds: 3),
    );
    try {
      final r = await conn.query('SELECT 1 AS n');
      expect(r[0]['n'], equals(1));
    } finally {
      await conn.close();
    }
  });

  test('ADO ApplicationIntent string connects', () async {
    if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
      return;
    }
    final trust = liveTestConfig.trustServerCertificate ? 'yes' : 'no';
    final enc = liveTestConfig.encrypt ? 'true' : 'false';
    final conn = await MssqlConnection.connectFromString(
      'Server=$_host,$_port;Database=master;User Id=$_user;'
      'Password=$_password;Encrypt=$enc;TrustServerCertificate=$trust;'
      'ApplicationIntent=ReadOnly;',
    );
    try {
      expect((await conn.query('SELECT 1 AS n'))[0]['n'], equals(1));
    } finally {
      await conn.close();
    }
  });
}
