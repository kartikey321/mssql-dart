import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Offline login-timeout coverage for LAN SQL use.
///
/// Query timeouts are covered live in `timeout_live_test.dart` (Attention drain).
/// Sources: go-mssqldb dial/login timeouts; node-mssql connectionTimeout.

void main() {
  test('login timeout when server accepts TCP but never replies', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);

    // Accept TCP but never send PRELOGIN — handshake must not hang forever.
    listener.listen((socket) {
      socket.listen((_) {}, onError: (_) {}, cancelOnError: true);
    });

    final sw = Stopwatch()..start();
    await expectLater(
      MssqlConnection.connect(
        host: '127.0.0.1',
        port: listener.port,
        user: 'sa',
        password: 'x',
        encrypt: false,
        timeout: const Duration(milliseconds: 400),
      ),
      throwsA(isA<MssqlException>().having(
        (e) => e.message,
        'message',
        contains('Login timed out'),
      )),
    );
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('MssqlPoolConfig carries appName and queryTimeout', () {
    const c = MssqlPoolConfig(
      host: '10.0.0.5',
      user: 'sa',
      password: 'x',
      appName: 'lan-app',
      queryTimeout: Duration(seconds: 8),
      connectionTimeout: Duration(seconds: 12),
    );
    expect(c.appName, 'lan-app');
    expect(c.queryTimeout, const Duration(seconds: 8));
    expect(c.connectionTimeout, const Duration(seconds: 12));
    expect(c.validateOnAcquire, isTrue);
  });

  test('validateOnAcquire can be disabled', () {
    const c = MssqlPoolConfig(
      host: '10.0.0.5',
      user: 'sa',
      password: 'x',
      validateOnAcquire: false,
    );
    expect(c.validateOnAcquire, isFalse);
  });

  test('resetOnRelease defaults true and can be disabled', () {
    const on = MssqlPoolConfig(host: 'h', user: 'u', password: 'p');
    expect(on.resetOnRelease, isTrue);
    const off = MssqlPoolConfig(
      host: 'h',
      user: 'u',
      password: 'p',
      resetOnRelease: false,
    );
    expect(off.resetOnRelease, isFalse);
  });
}
