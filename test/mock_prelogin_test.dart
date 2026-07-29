import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/prelogin.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Mock-server PreLogin tests.
///
/// Source: microsoft/go-mssqldb `bad_server_test.go` (malformed / minimal
/// PRELOGIN replies, encrypt negotiation). No live SQL Server required.

Uint8List _preloginBody(Map<int, List<int>> fields) {
  final keys = fields.keys.toList()..sort();
  var offset = keys.length * 5 + 1;
  final header = BytesBuilder(copy: false);
  final values = BytesBuilder(copy: false);

  for (final k in keys) {
    final v = fields[k]!;
    header.addByte(k);
    header.addByte((offset >> 8) & 0xFF);
    header.addByte(offset & 0xFF);
    header.addByte((v.length >> 8) & 0xFF);
    header.addByte(v.length & 0xFF);
    values.add(v);
    offset += v.length;
  }
  header.addByte(preloginTerminator);

  return Uint8List.fromList([...header.toBytes(), ...values.toBytes()]);
}

Future<void> _drainPreloginRequest(ChunkedStreamReader<int> reader) async {
  final hdr = await reader.readChunk(headerSize);
  expect(hdr.length, equals(headerSize));
  expect(hdr[0], equals(packPrelogin));
  final size = (hdr[2] << 8) | hdr[3];
  final bodyLen = size - headerSize;
  if (bodyLen > 0) {
    final body = await reader.readChunk(bodyLen);
    expect(body.length, equals(bodyLen));
  }
}

void main() {
  group('PreLogin mock server (encrypt not supported)', () {
    // go-mssqldb: goodPreloginSequence with encryptNotSup
    test('client send + read negotiates encryptNotSupported', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptNotSupported],
        });
        pair.server.add(tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptNotSupported));
      expect(result.requiresTls, isFalse);
      expect(result.fedAuthRequired, isFalse);
    });

    test('server advertising encryptOn sets requiresTls', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginVersion: [0x0F, 0x00, 0x00, 0x00, 0x00, 0x00],
          preloginEncryption: [encryptOn],
        });
        pair.server.add(tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptOn);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptOn));
      expect(result.requiresTls, isTrue);
    });

    test('fedAuthRequired flag is parsed from server response', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptNotSupported],
          preloginFedAuthRequired: [0x01],
        });
        pair.server.add(tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, fedAuthRequired: true);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.fedAuthRequired, isTrue);
    });
  });

  group('PreLogin bad server responses', () {
    // go-mssqldb: TestBadServerIncorrectLoginResponseType analogue for PRELOGIN
    test('wrong packet type throws StateError', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        pair.server.add(tdsPacket(type: packLogin7, body: [0x00]));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      await expectLater(Prelogin.read(buf), throwsA(isA<StateError>()));
      await serverDone;
    });

    // go-mssqldb: TestBadServerPreLoginPacketWithNoEntries (we document default)
    test('empty PRELOGIN option table still yields defaults', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        pair.server.add(
          tdsPacket(type: packReply, body: [preloginTerminator]),
        );
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptNotSupported));
      expect(result.fedAuthRequired, isFalse);
    });

    // go-mssqldb: TestBadServerInvalidTokenId shape after PRELOGIN
    test('invalid token id after login-shaped reply is readable as bytes',
        () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptNotSupported],
        });
        pair.server.add(tdsPacket(type: packReply, body: body));
        await pair.server.flush();
        pair.server.add(tdsPacket(type: packReply, body: [0x00]));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      expect(result.encryption, equals(encryptNotSupported));

      final pktType = await buf.beginRead();
      expect(pktType, equals(packReply));
      expect(await buf.readUint8(), equals(0x00));
      await serverDone;
    });

    // go-mssqldb bad_server: out-of-range PRELOGIN field length is ignored
    test('PRELOGIN field length past end of packet yields defaults', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        // token ENCRYPTION, offset 6, length 0x0100 (way past body)
        final body = Uint8List.fromList([
          preloginEncryption,
          0x00,
          0x06,
          0x01,
          0x00,
          preloginTerminator,
          encryptOn, // would be encryption if length were 1
        ]);
        pair.server.add(tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptNotSupported));
      expect(result.fedAuthRequired, isFalse);
    });

    // ms-tds encryptRequired — client must still see requiresTls
    test('encryptRequired from server sets requiresTls', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final serverDone = () async {
        await _drainPreloginRequest(serverReader);
        final body = _preloginBody({
          preloginEncryption: [encryptRequired],
        });
        pair.server.add(tdsPacket(type: packReply, body: body));
        await pair.server.flush();
      }();

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptOn);
      final result = await Prelogin.read(buf);
      await serverDone;

      expect(result.encryption, equals(encryptRequired));
      expect(result.requiresTls, isTrue);
    });
  });

  group('PreLogin client request framing', () {
    test('client PRELOGIN packet is type 0x12 with EOM', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);

      final buf = TdsBuffer(pair.client);
      await Prelogin.send(buf, requestEncrypt: encryptNotSupported);

      final hdr = await serverReader.readChunk(headerSize);
      expect(hdr[0], equals(packPrelogin));
      expect(hdr[1] & statusEOM, equals(statusEOM));
      final size = (hdr[2] << 8) | hdr[3];
      expect(size, greaterThan(headerSize));
      final bodyLen = size - headerSize;
      if (bodyLen > 0) {
        final body = await serverReader.readChunk(bodyLen);
        expect(body.length, equals(bodyLen));
      }
    });
  });
}
