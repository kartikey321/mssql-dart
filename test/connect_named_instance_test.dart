import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// End-to-end test of MssqlConnection.connect's host\INSTANCE wiring: it must
// actually resolve the instance via SQL Browser (SqlBrowser) and then dial
// the resolved TCP port, not the literal "host\INSTANCE" string. No SQL
// Server is needed: a fake Browser responder and a bare TCP listener stand
// in for the real server.

Uint8List _browserReply(String text) {
  final body = Uint8List.fromList(text.codeUnits);
  return Uint8List.fromList([5, body.length & 255, body.length >> 8, ...body]);
}

void main() {
  test('resolves host\\INSTANCE via SQL Browser and dials the resolved port',
      () async {
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final sub = tcp.listen((s) {
      if (!accepted.isCompleted) accepted.complete();
      s.destroy();
    });

    final browser =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final browserSub = browser.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = browser.receive();
      if (d == null) return;
      browser.send(
          _browserReply('ServerName;h;InstanceName;TESTINST;tcp;${tcp.port};'),
          d.address,
          d.port);
    });

    addTearDown(() async {
      await sub.cancel();
      await tcp.close();
      browserSub.cancel();
      browser.close();
    });

    // The TDS handshake will fail against this bare TCP listener; only the
    // routing (Browser resolution -> connect to the resolved port) is under
    // test, so any error past that point is expected and ignored.
    unawaited(MssqlConnection.connect(
      host: r'127.0.0.1\TESTINST',
      user: 'sa',
      password: 'pw',
      encrypt: false,
      sqlBrowserPort: browser.port,
      timeout: const Duration(seconds: 2),
    ).then((_) {}, onError: (_) {}));

    await accepted.future.timeout(const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException(
            'connect() never reached the Browser-resolved TCP port; the '
            r'host\INSTANCE split is likely broken'));
  });

  test(
      'an explicit port bypasses SQL Browser entirely, dialing the stripped '
      'host rather than the literal "host\\instance" string', () async {
    // A dynamic port, not a hardcoded 1433: this machine (or CI) may already
    // have something else listening on 1433, which would make a hardcoded
    // dial there hang waiting for a TDS handshake with an unrelated service
    // instead of failing fast — exactly the kind of environment-dependent
    // flakiness a regression test must not have. The numeral 1433 itself
    // isn't special to connect() any more (its sentinel is `port == null`,
    // not a value comparison); that specific "coincides with defaultPort"
    // case is covered at the connection-string layer instead, in
    // connection_string_test.dart.
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final sub = tcp.listen((s) {
      if (!accepted.isCompleted) accepted.complete();
      s.destroy();
    });

    var browserWasQueried = false;
    final browser =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Must drain: an undrained RawDatagramSocket can keep re-firing read
    // events for the same pending datagram, busy-looping the event loop
    // instead of the test failing cleanly if Browser is ever queried again.
    final browserSub = browser.listen((e) {
      if (e != RawSocketEvent.read) return;
      if (browser.receive() != null) browserWasQueried = true;
    });
    addTearDown(() async {
      await sub.cancel();
      await tcp.close();
      browserSub.cancel();
      browser.close();
    });

    // Reaching this listener at all proves the dialed host was the stripped
    // "127.0.0.1", not the literal "127.0.0.1\TESTINST" (which would fail
    // hostname lookup and never reach any listener, real or fake).
    unawaited(MssqlConnection.connect(
      host: r'127.0.0.1\TESTINST',
      port: tcp.port,
      user: 'sa',
      password: 'pw',
      encrypt: false,
      sqlBrowserPort: browser.port,
      timeout: const Duration(seconds: 2),
    ).then((_) {}, onError: (_) {}));

    await accepted.future.timeout(const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException(
            'connect() never reached the explicit port; the instance '
            r'suffix was likely left in the dialed hostname'));
    expect(browserWasQueried, isFalse);
  });

  test('a Browser resolution attempt from connect() does not retry', () async {
    var requestCount = 0;
    final browser =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Never replies; if connect() retried, more than one request would
    // arrive within the timeout window.
    final browserSub = browser.listen((e) {
      if (e != RawSocketEvent.read) return;
      if (browser.receive() != null) requestCount++;
    });
    addTearDown(() {
      browserSub.cancel();
      browser.close();
    });

    await expectLater(
      MssqlConnection.connect(
        host: r'127.0.0.1\TESTINST',
        user: 'sa',
        password: 'pw',
        encrypt: false,
        sqlBrowserPort: browser.port,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(anything),
    );
    expect(requestCount, equals(1));
  });
}
