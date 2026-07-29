import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tcp_options.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

/// TCP keepalive + SessionInitSQL (go-mssqldb keepAlive / SessionInitSQL).
///
/// Live cases skip when 127.0.0.1:14330 is down.

final _config = liveTestConfig;
String get _host => _config.host;
int get _port => _config.port;
String get _user => _config.user;
String get _password => _config.password;

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
      keepAlive: Duration.zero,
    );
    await c.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  group('applyMssqlTcpOptions', () {
    test('enables tcpNoDelay and SO_KEEPALIVE without throwing', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final client = await Socket.connect(listener.address, listener.port);
      addTearDown(client.destroy);
      final server = await listener.first;
      addTearDown(server.destroy);

      applyMssqlTcpOptions(
        client,
        keepAlive: const Duration(seconds: 30),
      );
      // Round-trip still works after options.
      client.add([1, 2, 3]);
      await client.flush();
      final got = await server.first;
      expect(got, equals([1, 2, 3]));
    });

    test('Duration.zero skips keepalive enable', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final client = await Socket.connect(listener.address, listener.port);
      addTearDown(client.destroy);
      await listener.first.then((s) => s.destroy());

      // Should not throw.
      applyMssqlTcpOptions(client, keepAlive: Duration.zero);
    });
  });

  group('sessionInitSql live', () {
    late bool available;

    setUpAll(() async {
      available = await _sqlUp();
    });

    test('runs after login (SET LOCK_TIMEOUT)', () async {
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
        sessionInitSql: 'SET LOCK_TIMEOUT 1234;',
      );
      try {
        final r = await conn.query(
          'SELECT @@LOCK_TIMEOUT AS lt',
        );
        expect(r[0]['lt'], equals(1234));
      } finally {
        await conn.close();
      }
    });

    test('re-applies after resetSession', () async {
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
        sessionInitSql: 'SET LOCK_TIMEOUT 4321;',
      );
      try {
        await conn.execute('SET LOCK_TIMEOUT 1;');
        expect(
          (await conn.query('SELECT @@LOCK_TIMEOUT AS lt'))[0]['lt'],
          equals(1),
        );
        final ok = await conn.resetSession();
        expect(ok, isTrue);
        expect(
          (await conn.query('SELECT @@LOCK_TIMEOUT AS lt'))[0]['lt'],
          equals(4321),
        );
      } finally {
        await conn.close();
      }
    });
  });
}
