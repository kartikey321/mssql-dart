import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/src/tds/sql_browser.dart';
import 'package:test/test.dart';

void main() {
  Uint8List reply(String text) {
    final body = Uint8List.fromList(text.codeUnits);
    return Uint8List.fromList(
        [5, body.length & 255, body.length >> 8, ...body]);
  }

  test('builds requests and parses instance names case-insensitively', () {
    expect(SqlBrowser.buildRequest('Test'), [4, 84, 101, 115, 116, 0]);
    expect(
        SqlBrowser.parseTcpPort(
          reply('ServerName;host;InstanceName;sQlExPrEsS;tcp;1444;'),
          expectedInstance: 'SQLEXPRESS',
        ),
        1444);
  });

  test('rejects malformed browser replies', () {
    expect(
        () => SqlBrowser.parseTcpPort(Uint8List.fromList([5, 1, 0]),
            expectedInstance: 'x'),
        throwsFormatException);
    expect(
        () => SqlBrowser.parseTcpPort(reply('InstanceName;x;tcp;0;'),
            expectedInstance: 'x'),
        throwsFormatException);
  });

  group('resolveTcpPort over real loopback UDP', () {
    test('resolves the port from a genuine responder', () async {
      final responder =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = responder.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = responder.receive();
        if (d == null) return;
        responder.send(reply('ServerName;h;InstanceName;SQLEXPRESS;tcp;5555;'),
            d.address, d.port);
      });
      addTearDown(() {
        sub.cancel();
        responder.close();
      });

      final port = await SqlBrowser.resolveTcpPort('127.0.0.1', 'SQLEXPRESS',
          browserPort: responder.port, timeout: const Duration(seconds: 2));
      expect(port, equals(5555));
    });

    test('ignores a reply spoofed from a different sender', () async {
      final responder =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final attacker =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subs = <StreamSubscription<RawSocketEvent>>[];
      // The responder learns the client's ephemeral (address, port) the
      // moment the client's request arrives, exactly as an on-path attacker
      // on the same network could. It hands that to the attacker, which
      // races a bogus reply against the real one, sent from a different
      // source port than the browser the client actually queried.
      subs.add(responder.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = responder.receive();
        if (d == null) return;
        attacker.send(reply('ServerName;h;InstanceName;SQLEXPRESS;tcp;9999;'),
            d.address, d.port);
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          responder.send(
              reply('ServerName;h;InstanceName;SQLEXPRESS;tcp;5555;'),
              d.address,
              d.port);
        });
      }));
      addTearDown(() {
        for (final s in subs) {
          s.cancel();
        }
        responder.close();
        attacker.close();
      });

      final port = await SqlBrowser.resolveTcpPort('127.0.0.1', 'SQLEXPRESS',
          browserPort: responder.port, timeout: const Duration(seconds: 2));
      // A client without the sender check would return 9999 (the attacker's
      // packet, which always arrives first); this proves it is rejected.
      expect(port, equals(5555));
    });

    test('times out when nothing replies', () async {
      final silent =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      await expectLater(
          SqlBrowser.resolveTcpPort('127.0.0.1', 'X',
              browserPort: silent.port,
              timeout: const Duration(milliseconds: 200),
              retries: 0),
          throwsA(isA<Exception>()));
    });
  });
}
