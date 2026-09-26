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

  test('an explicit port bypasses SQL Browser entirely', () async {
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
    addTearDown(() {
      browserSub.cancel();
      browser.close();
    });

    await expectLater(
      MssqlConnection.connect(
        host: r'127.0.0.1\TESTINST',
        port: 1, // no listener; connect must fail quickly, not hang on UDP
        user: 'sa',
        password: 'pw',
        encrypt: false,
        sqlBrowserPort: browser.port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(anything),
    );
    expect(browserWasQueried, isFalse);
  });

  test(
      'an explicit port that happens to equal the default (1433) still '
      'bypasses SQL Browser', () async {
    // Distinct from the test above: this specifically exercises the
    // "was a port given at all" decision, not "was a non-default port
    // given" — a caller who explicitly states the standard port must not
    // trigger a UDP round trip just because that value coincides with the
    // sentinel default.
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
    addTearDown(() {
      browserSub.cancel();
      browser.close();
    });

    await expectLater(
      MssqlConnection.connect(
        host: r'127.0.0.1\TESTINST',
        port: 1433,
        user: 'sa',
        password: 'pw',
        encrypt: false,
        sqlBrowserPort: browser.port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(anything),
    );
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
