import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/prelogin.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Named-instance + SQL Browser offline tests.
///
/// Sources: MS-SSRP CLNT_UCAST_INST / SVR_RESP; go-mssqldb instance lookup;
/// ms-tds PRELOGIN INSTOPT (§2.2.6.4).

Uint8List _svrResp({
  required String instance,
  required int tcpPort,
  String serverName = 'HOST',
}) {
  final text = 'ServerName;$serverName;InstanceName;$instance;IsClustered;No;'
      'Version;15.0.2000.5;tcp;$tcpPort;;';
  final payload = utf8.encode(text);
  final out = Uint8List(3 + payload.length);
  out[0] = 0x05;
  out[1] = payload.length & 0xFF;
  out[2] = (payload.length >> 8) & 0xFF;
  out.setRange(3, out.length, payload);
  return out;
}

Map<int, Uint8List> _parsePreloginOptions(Uint8List body) {
  final map = <int, Uint8List>{};
  var i = 0;
  while (i < body.length && body[i] != preloginTerminator) {
    final token = body[i];
    final off = (body[i + 1] << 8) | body[i + 2];
    final len = (body[i + 3] << 8) | body[i + 4];
    i += 5;
    map[token] = Uint8List.sublistView(body, off, off + len);
  }
  return map;
}

void main() {
  group('ServerEndpoint.parse', () {
    test('plain host keeps default port', () {
      final ep = ServerEndpoint.parse('sql01');
      expect(ep.host, 'sql01');
      expect(ep.port, defaultPort);
      expect(ep.instanceName, isNull);
      expect(ep.shouldResolvePort, isFalse);
    });

    test(r'HOST\INSTANCE enables browser resolve', () {
      final ep = ServerEndpoint.parse(r'sql01\SQLEXPRESS');
      expect(ep.host, 'sql01');
      expect(ep.instanceName, 'SQLEXPRESS');
      expect(ep.port, defaultPort);
      expect(ep.shouldResolvePort, isTrue);
    });

    test(r'HOST\INSTANCE,15001 skips browser', () {
      final ep = ServerEndpoint.parse(r'sql01\SQLEXPRESS,15001');
      expect(ep.host, 'sql01');
      expect(ep.instanceName, 'SQLEXPRESS');
      expect(ep.port, 15001);
      expect(ep.shouldResolvePort, isFalse);
    });

    test('host,port without instance', () {
      final ep = ServerEndpoint.parse('sql01,1500');
      expect(ep.host, 'sql01');
      expect(ep.port, 1500);
      expect(ep.instanceName, isNull);
      expect(ep.shouldResolvePort, isFalse);
    });

    test('instanceName param + default port resolves', () {
      final ep = ServerEndpoint.parse(
        'sql01',
        instanceName: 'INST1',
      );
      expect(ep.shouldResolvePort, isTrue);
      expect(ep.instanceName, 'INST1');
    });

    test('explicit port arg skips browser even with instance', () {
      final ep = ServerEndpoint.parse(
        'sql01',
        port: 15001,
        instanceName: 'INST1',
      );
      expect(ep.port, 15001);
      expect(ep.instanceName, 'INST1');
      expect(ep.shouldResolvePort, isFalse);
    });

    test(r'HOST/INSTANCE slash form', () {
      final ep = ServerEndpoint.parse('sql01/SQLEXPRESS');
      expect(ep.host, 'sql01');
      expect(ep.instanceName, 'SQLEXPRESS');
      expect(ep.shouldResolvePort, isTrue);
    });

    test('instanceName override wins over host backslash', () {
      final ep = ServerEndpoint.parse(
        r'sql01\FROMHOST',
        instanceName: 'OVERRIDE',
      );
      expect(ep.instanceName, 'OVERRIDE');
    });
  });

  group('SqlBrowser encode/parse', () {
    test('CLNT_UCAST_INST request bytes', () {
      final req = SqlBrowser.buildClntUcastInst('SQLEXPRESS');
      expect(req[0], 0x04);
      expect(utf8.decode(req.sublist(1, req.length - 1)), 'SQLEXPRESS');
      expect(req.last, 0x00);
    });

    test('SVR_RESP tcp port', () {
      final data = _svrResp(instance: 'SQLEXPRESS', tcpPort: 51433);
      expect(
        SqlBrowser.parseTcpPort(data, expectedInstance: 'SQLEXPRESS'),
        51433,
      );
    });

    test('SVR_RESP instance mismatch throws', () {
      final data = _svrResp(instance: 'OTHER', tcpPort: 51433);
      expect(
        () => SqlBrowser.parseTcpPort(data, expectedInstance: 'SQLEXPRESS'),
        throwsA(isA<MssqlException>()),
      );
    });

    test('SVR_RESP declared length must match the datagram', () {
      final data = _svrResp(instance: 'SQLEXPRESS', tcpPort: 51433);
      data[1]--;
      expect(
        () => SqlBrowser.parseTcpPort(data),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing tcp throws', () {
      final text = 'ServerName;H;InstanceName;X;IsClustered;No;Version;1.0;;';
      final payload = utf8.encode(text);
      final data = Uint8List.fromList([
        0x05,
        payload.length & 0xFF,
        (payload.length >> 8) & 0xFF,
        ...payload,
      ]);
      expect(
        () => SqlBrowser.parseTcpPort(data),
        throwsA(isA<MssqlException>()),
      );
    });
  });

  group('SqlBrowser UDP mock', () {
    test('resolveTcpPort against local mock browser', () async {
      final browser =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(browser.close);

      late StreamSubscription<RawSocketEvent> sub;
      sub = browser.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = browser.receive();
        if (dg == null) return;
        expect(dg.data[0], 0x04);
        final name = utf8.decode(dg.data.sublist(1, dg.data.length - 1));
        expect(name, 'MOCKINST');
        final resp = _svrResp(instance: 'MOCKINST', tcpPort: 49152);
        browser.send(resp, dg.address, dg.port);
      });
      addTearDown(() => sub.cancel());

      final resolved = await SqlBrowser.resolve(
        '127.0.0.1',
        'MOCKINST',
        browserPort: browser.port,
        timeout: const Duration(seconds: 2),
      );
      expect(resolved.port, 49152);
      expect(resolved.address.address, InternetAddress.loopbackIPv4.address);
    });

    test('resolve supports an IPv6 Browser endpoint', () async {
      final browser =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv6, 0);
      addTearDown(browser.close);

      late StreamSubscription<RawSocketEvent> sub;
      sub = browser.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = browser.receive();
        if (dg == null) return;
        browser.send(
          _svrResp(instance: 'IPV6INST', tcpPort: 49153),
          dg.address,
          dg.port,
        );
      });
      addTearDown(() => sub.cancel());

      final resolved = await SqlBrowser.resolve(
        '::1',
        'IPV6INST',
        browserPort: browser.port,
        timeout: const Duration(seconds: 2),
      );
      expect(resolved.port, 49153);
      expect(resolved.address.type, InternetAddressType.IPv6);
    });

    test('resolveTcpPort ignores datagrams from unexpected source port',
        () async {
      final browser =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final spoof =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(browser.close);
      addTearDown(spoof.close);

      late StreamSubscription<RawSocketEvent> sub;
      sub = browser.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = browser.receive();
        if (dg == null) return;

        spoof.send(
          _svrResp(instance: 'MOCKINST', tcpPort: 1),
          dg.address,
          dg.port,
        );
        browser.send(
          _svrResp(instance: 'MOCKINST', tcpPort: 49152),
          dg.address,
          dg.port,
        );
      });
      addTearDown(() => sub.cancel());

      final port = await SqlBrowser.resolveTcpPort(
        '127.0.0.1',
        'MOCKINST',
        browserPort: browser.port,
        timeout: const Duration(seconds: 2),
      );
      expect(port, 49152);
    });
  });

  group('PRELOGIN INSTOPT', () {
    test('sends null-terminated instance name', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        final hdr = await serverReader.readChunk(headerSize);
        final size = (hdr[2] << 8) | hdr[3];
        final body = await serverReader.readChunk(size - headerSize);
        final opts = _parsePreloginOptions(Uint8List.fromList(body));
        final inst = opts[preloginInstopt]!;
        expect(utf8.decode(inst.sublist(0, inst.length - 1)), 'SQLEXPRESS');
        expect(inst.last, 0x00);

        // Minimal encryptNotSupported reply so client can finish.
        final reply = Uint8List.fromList([
          preloginEncryption,
          0x00,
          0x06,
          0x00,
          0x01,
          preloginTerminator,
          encryptNotSupported,
        ]);
        pair.server.add(tdsPacket(type: packReply, body: reply));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(
        buf,
        requestEncrypt: encryptNotSupported,
        instanceName: 'SQLEXPRESS',
      );
      await Prelogin.read(buf);
      await serverDone;
    });
  });
}
