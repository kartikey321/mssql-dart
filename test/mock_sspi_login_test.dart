import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/login7.dart';
import 'package:mssql/src/tds/prelogin.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Mock NTLM SSPI handshake: PreLogin → Login7(Type1) → tokenSSPI(Type2) →
/// packSSPIMessage(Type3) → LOGINACK.
///
/// Sources: go-mssqldb tds.go SSPI exchange; ms-tds §2.2.7.22 SSPI token;
/// [MS-NLMP] Type 2/3.

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

Future<Uint8List> _readPacketBody(
  ChunkedStreamReader<int> reader,
  int expectType,
) async {
  final hdr = await reader.readChunk(headerSize);
  expect(hdr[0], equals(expectType));
  final size = (hdr[2] << 8) | hdr[3];
  final bodyLen = size - headerSize;
  if (bodyLen <= 0) return Uint8List(0);
  return Uint8List.fromList(await reader.readChunk(bodyLen));
}

Uint8List _type2Challenge({
  required Uint8List serverChallenge,
  required String targetName,
  required Uint8List targetInfo,
}) {
  final target = ucs2(targetName);
  const headerLen = 48;
  final out = Uint8List(headerLen + target.length + targetInfo.length);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 8, const [0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0x00]);
  bd.setUint32(8, 2, Endian.little);
  var off = headerLen;
  bd.setUint16(12, target.length, Endian.little);
  bd.setUint16(14, target.length, Endian.little);
  bd.setUint32(16, off, Endian.little);
  bd.setUint32(
    20,
    NtlmAuth.negotiateUnicode |
        NtlmAuth.negotiateNtlm |
        NtlmAuth.negotiateTargetInfo |
        NtlmAuth.negotiateExtendedSessionSecurity,
    Endian.little,
  );
  out.setRange(24, 32, serverChallenge);
  out.setRange(off, off + target.length, target);
  off += target.length;
  bd.setUint16(40, targetInfo.length, Endian.little);
  bd.setUint16(42, targetInfo.length, Endian.little);
  bd.setUint32(44, off, Endian.little);
  out.setRange(off, off + targetInfo.length, targetInfo);
  return out;
}

Uint8List _sspiToken(Uint8List blob) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenSSPI);
  writeUint16LE(out, blob.length);
  out.add(blob);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _loginAckDone({required String progName, required String database}) {
  final name = ucs2(progName);
  final ackData = BytesBuilder(copy: false);
  ackData.addByte(1);
  ackData.add([0x74, 0x00, 0x00, 0x04]);
  ackData.addByte(progName.length);
  ackData.add(name);
  writeUint32LE(ackData, 0x01000000);
  final ackBytes = ackData.toBytes();

  final envPayload = BytesBuilder(copy: false);
  envPayload.addByte(envDatabase);
  envPayload.addByte(database.length);
  envPayload.add(ucs2(database));
  envPayload.addByte(database.length);
  envPayload.add(ucs2(database));
  final envBytes = envPayload.toBytes();

  final out = BytesBuilder(copy: false);
  out.addByte(tokenLoginAck);
  writeUint16LE(out, ackBytes.length);
  out.add(ackBytes);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, envBytes.length);
  out.add(envBytes);
  out.addByte(tokenDone);
  writeUint16LE(out, doneFlagFinal);
  writeUint16LE(out, 0);
  writeUint64LE(out, 0);
  return Uint8List.fromList(out.toBytes());
}

void main() {
  test('PreLogin → Login7(NTLM) → SSPI → LOGINACK', () async {
    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);
    final serverReader = ChunkedStreamReader(pair.server);

    final ntlm = NtlmAuth(
      domain: 'DOMAIN',
      username: 'user',
      password: 'SecREt01',
      workstation: 'PC1',
    );

    final targetInfo = Uint8List.fromList([
      0x02, 0x00, 0x0C, 0x00, // NetBIOS domain
      ...ucs2('DOMAIN'),
      0x00, 0x00, 0x00, 0x00, // terminator
    ]);
    final type2 = _type2Challenge(
      serverChallenge: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      targetName: 'DOMAIN',
      targetInfo: targetInfo,
    );

    final serverDone = () async {
      await _readPacketBody(serverReader, packPrelogin);
      pair.server.add(tdsPacket(
        type: packReply,
        body: _preloginBody({preloginEncryption: [encryptNotSupported]}),
      ));
      await pair.server.flush();

      final login7 = await _readPacketBody(serverReader, packLogin7);
      // OptionFlags2 must request integrated security
      expect(login7[25] & fIntSecurity, equals(fIntSecurity));
      // SSPI offset/len @78
      final sspiOff = readUint16LE(login7, 78);
      final sspiLen = readUint16LE(login7, 80);
      expect(sspiLen, greaterThan(0));
      expect(login7[sspiOff], equals(0x4E)); // 'N' of NTLMSSP

      pair.server.add(tdsPacket(type: packReply, body: _sspiToken(type2)));
      await pair.server.flush();

      final sspiPkt = await _readPacketBody(serverReader, packSSPIMessage);
      expect(sspiPkt[8], equals(3)); // NTLM Type 3 message type
      final challenge = NtlmChallenge.parse(type2);
      final expected = ntlm.authenticateMessage(
        challenge,
        // Can't match random client challenge — just check Type 3 shape above.
      );
      expect(sspiPkt.length, greaterThan(64));
      expect(expected.length, greaterThan(64));

      pair.server.add(tdsPacket(
        type: packReply,
        body: _loginAckDone(
          progName: 'Microsoft SQL Server',
          database: 'master',
        ),
      ));
      await pair.server.flush();
    }();

    final buf = TdsBuffer(pair.client);
    await Prelogin.send(buf, requestEncrypt: encryptNotSupported);
    await Prelogin.read(buf);

    await Login7.send(
      buf,
      LoginConfig(
        host: 'localhost',
        username: '',
        password: '',
        serverName: 'localhost',
        database: 'master',
        sspi: ntlm.negotiateMessage(),
      ),
    );

    final result = await TokenStream(buf).processLoginResponse(
      onSspi: (challengeBytes) async {
        final challenge = NtlmChallenge.parse(challengeBytes);
        return ntlm.authenticateMessage(challenge);
      },
    );

    await serverDone;
    expect(result.serverVersion, equals('Microsoft SQL Server'));
    expect(result.database, equals('master'));
  });

  test('tokenSSPI without onSspi throws StateError', () async {
    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);

    final type2 = _type2Challenge(
      serverChallenge: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      targetName: 'DOMAIN',
      targetInfo: Uint8List.fromList([0, 0, 0, 0]),
    );
    await tdsSend(pair.server, tdsPacket(type: packReply, body: _sspiToken(type2)));

    final buf = TdsBuffer(pair.client);
    await expectLater(
      TokenStream(buf).processLoginResponse(),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('SSPI'),
      )),
    );
  });
}
