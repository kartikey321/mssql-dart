import 'dart:io';
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

/// End-to-end mock handshake: PreLogin → Login7 → LOGINACK (no live SQL).
///
/// Combines patterns from:
/// - go-mssqldb `bad_server_test.go` / `goodPreloginSequence`
/// - go-mssqldb login ack + ENVCHANGE token handling
/// - ms-tds connection sequence §2.2.1
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

Future<void> _readPacket(
    ChunkedStreamReader<int> reader, int expectType) async {
  final hdr = await reader.readChunk(headerSize);
  expect(hdr[0], equals(expectType));
  final size = (hdr[2] << 8) | hdr[3];
  final bodyLen = size - headerSize;
  if (bodyLen > 0) {
    final body = await reader.readChunk(bodyLen);
    expect(body.length, equals(bodyLen));
  }
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

Uint8List _infoToken(String message) {
  final msg = ucs2(message);
  final payload = BytesBuilder(copy: false);
  writeUint32LE(payload, 0);
  payload.addByte(0);
  payload.addByte(0);
  writeUint16LE(payload, message.length);
  payload.add(msg);
  payload.addByte(0);
  payload.addByte(0);
  writeUint32LE(payload, 0);

  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenInfo);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

void main() {
  test('PreLogin → Login7 → LOGINACK handshake (encrypt not supported)',
      () async {
    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);
    final serverReader = ChunkedStreamReader(pair.server);

    final serverDone = () async {
      // 1. Drain PRELOGIN, reply encryptNotSupported
      await _readPacket(serverReader, packPrelogin);
      pair.server.add(tdsPacket(
        type: packReply,
        body: _preloginBody({
          preloginEncryption: [encryptNotSupported],
        }),
      ));
      await pair.server.flush();

      // 2. Drain LOGIN7, reply LOGINACK + ENVCHANGE + DONE
      await _readPacket(serverReader, packLogin7);
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
    final pre = await Prelogin.read(buf);
    expect(pre.requiresTls, isFalse);

    await Login7.send(
      buf,
      const LoginConfig(
        host: 'localhost',
        username: 'sa',
        password: 'Secret1',
        serverName: 'localhost',
        database: 'master',
      ),
    );

    final login = await TokenStream(buf).processLoginResponse();
    expect(login.serverVersion, equals('Microsoft SQL Server'));
    expect(login.database, equals('master'));

    await serverDone;
  });

  test('protocol limit violation closes connection', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);

    final serverDone = () async {
      final server = await listener.first;
      try {
        final serverReader = ChunkedStreamReader(server);

        await _readPacket(serverReader, packPrelogin);
        server.add(tdsPacket(
          type: packReply,
          body: _preloginBody({
            preloginEncryption: [encryptNotSupported],
          }),
        ));
        await server.flush();

        await _readPacket(serverReader, packLogin7);
        server.add(tdsPacket(
          type: packReply,
          body: _loginAckDone(
            progName: 'Microsoft SQL Server',
            database: 'master',
          ),
        ));
        await server.flush();

        await _readPacket(serverReader, packSQLBatch);
        server.add(tdsPacket(
          type: packReply,
          body: _infoToken('this info token is intentionally too large'),
        ));
        await server.flush();
      } finally {
        server.destroy();
      }
    }();

    final conn = await MssqlConnection.connect(
      host: InternetAddress.loopbackIPv4.address,
      port: listener.port,
      user: 'sa',
      password: 'Secret1',
      database: 'master',
      encrypt: false,
      protocolLimits: const MssqlProtocolLimits(maximumTokenBytes: 64),
    );
    addTearDown(conn.close);

    await expectLater(
      conn.query('SELECT 1'),
      throwsA(isA<MssqlProtocolLimitException>()),
    );
    expect(conn.isOpen, isFalse);

    await serverDone;
  });
}
