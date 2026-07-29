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

/// Mock Azure AD FedAuth login: PreLogin(fedAuth) → Login7(FeatureExt) →
/// FEATUREEXTACK + LOGINACK.
///
/// Sources: go-mssqldb fedauth / FEATUREEXTACK; ms-tds §2.2.6.3 FeatureExt,
/// §2.2.7.11 FEATUREEXTACK; Tedious azure-active-directory-access-token.

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

Uint8List _featureExtAck({int featureId = featExtFedAuth}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenFeatureExtAck);
  out.addByte(featureId);
  writeUint32LE(out, 2);
  out.add([0x00, 0x00]);
  out.addByte(featExtTerminator);
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

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// FEDAUTHINFO token (ms-tds §2.2.7.12 / go-mssqldb parseFedAuthInfo).
Uint8List _fedAuthInfoToken({
  required String stsUrl,
  required String serverSpn,
}) {
  final sts = ucs2(stsUrl);
  final spn = ucs2(serverSpn);
  const headerLen = 4 + 2 * 9; // count + two (id+len+off)
  final size = headerLen + sts.length + spn.length;
  final out = BytesBuilder(copy: false);
  out.addByte(tokenFedAuthInfo);
  writeUint32LE(out, size);
  writeUint32LE(out, 2); // option count
  out.addByte(fedAuthInfoStsUrl);
  writeUint32LE(out, sts.length);
  writeUint32LE(out, headerLen);
  out.addByte(fedAuthInfoSpn);
  writeUint32LE(out, spn.length);
  writeUint32LE(out, headerLen + sts.length);
  out.add(sts);
  out.add(spn);
  return Uint8List.fromList(out.toBytes());
}

