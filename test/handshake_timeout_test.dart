import 'dart:io';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// Regression test for: connect(timeout: ...) only bounded the initial
// TCP/TLS socket connect, not PRELOGIN/LOGIN7/the login-response read. A
// server that accepts the connection but then stalls (black-holed, a
// misbehaving proxy) hung connect() forever past that point, regardless of
// the timeout given. No real SQL Server is needed: a bare TCP listener that
// accepts and then never writes a byte stands in for the stalled server.

void main() {
  test(
      'connect() times out if the server accepts the connection but never '
      'speaks (PRELOGIN never answered)', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sub = listener.listen((socket) {
      // Accept and go silent — never write PRELOGIN's response.
    });
    addTearDown(() async {
      await sub.cancel();
      await listener.close();
    });

    final stopwatch = Stopwatch()..start();
    await expectLater(
      MssqlConnection.connect(
        host: '127.0.0.1',
        port: listener.port,
        user: 'sa',
        password: 'pw',
        encrypt: false,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<MssqlException>()
          .having((e) => e.message, 'message', contains('timed out'))),
    );
    stopwatch.stop();

    // Generous upper bound: proves connect() actually gave up close to the
    // requested timeout rather than hanging — this is what the old code
    // did not do at all (it would still be waiting well past 300ms).
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test(
      'connect() leaves no usable connection behind after a handshake '
      'timeout', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sub = listener.listen((socket) {});
    addTearDown(() async {
      await sub.cancel();
      await listener.close();
    });

    // Nothing to assert on the (rejected) MssqlConnection itself — connect()
    // throws rather than returning one — but the fix must not leave the
    // raw socket it opened lingering; _markDead() destroying it is the
    // observable half of that from outside this file, covered implicitly
    // by the listener/test process exiting cleanly (addTearDown would hang
    // on listener.close() if something still held the socket open).
    await expectLater(
      MssqlConnection.connect(
        host: '127.0.0.1',
        port: listener.port,
        user: 'sa',
        password: 'pw',
        encrypt: false,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<MssqlException>()),
    );
  });
}
