import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/login7.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Golden Login7 encoding tests.
///
/// Sources:
/// - ms-tds §2.2.6.3 LOGIN7
/// - microsoft/go-mssqldb / denisenkom `tds_login_test.go` hex fixtures
///   (fixed header, offset/length table, password mangling)
/// - FedAuth feature extension layout from go-mssqldb fedauth feature blocks
Future<Uint8List> _captureLogin7Body(LoginConfig cfg) async {
  final pair = await TdsSocketPair.open();
  final completer = Completer<Uint8List>();
  final chunks = BytesBuilder(copy: false);

  pair.server.listen((data) {
    chunks.add(data);
    final all = chunks.toBytes();
    if (all.length >= headerSize) {
      final size = (all[2] << 8) | all[3];
      if (all.length >= size && !completer.isCompleted) {
        completer.complete(Uint8List.fromList(all.sublist(headerSize, size)));
      }
    }
  });

  final buf = TdsBuffer(pair.client);
  await Login7.send(buf, cfg);
  final body = await completer.future.timeout(const Duration(seconds: 2));
  await pair.close();
  return body;
}

String _ucs2At(List<int> body, int byteOffset, int charCount) {
  final bytes = body.sublist(byteOffset, byteOffset + charCount * 2);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2)
      bytes[i] | (bytes[i + 1] << 8),
  ]);
}