void main() {
  test('PreLogin → Login7(FedAuth) → FEATUREEXTACK → LOGINACK', () async {
    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);
    final serverReader = ChunkedStreamReader(pair.server);

    const token = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.fake.sig';
    final tokenUcs2 = ucs2(token);

    final serverDone = () async {
      await _readPacketBody(serverReader, packPrelogin);
      pair.server.add(tdsPacket(
        type: packReply,
        body: _preloginBody({
          preloginEncryption: [encryptNotSupported],
          preloginFedAuthRequired: [0x01],
        }),
      ));
      await pair.server.flush();

      final login7 = await _readPacketBody(serverReader, packLogin7);
      expect(login7[27] & fExtension, equals(fExtension));

      final featOff = readUint16LE(login7, 56);
      final featLen = readUint16LE(login7, 58);
      expect(featOff, greaterThan(0));
      expect(featLen, greaterThan(0));
      final feat = login7.sublist(featOff, featOff + featLen);
      expect(feat[0], equals(featExtFedAuth));
      expect(feat.last, equals(featExtTerminator));
      expect(_containsBytes(feat, tokenUcs2), isTrue);

      // FEATUREEXTACK then LOGINACK in one reply (common Azure SQL shape).
      pair.server.add(tdsPacket(
        type: packReply,
        body: Uint8List.fromList([
          ..._featureExtAck(),
          ..._loginAckDone(
            progName: 'Microsoft SQL Azure',
            database: 'appdb',
          ),
        ]),
      ));
      await pair.server.flush();
    }();

    final buf = TdsBuffer(pair.client);
    await Prelogin.send(
      buf,
      requestEncrypt: encryptNotSupported,
      fedAuthRequired: true,
    );
    final pre = await Prelogin.read(buf);
    expect(pre.fedAuthRequired, isTrue);
    expect(pre.requiresTls, isFalse);

    await Login7.send(
      buf,
      LoginConfig(
        host: 'myserver.database.windows.net',
        username: '',
        password: '',
        serverName: 'myserver.database.windows.net',
        database: 'appdb',
        fedAuthToken: token,
      ),
    );

    final result = await TokenStream(buf).processLoginResponse();
    await serverDone;

    expect(result.serverVersion, equals('Microsoft SQL Azure'));
    expect(result.database, equals('appdb'));
  });

  test('AzureAdAuth.fromToken feeds Login7 FedAuth path', () async {
    // Sanity: public auth helper used by connectAzureAd / pool azureAd.
    final auth = AzureAdAuth.fromToken('preacquired-token');
    expect(auth.bearerToken, equals('preacquired-token'));

    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);
    final serverReader = ChunkedStreamReader(pair.server);

    final serverDone = () async {
      await _readPacketBody(serverReader, packPrelogin);
      pair.server.add(tdsPacket(
        type: packReply,
        body: _preloginBody({
          preloginEncryption: [encryptNotSupported],
          preloginFedAuthRequired: [0x01],
        }),
      ));
      await pair.server.flush();

      final login7 = await _readPacketBody(serverReader, packLogin7);
      expect(_containsBytes(login7, ucs2(auth.bearerToken)), isTrue);

      pair.server.add(tdsPacket(
        type: packReply,
        body: Uint8List.fromList([
          ..._featureExtAck(),
          ..._loginAckDone(
            progName: 'Microsoft SQL Azure',
            database: 'master',
          ),
        ]),
      ));
      await pair.server.flush();
    }();

    final buf = TdsBuffer(pair.client);
    await Prelogin.send(
      buf,
      requestEncrypt: encryptNotSupported,
      fedAuthRequired: true,
    );
    await Prelogin.read(buf);
    await Login7.send(
      buf,
      LoginConfig(
        host: 'localhost',
        username: '',
        password: '',
        serverName: 'localhost',
        database: 'master',
        fedAuthToken: auth.bearerToken,
      ),
    );
    final result = await TokenStream(buf).processLoginResponse();
    await serverDone;
    expect(result.database, equals('master'));
  });

  test('FEDAUTHINFO → packFedAuthToken → LOGINACK (ADAL-style)', () async {
    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);
    final serverReader = ChunkedStreamReader(pair.server);

    const sts = 'https://login.windows.net/common';
    const spn = 'MSSQLSvc/myserver.database.windows.net:1433';
    const accessToken = 'adal-access-token';

    final serverDone = () async {
      // Client may send PreLogin first in full flows; here we only drive login
      // response tokens after Login7 was already "sent" conceptually — feed
      // FEDAUTHINFO then wait for FEDAUTHTOKEN, then LOGINACK.
      pair.server.add(tdsPacket(
        type: packReply,
        body: _fedAuthInfoToken(stsUrl: sts, serverSpn: spn),
      ));
      await pair.server.flush();

      final fed = await _readPacketBody(serverReader, packFedAuthToken);
      expect(fed.length, greaterThan(8));
      final tokenLen = readUint32LE(fed, 4);
      expect(tokenLen, equals(accessToken.length * 2));
      expect(
        fed.sublist(8, 8 + tokenLen),
        equals(ucs2(accessToken)),
      );

      pair.server.add(tdsPacket(
        type: packReply,
        body: Uint8List.fromList([
          ..._featureExtAck(),
          ..._loginAckDone(
            progName: 'Microsoft SQL Azure',
            database: 'appdb',
          ),
        ]),
      ));
      await pair.server.flush();
    }();

    final buf = TdsBuffer(pair.client);
    FedAuthInfo? seen;
    final result = await TokenStream(buf).processLoginResponse(
      onFedAuthInfo: (info) async {
        seen = info;
        return accessToken;
      },
    );
    await serverDone;

    expect(seen!.stsUrl, equals(sts));
    expect(seen!.serverSpn, equals(spn));
    expect(result.database, equals('appdb'));
  });

  test('FEDAUTHINFO without handler is skipped', () async {
    final pair = await TdsSocketPair.open();
    addTearDown(pair.close);

    pair.server.add(tdsPacket(
      type: packReply,
      body: Uint8List.fromList([
        ..._fedAuthInfoToken(
          stsUrl: 'https://login.windows.net/common',
          serverSpn: 'MSSQLSvc/x',
        ),
        ..._loginAckDone(
          progName: 'Microsoft SQL Azure',
          database: 'master',
        ),
      ]),
    ));
    await pair.server.flush();

    final buf = TdsBuffer(pair.client);
    final result = await TokenStream(buf).processLoginResponse();
    expect(result.database, equals('master'));
  });
}
