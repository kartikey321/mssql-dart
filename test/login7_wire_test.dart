import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/login7.dart';
import 'package:mssql/src/tds/prelogin.dart';
import 'package:mssql/src/tds/rpc.dart';
import 'package:test/test.dart';

// Wire-format tests for LOGIN7 and PRELOGIN. No SQL Server needed: the bytes a
// TdsBuffer writes are captured from a loopback socket and parsed.

/// Runs [write] against a TdsBuffer and returns the TDS message it sent, as
/// (concatenated packet payloads, total bytes on the wire).
Future<({Uint8List payload, int wireBytes})> _capture(
  Future<void> Function(TdsBuffer buf) write, {
  bool secure = false,
  int packetSize = 512,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clientFuture =
      Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final peer = await server.first;
  final client = await clientFuture;
  final received = peer.fold<BytesBuilder>(BytesBuilder(), (b, d) {
    b.add(d);
    return b;
  });
  final buf = TdsBuffer(client, secureTransport: secure);
  if (secure) buf.packetSize = packetSize;
  await write(buf);
  await client.close();
  final bytes = (await received).toBytes();
  peer.destroy();
  await server.close();

  final payload = BytesBuilder();
  var i = 0;
  while (i < bytes.length) {
    final size = (bytes[i + 2] << 8) | bytes[i + 3];
    payload.add(bytes.sublist(i + headerSize, i + size));
    i += size;
  }
  return (payload: payload.toBytes(), wireBytes: bytes.length);
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

String _utf16(Uint8List b, int offset, int chars) =>
    String.fromCharCodes(List.generate(chars, (i) => _u16(b, offset + 2 * i)));

class _Field {
  final String name;
  final String value;
  final int offset;
  final int chars;
  _Field(this.name, this.value, this.offset, this.chars);
}

/// Reads the LOGIN7 string fields in wire order and checks that the declared
/// offsets and lengths describe the variable data with no gaps or overlaps.
List<_Field> _parseLoginFields(Uint8List body) {
  expect(_u32(body, 0), equals(body.length), reason: 'declared total length');
  // Offset/length pairs start at byte 36; data order on the wire.
  const layout = [
    ('host', 36),
    ('user', 40),
    ('pass', 44),
    ('app', 48),
    ('server', 52),
    ('ctlInt', 60),
    ('lang', 64),
    ('db', 68),
  ];
  final fields = <_Field>[];
  for (final (name, pos) in layout) {
    final off = _u16(body, pos);
    final chars = _u16(body, pos + 2);
    fields.add(_Field(
        name, name == 'pass' ? '' : _utf16(body, off, chars), off, chars));
  }
  for (var i = 0; i < fields.length - 1; i++) {
    expect(fields[i].offset + 2 * fields[i].chars, equals(fields[i + 1].offset),
        reason: 'gap or overlap after ${fields[i].name}');
  }
  final last = fields.last;
  expect(last.offset + 2 * last.chars, equals(_u16(body, 78)),
      reason: 'SSPI data follows the last string field');
  expect(_u16(body, 78) + _u16(body, 80), equals(body.length),
      reason: 'no trailing bytes after the declared fields');
  return fields;
}

LoginConfig _cfg({
  String host = 'client-host',
  String app = 'mssql-dart',
  int tdsVersion = verTDS74,
  int packetSize = 512,
  String? fedAuthToken,
}) =>
    LoginConfig(
      host: host,
      username: 'sa',
      password: 'pw',
      appName: app,
      serverName: 'db.example.com',
      database: 'master',
      packetSize: packetSize,
      tdsVersion: tdsVersion,
      fedAuthToken: fedAuthToken,
    );

void main() {
  group('LOGIN7 on encrypted connections', () {
    test('every declared field length covers its bytes; message ends aligned',
        () async {
      for (final host in ['h', 'client-host', 'x' * 60, 'y' * 120]) {
        for (final app in ['a', 'mssql-dart', 'z' * 90, 'w' * 128]) {
          final cap = await _capture(
            (b) => Login7.send(b, _cfg(host: host, app: app)),
            secure: true,
          );
          final fields = _parseLoginFields(cap.payload);
          // Worst-case padding is 255 characters spread over the app name,
          // client library name and hostname (128-char cap each). When they
          // cannot absorb it, the login is sent unpadded but still valid.
          int room(int used) => used >= 128 ? 0 : 128 - used;
          final capacity = room(app.length) + 128 + room(host.length);
          if (capacity >= 255) {
            expect(cap.wireBytes % 512, equals(0),
                reason: 'host=${host.length} app=${app.length} not aligned');
          }
          final byName = {for (final f in fields) f.name: f};
          expect(byName['host']!.value.trimRight(), equals(host));
          expect(byName['app']!.value.trimRight(), equals(app));
          expect(byName['ctlInt']!.value.trim(), isEmpty);
        }
      }
    });

    test('an application name longer than 128 chars does not throw', () async {
      final app = 'q' * 200;
      final cap = await _capture(
        (b) => Login7.send(b, _cfg(app: app)),
        secure: true,
      );
      final byName = {
        for (final f in _parseLoginFields(cap.payload)) f.name: f
      };
      expect(byName['app']!.value.trimRight(), equals(app));
    });

    test('names too long to absorb padding are sent unpadded, still valid',
        () async {
      final cap = await _capture(
        (b) => Login7.send(b, _cfg(host: 'h' * 128, app: 'a' * 128)),
        secure: true,
      );
      final byName = {
        for (final f in _parseLoginFields(cap.payload)) f.name: f
      };
      expect(byName['host']!.chars, equals(128));
      expect(byName['app']!.chars, equals(128));
    });
  });

  group('LOGIN7 on unencrypted connections', () {
    test('nothing is padded', () async {
      final cap = await _capture((b) => Login7.send(b, _cfg()));
      final byName = {
        for (final f in _parseLoginFields(cap.payload)) f.name: f
      };
      expect(byName['host']!.value, equals('client-host'));
      expect(byName['app']!.value, equals('mssql-dart'));
      expect(byName['ctlInt']!.chars, equals(0));
    });
  });

  group('TDS 8.0 strict mode wire format', () {
    test('LOGIN7 carries the TDS 8.0 version', () async {
      final cap = await _capture(
        (b) => Login7.send(b, _cfg(tdsVersion: verTDS80)),
        secure: true,
      );
      expect(_u32(cap.payload, 4), equals(verTDS80));
    });

    test('LOGIN7 keeps the TDS 7.4 version by default', () async {
      final cap = await _capture((b) => Login7.send(b, _cfg()));
      expect(_u32(cap.payload, 4), equals(verTDS74));
    });

    test('PRELOGIN requests the strict encryption value', () async {
      final cap = await _capture(
        (b) => Prelogin.send(b, requestEncrypt: encryptStrict),
        secure: true,
      );
      final p = cap.payload;
      int? value;
      for (var i = 0; p[i] != preloginTerminator; i += 5) {
        if (p[i] == preloginEncryption) {
          final off = (p[i + 1] << 8) | p[i + 2];
          value = p[off];
        }
      }
      expect(encryptStrict, equals(4));
      expect(value, equals(encryptStrict));
    });
  });

  group('Azure AD (FedAuth) login parity', () {
    // The FedAuth feature block is an odd number of bytes, so the LOGIN7 cannot
    // be padded to an aligned end with UCS-2 text. SQL batches are always
    // even-sized, so text padding can never correct the stream afterwards;
    // only an RPC (byte-granular padding parameter) can.
    test('LOGIN7 leaves the sealed stream at an odd offset', () async {
      late TdsBuffer buf;
      await _capture((b) async {
        buf = b;
        await Login7.send(b, _cfg(fedAuthToken: 'tok'));
      }, secure: true);
      expect(buf.sealedBytes.isOdd, isTrue);
    });

    test('batches cannot re-align an odd stream', () async {
      final cap = await _capture((b) async {
        await Login7.send(b, _cfg(fedAuthToken: 'tok'));
        await RpcRequest.sendBatch(b, 'SELECT 1');
      }, secure: true);
      expect(cap.wireBytes % 512, isNot(0));
    });

    test(
        'one parameterized RPC after login restores alignment, then batches '
        'stay aligned', () async {
      late TdsBuffer buf;
      final cap = await _capture((b) async {
        buf = b;
        await Login7.send(b, _cfg(fedAuthToken: 'tok'));
        await RpcRequest.sendExecuteSql(b, 'SELECT 1', const {});
        expect(b.sealedBytes % 512, equals(0));
        await RpcRequest.sendBatch(b, 'SELECT 2');
        await RpcRequest.sendBatch(b, 'SELECT ' * 40);
      }, secure: true);
      expect(buf.sealedBytes % 512, equals(0));
      expect(cap.wireBytes % 512, equals(0));
    });
  });
}