void main() {
  const host = 'localhost';
  const user = 'sa';
  const pass = 'Secret1';
  const server = 'localhost';
  const database = 'master';
  const appName = 'mssql-dart';

  group('Login7 encoding', () {
    late Uint8List body;

    setUpAll(() async {
      body = await _captureLogin7Body(const LoginConfig(
        host: host,
        username: user,
        password: pass,
        appName: appName,
        serverName: server,
        database: database,
        packetSize: defaultPacketSize,
      ));
    });

    // go-mssqldb login header: Length, TDSVersion, PacketSize, OptionFlags*
    test('fixed header: length, TDS 7.4, packet size, option flags', () {
      expect(readUint32LE(body, 0), equals(body.length));
      expect(readUint32LE(body, 4), equals(verTDS74));
      expect(readUint32LE(body, 8), equals(defaultPacketSize));
      expect(body[24], equals(fUseDB | fSetLang)); // OptionFlags1
      expect(body[25], equals(fODBC)); // OptionFlags2 (SQL auth)
      expect(body[26], equals(0)); // TypeFlags — no ReadOnlyIntent
      expect(body[27], equals(0)); // OptionFlags3 — no feature ext
      expect(readUint32LE(body, 32), equals(0x0409)); // ClientLCID en-US
    });

    test('ApplicationIntent ReadOnly sets TypeFlags fReadOnlyIntent', () async {
      final body = await _captureLogin7Body(const LoginConfig(
        host: host,
        username: user,
        password: pass,
        serverName: server,
        database: database,
        readOnlyIntent: true,
      ));
      expect(body[26], equals(fReadOnlyIntent));
    });

    test('hostname / username / database land at declared offsets', () {
      final hostOff = readUint16LE(body, 36);
      final hostLen = readUint16LE(body, 38);
      final userOff = readUint16LE(body, 40);
      final userLen = readUint16LE(body, 42);
      final dbOff = readUint16LE(body, 68);
      final dbLen = readUint16LE(body, 70);

      expect(hostLen, equals(host.length));
      expect(userLen, equals(user.length));
      expect(dbLen, equals(database.length));
      expect(_ucs2At(body, hostOff, hostLen), equals(host));
      expect(_ucs2At(body, userOff, userLen), equals(user));
      expect(_ucs2At(body, dbOff, dbLen), equals(database));
    });

    // ms-tds §2.2.6.3 / go-mssqldb manglePassword — not plaintext UCS-2
    test('password is obfuscated, not plaintext UCS-2', () {
      final passOff = readUint16LE(body, 44);
      final passLen = readUint16LE(body, 46);
      expect(passLen, equals(pass.length));

      final onWire = body.sublist(passOff, passOff + passLen * 2);
      final plaintext = ucs2(pass);
      final expected = obfuscatePassword(plaintext);

      expect(onWire, isNot(equals(plaintext)));
      expect(onWire, equals(expected));
    });

    test('app name and server name match config', () {
      final appOff = readUint16LE(body, 48);
      final appLen = readUint16LE(body, 50);
      final serverOff = readUint16LE(body, 52);
      final serverLen = readUint16LE(body, 54);

      expect(_ucs2At(body, appOff, appLen), equals(appName));
      expect(_ucs2At(body, serverOff, serverLen), equals(server));
    });
  });

  group('Login7 FedAuth feature extension', () {
    // go-mssqldb FedAuth feature extension (featExtFedAuth) block layout
    test('sets OptionFlags3 fExtension and embeds token', () async {
      const token = 'bearer-token-xyz';
      final body = await _captureLogin7Body(const LoginConfig(
        host: host,
        username: '',
        password: '',
        serverName: server,
        database: database,
        fedAuthToken: token,
      ));

      expect(body[27] & fExtension, equals(fExtension));

      final featOff = readUint16LE(body, 56);
      final featLen = readUint16LE(body, 58);
      expect(featOff, greaterThan(0));
      expect(featLen, greaterThan(0));

      final feat = body.sublist(featOff, featOff + featLen);
      expect(feat[0], equals(featExtFedAuth));
      final tokenBytes = ucs2(token);
      var found = false;
      for (var i = 0; i <= feat.length - tokenBytes.length; i++) {
        var match = true;
        for (var j = 0; j < tokenBytes.length; j++) {
          if (feat[i + j] != tokenBytes[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          found = true;
          break;
        }
      }
      expect(found, isTrue, reason: 'FedAuth token missing from feature ext');
      expect(feat.last, equals(featExtTerminator));
    });

    // ms-tds §2.2.6.3 FeatureExt FedAuth: FeatureID + DataLen + options + tokenLen
    test('FedAuth feature data: SecurityToken library + UCS-2 token length',
        () async {
      const token = 'tok';
      final body = await _captureLogin7Body(const LoginConfig(
        host: host,
        username: '',
        password: '',
        serverName: server,
        fedAuthToken: token,
      ));

      final featOff = readUint16LE(body, 56);
      final featLen = readUint16LE(body, 58);
      final feat = body.sublist(featOff, featOff + featLen);

      expect(feat[0], equals(featExtFedAuth));
      final dataLen = readUint32LE(feat, 1);
      expect(dataLen, equals(5 + token.length * 2));
      expect(feat[5], equals(fedAuthLibSecurityToken << 1)); // options
      expect(readUint32LE(feat, 6), equals(token.length * 2));
      expect(
        feat.sublist(10, 10 + token.length * 2),
        equals(ucs2(token)),
      );
      expect(feat[10 + token.length * 2], equals(featExtTerminator));
    });
  });

  group('Login7 SSPI / integrated security', () {
    // go-mssqldb tds.go Login7 SSPI field; OptionFlags2 fIntSecurity
    test('SSPI blob sets fIntSecurity and lands at declared byte offset',
        () async {
      final sspi = Uint8List.fromList([0x4E, 0x54, 0x4C, 0x4D, 0x01, 0x02]);
      final body = await _captureLogin7Body(LoginConfig(
        host: host,
        username: '',
        password: '',
        serverName: server,
        database: database,
        sspi: sspi,
      ));

      expect(body[25] & fIntSecurity, equals(fIntSecurity));
      expect(body[25] & fODBC, equals(0));

      // After ClientID @72 (6 bytes): SSPI off/len @78, SSPILongLength @90
      final sspiOff = readUint16LE(body, 78);
      final sspiLen = readUint16LE(body, 80);
      expect(sspiLen, equals(sspi.length)); // byte length, not char count
      expect(body.sublist(sspiOff, sspiOff + sspiLen), equals(sspi));
      expect(readUint32LE(body, 90), equals(0)); // SSPILongLength
    });
  });
}
