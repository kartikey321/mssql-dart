import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Crafted token-stream packets for [TokenStream].
///
/// Sources:
/// - microsoft/go-mssqldb `token.go` parsers (ERROR, DONE, LOGINACK, ENVCHANGE,
///   COLMETADATA, ROW, NBCROW, ORDER, RETURNVALUE, FEATUREEXTACK)
/// - Tedious `test/unit/token/*-token-parser-test.ts`
/// - ms-tds §2.2.7 token stream grammar

Uint8List _errorToken({
  required int number,
  required String message,
  int state = 1,
  int clazz = 16,
}) {
  final msg = ucs2(message);
  final payload = BytesBuilder(copy: false);
  writeUint32LE(payload, number);
  payload.addByte(state);
  payload.addByte(clazz);
  writeUint16LE(payload, message.length);
  payload.add(msg);
  // serverName B_VARCHAR empty, procName empty, lineNumber
  payload.addByte(0);
  payload.addByte(0);
  writeUint32LE(payload, 1);

  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenError);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _infoToken(String message) {
  // Same shape as ERROR but tokenInfo — skipped by query/login parsers.
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

Uint8List _doneToken({
  int flags = doneFlagFinal,
  int curCmd = 0,
  int rowCount = 0,
}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenDone);
  writeUint16LE(out, flags);
  writeUint16LE(out, curCmd);
  writeUint64LE(out, rowCount);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _loginAckToken(String progName) {
  final name = ucs2(progName);
  final data = BytesBuilder(copy: false);
  data.addByte(1); // interface
  // TDS version BE-ish bytes (parser does not interpret them)
  data.add([0x74, 0x00, 0x00, 0x04]);
  data.addByte(progName.length);
  data.add(name);
  writeUint32LE(data, 0x01000000); // prog version

  final bytes = data.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenLoginAck);
  writeUint16LE(out, bytes.length);
  out.add(bytes);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangeDatabase(String newDb, String oldDb) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envDatabase);
  payload.addByte(newDb.length);
  payload.add(ucs2(newDb));
  payload.addByte(oldDb.length);
  payload.add(ucs2(oldDb));

  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

/// COLMETADATA for a single INT4 column named [name].
Uint8List _colMetaInt(String name) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1); // column count
  writeUint32LE(out, 0); // userType
  writeUint16LE(out, 0); // flags
  out.addByte(typeInt4);
  out.addByte(name.length);
  out.add(ucs2(name));
  return Uint8List.fromList(out.toBytes());
}

/// COLMETADATA for two INTN (nullable INT) columns.
Uint8List _colMetaTwoNullableInts(String a, String b) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 2);
  for (final name in [a, b]) {
    writeUint32LE(out, 0);
    writeUint16LE(out, 1); // nullable
    out.addByte(typeIntN);
    out.addByte(4); // MaxLen
    out.addByte(name.length);
    out.add(ucs2(name));
  }
  return Uint8List.fromList(out.toBytes());
}

Uint8List _rowInt(int value) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenRow);
  writeUint32LE(out, value);
  return Uint8List.fromList(out.toBytes());
}

/// NBCROW: first column null, second column = [value].
Uint8List _nbcRowSecondInt(int value) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenNbcRow);
  out.addByte(0x01); // bitmap: bit0 set → col0 null
  // col1 present: BYTELEN INTN → len 4 + int32
  out.addByte(4);
  writeUint32LE(out, value);
  return Uint8List.fromList(out.toBytes());
}

/// COLMETADATA for [count] nullable INTN columns named c0..c{n-1}.
Uint8List _colMetaNullableInts(int count) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, count);
  for (var i = 0; i < count; i++) {
    final name = 'c$i';
    writeUint32LE(out, 0);
    writeUint16LE(out, 1); // nullable
    out.addByte(typeIntN);
    out.addByte(4);
    out.addByte(name.length);
    out.add(ucs2(name));
  }
  return Uint8List.fromList(out.toBytes());
}

/// 9-col NBCROW: null,1,null,2,null,3,null,4,null — spans bitmap byte boundary.
Uint8List _nbcRowNineColBoundary() {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenNbcRow);
  // bits 0..7: 1,0,1,0,1,0,1,0 → 0x55; bit 8 null → second byte 0x01
  out.addByte(0x55);
  out.addByte(0x01);
  for (final v in [1, 2, 3, 4]) {
    out.addByte(4);
    writeUint32LE(out, v);
  }
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangePacketSize(String size) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envPacketSize);
  payload.addByte(size.length);
  payload.add(ucs2(size));
  payload.addByte(size.length);
  payload.add(ucs2(size));
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangeBeginTran(int descriptor) {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envBeginTran);
  payload.addByte(8); // new value length
  for (var i = 0; i < 8; i++) {
    payload.addByte((descriptor >> (i * 8)) & 0xFF);
  }
  payload.addByte(0); // old empty
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _envChangeCommitTran() {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envCommitTran);
  payload.addByte(0);
  payload.addByte(0);
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _orderToken() {
  // One column ordinal (1) — skipped by parser.
  final data = [0x01, 0x00];
  final out = BytesBuilder(copy: false);
  out.addByte(tokenOrder);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _returnValueInt({required String name, required int value}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenReturnValue);
  writeUint16LE(out, 1); // ordinal
  out.addByte(name.length);
  out.add(ucs2(name));
  out.addByte(0x01); // status OUTPUT
  writeUint32LE(out, 0); // userType
  writeUint16LE(out, 0); // flags
  out.addByte(typeIntN);
  out.addByte(4); // MaxLen
  out.addByte(4); // value len
  writeUint32LE(out, value);
  return Uint8List.fromList(out.toBytes());
}

Uint8List _featureExtAck({int featureId = featExtFedAuth}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenFeatureExtAck);
  out.addByte(featureId);
  writeUint32LE(out, 2); // feature data len
  out.add([0x00, 0x00]);
  out.addByte(featExtTerminator);
  return Uint8List.fromList(out.toBytes());
}

/// Multi-part TableName after TEXT/NTEXT/IMAGE TYPE_INFO (ms-tds §2.2.7.4).
void _writeTableName(BytesBuilder out, List<String> parts) {
  out.addByte(parts.length);
  for (final part in parts) {
    writeUint16LE(out, part.length);
    out.add(ucs2(part));
  }
}

List<int> get _zeroCollation => [0, 0, 0, 0, 0];

/// COLMETADATA for one TEXT/NTEXT/IMAGE column with optional TableName parts.
Uint8List _colMetaLegacyLob(
  int typeId,
  String name, {
  List<String> tableParts = const [],
}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1);
  writeUint32LE(out, 0); // userType
  writeUint16LE(out, 0); // flags
  out.addByte(typeId);
  writeUint32LE(out, 0x7FFFFFFF); // MaxLen
  if (typeId == typeText || typeId == typeNText) {
    out.add(_zeroCollation);
  }
  _writeTableName(out, tableParts);
  out.addByte(name.length);
  out.add(ucs2(name));
  return Uint8List.fromList(out.toBytes());
}

/// ROW for TEXT/NTEXT/IMAGE: textPtr + timestamp + LONGLEN data (or null).
Uint8List _rowLegacyLob(List<int> data, {bool isNull = false}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenRow);
  if (isNull) {
    out.addByte(0); // textPtrLen 0 → NULL
    return Uint8List.fromList(out.toBytes());
  }
  out.addByte(16); // text pointer length
  out.add(List.filled(16, 0x11));
  out.add(List.filled(8, 0x22)); // timestamp
  writeUint32LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

/// ENVCHANGE type 20 (routing) — binary payload, not B_VARCHAR strings.
Uint8List _envChangeRouting({
  String server = 'x',
  int port = 1433,
}) {
  // go-mssqldb / ms-tds §2.2.7.9: Protocol + Port + Hostname US_VARCHAR.
  final name = ucs2(server);
  final routingValueLen = 1 + 2 + 2 + name.length; // proto+port+len+chars
  final payload = BytesBuilder(copy: false);
  payload.addByte(envRouting);
  writeUint16LE(payload, routingValueLen);
  payload.addByte(0); // Protocol TCP
  writeUint16LE(payload, port);
  writeUint16LE(payload, server.length);
  payload.add(name);
  writeUint16LE(payload, 0); // OLDVALUE = 0x00 0x00
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

/// ENVCHANGE type 7 (SQL collation) — 5-byte binary new/old values.
Uint8List _envChangeSqlCollation() {
  final payload = BytesBuilder(copy: false);
  payload.addByte(envSqlCollation);
  payload.addByte(5);
  payload.add([0x09, 0x04, 0xD0, 0x00, 0x34]); // new
  payload.addByte(5);
  payload.add([0, 0, 0, 0, 0]); // old
  final data = payload.toBytes();
  final out = BytesBuilder(copy: false);
  out.addByte(tokenEnvChange);
  writeUint16LE(out, data.length);
  out.add(data);
  return Uint8List.fromList(out.toBytes());
}

typedef _Fed = ({TdsBuffer buf, TdsSocketPair pair});

Future<_Fed> _openWithBody(
  List<int> body, {
  MssqlProtocolLimits limits = MssqlProtocolLimits.unlimited,
}) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  return (buf: TdsBuffer(pair.client, limits: limits), pair: pair);
}

/// Sends one final reply packet then closes the peer, so truncated parses fail
/// rather than waiting for another packet indefinitely.
Future<_Fed> _openClosedWithBody(List<int> body) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  await pair.server.close();
  return (buf: TdsBuffer(pair.client), pair: pair);
}

Future<void> _expectPromptRejection(Future<Object?> parse) async {
  try {
    await parse.timeout(const Duration(milliseconds: 250));
    fail('expected malformed protocol input to be rejected');
  } on TimeoutException {
    fail('parser did not reject malformed protocol input promptly');
  } catch (_) {}
}

/// Multi-packet reply (EOM only on last) — PR #3 / go-mssqldb multi-packet reads.
Future<_Fed> _openWithPackets(List<List<int>> bodies) async {
  final pair = await TdsSocketPair.open();
  for (var i = 0; i < bodies.length; i++) {
    await tdsSend(
      pair.server,
      tdsPacket(
        type: packReply,
        body: bodies[i],
        eom: i == bodies.length - 1,
        seq: i + 1,
      ),
    );
  }
  return (buf: TdsBuffer(pair.client), pair: pair);
}

/// COLMETADATA for a single NVARCHAR column (fixed MaxLen, collation zeros).
Uint8List _colMetaNVarChar(String name, {int maxLen = 100}) {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenColMetadata);
  writeUint16LE(out, 1);
  writeUint32LE(out, 0);
  writeUint16LE(out, 0);
  out.addByte(typeNVarChar);
  writeUint16LE(out, maxLen);
  out.add([0, 0, 0, 0, 0]); // collation
  out.addByte(name.length);
  out.add(ucs2(name));
  return Uint8List.fromList(out.toBytes());
}

void main() {
  group('TokenStream login response', () {
    // go-mssqldb parseLoginAck + ENVCHANGE database; Tedious loginack-token-parser
    test('LOGINACK + ENVCHANGE database + DONE', () async {
      final body = [
        ..._loginAckToken('Microsoft SQL Server'),
        ..._envChangeDatabase('master', 'master'),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processLoginResponse();
      expect(result.serverVersion, equals('Microsoft SQL Server'));
      expect(result.database, equals('master'));
    });

    test('ERROR during login throws MssqlException', () async {
      final body = [
        ..._errorToken(number: 18456, message: 'Login failed'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processLoginResponse(),
        throwsA(isA<MssqlException>()
            .having((e) => e.errorCode, 'errorCode', 18456)
            .having((e) => e.message, 'message', contains('Login failed'))),
      );
    });

    // go-mssqldb FEATUREEXTACK skip + ENVCHANGE packet size
    test('FeatureExtAck is skipped; packet-size ENVCHANGE applied', () async {
      final body = [
        ..._loginAckToken('SQL Server'),
        ..._featureExtAck(),
        ..._envChangePacketSize('8192'),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processLoginResponse();
      expect(result.serverVersion, equals('SQL Server'));
      expect(result.packetSize, equals(8192));
    });

    test('malformed LOGINACK is rejected', () async {
      final body = [
        tokenLoginAck,
        1, 0, // body length
        0x00,
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processLoginResponse(),
        throwsA(isA<FormatException>()),
      );
    });

    test('malformed FEDAUTHINFO option table is rejected', () async {
      final body = [
        tokenFedAuthInfo,
        4, 0, 0, 0, // size only contains option count
        1, 0, 0, 0, // count requires a 9-byte option entry
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processLoginResponse(),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('TokenStream query response', () {
    // Tedious row-token-parser / go-mssqldb COLMETADATA+ROW
    test('COLMETADATA + ROW + DONE returns one row', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(42),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('n'));
      expect(
          result.rows,
          equals([
            [42]
          ]));
      expect(result.rowsAffected, equals(1));
    });

    // Tedious nbcrow-token-parser-test / go-mssqldb NBCROW bitmap
    test('COLMETADATA + NBCROW null bitmap', () async {
      final body = [
        ..._colMetaTwoNullableInts('a', 'b'),
        ..._nbcRowSecondInt(99),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([null, 99]));
    });

    test('INFO then ERROR then DONE surfaces error', () async {
      final body = [
        ..._infoToken('ignored info'),
        ..._errorToken(number: 208, message: 'Invalid object name'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<MssqlException>()
            .having((e) => e.errorCode, 'errorCode', 208)
            .having((e) => e.message, 'message', contains('Invalid object'))
            .having((e) => e.severity, 'severity', 16)
            .having((e) => e.state, 'state', 1)
            .having((e) => e.lineNo, 'lineNo', 1)),
      );
    });

    // go-mssqldb parseInfo; Tedious infoMessage event
    test('INFO token invokes onInfoMessage with full fields', () async {
      MssqlInfoMessage? seen;
      final body = [
        ..._infoToken('hello print'),
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(
        fed.buf,
        onInfoMessage: (info) => seen = info,
      ).processQueryResponse();
      expect(result.rows.single, equals([1]));
      expect(seen, isNotNull);
      expect(seen!.message, equals('hello print'));
      expect(seen!.isError, isFalse);
    });

    // go-mssqldb doneStruct multi-error aggregation pattern
    test('two ERROR tokens populate precedingErrors', () async {
      final body = [
        ..._errorToken(number: 1, message: 'error 1'),
        ..._errorToken(number: 2, message: 'error 2'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      try {
        await TokenStream(fed.buf).processQueryResponse();
        fail('expected MssqlException');
      } on MssqlException catch (e) {
        expect(e.message, contains('error 2'));
        expect(e.errorCode, equals(2));
        expect(e.precedingErrors.length, equals(2));
        expect(e.precedingErrors[0].message, contains('error 1'));
        expect(e.precedingErrors[1].message, contains('error 2'));
      }
    });

    // ms-tds DONE.status DONE_MORE; multi-result batches (node-mssql / go-mssqldb)
    test('multiple result sets via DONE MORE', () async {
      final body = [
        ..._colMetaInt('a'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagMore | doneFlagCount, rowCount: 1),
        ..._colMetaInt('b'),
        ..._rowInt(2),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final sets = await TokenStream(fed.buf).processAllQueryResponses();
      expect(sets.length, equals(2));
      expect(sets[0].columns.single.name, equals('a'));
      expect(sets[0].rows.single, equals([1]));
      expect(sets[1].columns.single.name, equals('b'));
      expect(sets[1].rows.single, equals([2]));
    });

    test('token body length respects maximumTokenBytes', () async {
      final body = [
        ..._infoToken('too large'),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(
        body,
        limits: const MssqlProtocolLimits(maximumTokenBytes: 4),
      );
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });

    test('malformed ENVCHANGE empty body is rejected', () async {
      final body = [
        tokenEnvChange,
        0, 0, // empty token body has no ENVCHANGE type byte
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<FormatException>()),
      );
    });

    test('malformed INFO body is rejected', () async {
      final body = [
        tokenInfo,
        8, 0, // header says one UTF-16 char but omits message bytes
        0, 0, 0, 0, // number
        0, // state
        0, // class
        1, 0, // message length
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<FormatException>()),
      );
    });

    test('COLMETADATA count respects maximumColumns', () async {
      final body = [
        ..._colMetaTwoNullableInts('a', 'b'),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(
        body,
        limits: const MssqlProtocolLimits(maximumColumns: 1),
      );
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });

    test('result set count respects maximumResultSets', () async {
      final body = [
        ..._colMetaInt('a'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagMore | doneFlagCount, rowCount: 1),
        ..._colMetaInt('b'),
        ..._rowInt(2),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(
        body,
        limits: const MssqlProtocolLimits(maximumResultSets: 1),
      );
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processAllQueryResponses(),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });

    // Tedious order-token-parser — must not desync stream
    test('ORDER token is skipped between COLMETADATA and ROW', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._orderToken(),
        ..._rowInt(5),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([5]));
    });

    // ms-tds §2.2.7.15 RETURNVALUE; go-mssqldb / tedious OUTPUT params
    test('RETURNVALUE token is captured into lastReturnValues', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ..._returnValueInt(name: '@out', value: 99),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final ts = TokenStream(fed.buf);
      final result = await ts.processQueryResponse();
      expect(result.rows.single, equals([1]));
      expect(ts.lastReturnValues['out'], equals(99));
    });

    // ms-tds §2.2.7.16 RETURNSTATUS; go-mssqldb parseReturnStatus
    test('RETURNSTATUS token is captured as signed int32', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenReturnStatus);
      writeUint32LE(out, 0xFFFFFF9C); // -100 as uint32 bits
      out.add(_doneToken());
      final fed = await _openWithBody(out.toBytes());
      addTearDown(fed.pair.close);

      final ts = TokenStream(fed.buf);
      await ts.processAllQueryResponses();
      expect(ts.lastReturnStatus, equals(-100));
    });

    // ms-tds ENVCHANGE type 8/9; go-mssqldb transaction descriptor
    test('ENVCHANGE begin/commit updates transactionDescriptor', () async {
      const descriptor = 0x0102030405060708;
      final body = [
        ..._envChangeBeginTran(descriptor),
        ..._doneToken(flags: doneFlagMore),
        ..._envChangeCommitTran(),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      // Drive login-style loop isn't right — use processAllQueryResponses which
      // still parses ENVCHANGE. No COLMETADATA → empty results.
      final sets = await TokenStream(fed.buf).processAllQueryResponses();
      expect(sets, isEmpty);
      // After commit, descriptor cleared.
      expect(fed.buf.transactionDescriptor, equals(0));
    });

    // ms-tds ENVCHANGE type 8 mid-query
    test('ENVCHANGE begin sets transactionDescriptor mid-stream', () async {
      const descriptor = 0x1122334455667788;
      // Query path: begin-tran envchange then a result set.
      final body = [
        ..._envChangeBeginTran(descriptor),
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await TokenStream(fed.buf).processQueryResponse();
      expect(fed.buf.transactionDescriptor, equals(descriptor));
    });

    // go-mssqldb / Tedious: USE → ENVCHANGE database; pool tracks for reset
    test('ENVCHANGE database invokes onDatabaseChanged', () async {
      String? seen;
      final body = [
        ..._envChangeDatabase('tempdb', 'master'),
        ..._colMetaInt('n'),
        ..._rowInt(7),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(
        fed.buf,
        onDatabaseChanged: (db) => seen = db,
      ).processQueryResponse();
      expect(seen, equals('tempdb'));
      expect(result.rows.single, equals([7]));
    });

    // go-mssqldb / node-mssql: INSERT/UPDATE DONE with COUNT, no COLMETADATA
    test('DML-only DONE emits rowsAffected without columns', () async {
      final body = [
        ..._doneToken(flags: doneFlagCount, rowCount: 3),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
      expect(result.rowsAffected, equals(3));
    });

    // ms-tds COLMETADATA count 0xFFFF = no columns (empty result metadata)
    test('empty COLMETADATA (0xFFFF) yields empty columns', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenColMetadata);
      writeUint16LE(out, 0xFFFF);
      final body = [
        ...out.toBytes(),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
    });

    // TokenStream.streamQueryResponse — streaming analogue of Tedious row events
    test('streamQueryResponse yields rows then completes', () async {
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(10),
        ..._rowInt(20),
        ..._doneToken(flags: doneFlagCount, rowCount: 2),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final rows = <int>[];
      await for (final (cols, row)
          in TokenStream(fed.buf).streamQueryResponse()) {
        expect(cols.single.name, equals('n'));
        rows.add(row.single as int);
      }
      expect(rows, equals([10, 20]));
    });

    // streamQueryResponse must still throw on ERROR like buffered path
    test('streamQueryResponse throws on ERROR token', () async {
      final body = [
        ..._errorToken(number: 50000, message: 'boom'),
        ..._doneToken(flags: doneFlagError),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        () async {
          await for (final _ in TokenStream(fed.buf).streamQueryResponse()) {}
        },
        throwsA(isA<MssqlException>()
            .having((e) => e.errorCode, 'errorCode', 50000)),
      );
    });

    // go-mssqldb / tedious: DONE_PROC (0xFE) ends RPC response like DONE
    test('DONE_PROC ends result set like DONE', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenDoneProc);
      writeUint16LE(out, doneFlagCount);
      writeUint16LE(out, 0);
      writeUint64LE(out, 1);
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(7),
        ...out.toBytes(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([7]));
      expect(result.rowsAffected, equals(1));
    });

    // ms-tds §2.2.7.16 RETURNSTATUS — 4-byte status, skipped in query path
    test('RETURNSTATUS is skipped before DONE', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenReturnStatus);
      writeUint32LE(out, 0); // status OK
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(1),
        ...out.toBytes(),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([1]));
    });

    // processQueryResponse keeps first set rows, sums rowsAffected (node-mssql)
    test('processQueryResponse sums rowsAffected across result sets', () async {
      final body = [
        ..._colMetaInt('a'),
        ..._rowInt(1),
        ..._doneToken(flags: doneFlagMore | doneFlagCount, rowCount: 2),
        ..._colMetaInt('b'),
        ..._rowInt(9),
        ..._doneToken(flags: doneFlagCount, rowCount: 5),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('a'));
      expect(result.rows.single, equals([1]));
      expect(result.rowsAffected, equals(7));
    });

    // go-mssqldb / tedious: unexpected token → hard error
    test('unknown token throws StateError', () async {
      final body = [
        0x00, // invalid
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      await expectLater(
        TokenStream(fed.buf).processQueryResponse(),
        throwsA(isA<StateError>()),
      );
    });

    // types_test 9-column NBCROW; Tedious nbcrow bitmap byte boundary
    test('NBCROW 9-column null bitmap spans byte boundary', () async {
      final body = [
        ..._colMetaNullableInts(9),
        ..._nbcRowNineColBoundary(),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(
        result.rows.single,
        equals([null, 1, null, 2, null, 3, null, 4, null]),
      );
    });

    // ms-tds §2.2.7.7 DONE_IN_PROC — same layout as DONE inside RPC
    test('DONE_IN_PROC ends result set like DONE', () async {
      final out = BytesBuilder(copy: false);
      out.addByte(tokenDoneInProc);
      writeUint16LE(out, doneFlagCount);
      writeUint16LE(out, 0);
      writeUint64LE(out, 1);
      final body = [
        ..._colMetaInt('n'),
        ..._rowInt(3),
        ...out.toBytes(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([3]));
      expect(result.rowsAffected, equals(1));
    });

    // ms-tds §2.2.7.4 TableName; tedious colmetadata-token-parser; go-mssqldb types.go
    test('TEXT COLMETADATA multi-part TableName + ROW', () async {
      final body = [
        ..._colMetaLegacyLob(
          typeText,
          'v',
          tableParts: ['db', 'dbo', 'text_t'],
        ),
        ..._rowLegacyLob('hi'.codeUnits),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('v'));
      expect(result.columns.single.typeInfo.typeId, equals(typeText));
      expect(result.rows.single, equals(['hi']));
    });

    // Same TableName skip path for NTEXT (UTF-16LE ROW payload)
    test('NTEXT COLMETADATA TableName + ROW', () async {
      final body = [
        ..._colMetaLegacyLob(typeNText, 'n', tableParts: ['dbo', 'ntext_t']),
        ..._rowLegacyLob(ucs2('αβ')),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.typeInfo.typeId, equals(typeNText));
      expect(result.rows.single, equals(['αβ']));
    });

    // IMAGE: MaxLen only (no collation) + TableName + binary ROW
    test('IMAGE COLMETADATA TableName + ROW', () async {
      final body = [
        ..._colMetaLegacyLob(typeImage, 'img', tableParts: ['dbo', 'img_t']),
        ..._rowLegacyLob([0xDE, 0xAD]),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.typeInfo.typeId, equals(typeImage));
      expect(
          result.rows.single,
          equals([
            [0xDE, 0xAD],
          ]));
    });

    // CAST/computed LOB columns send numParts = 0 (ms-tds §2.2.7.4)
    test('computed TEXT COLMETADATA numParts=0 + NULL ROW', () async {
      final body = [
        ..._colMetaLegacyLob(typeText, '', tableParts: const []),
        ..._rowLegacyLob(const [], isNull: true),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.typeInfo.typeId, equals(typeText));
      expect(result.rows.single, equals([null]));
    });

    // ms-tds ENVCHANGE type 20; go-mssqldb processEnvChg routing
    test('ENVCHANGE routing is skipped without desync in query stream',
        () async {
      final body = [
        ..._envChangeRouting(),
        ..._colMetaInt('n'),
        ..._rowInt(4),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([4]));
    });

    test('login ENVCHANGE routing populates LoginResult.routing', () async {
      final body = [
        ..._loginAckToken('Microsoft SQL Server'),
        ..._envChangeRouting(server: r'secondary\INST', port: 15001),
        ..._doneToken(),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final login = await TokenStream(fed.buf).processLoginResponse();
      expect(login.routing, isNotNull);
      expect(login.routing!.server, equals(r'secondary\INST'));
      expect(login.routing!.port, equals(15001));
    });

    // ms-tds ENVCHANGE type 7 binary collation (not B_VARCHAR)
    test('ENVCHANGE SQL collation is skipped without desync', () async {
      final body = [
        ..._envChangeSqlCollation(),
        ..._colMetaInt('n'),
        ..._rowInt(5),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([5]));
    });

    // INFO alone on success path (vs INFO+ERROR); go-mssqldb / Tedious skip
    test('INFO token alone is skipped before COLMETADATA', () async {
      final body = [
        ..._infoToken('rowcount info'),
        ..._colMetaInt('n'),
        ..._rowInt(8),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([8]));
    });

    // ms-tds XMLTYPE COLMETADATA (schemaPresent=0) + PLP ROW; Tedious xml
    test('COLMETADATA XML + PLP ROW', () async {
      final xml = ucs2('<x/>');
      final out = BytesBuilder(copy: false);
      out.addByte(tokenColMetadata);
      writeUint16LE(out, 1);
      writeUint32LE(out, 0);
      writeUint16LE(out, 0);
      out.addByte(typeXml);
      out.addByte(0); // no schema
      out.addByte(1); // name "v"
      out.add(ucs2('v'));
      out.addByte(tokenRow);
      writeUint64LE(out, xml.length);
      writeUint32LE(out, xml.length);
      out.add(xml);
      writeUint32LE(out, 0); // PLP terminator
      out.add(_doneToken(flags: doneFlagCount, rowCount: 1));

      final fed = await _openWithBody(out.toBytes());
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('v'));
      expect(result.rows.single, equals(['<x/>']));
    });

    // ms-tds UDTINFO COLMETADATA + PLP binary ROW; go-mssqldb UDT
    test('COLMETADATA UDT + PLP ROW', () async {
      final payload = [0xAA, 0xBB];
      List<int> us(String s) => [
            s.length & 0xFF,
            (s.length >> 8) & 0xFF,
            ...ucs2(s),
          ];
      final out = BytesBuilder(copy: false);
      out.addByte(tokenColMetadata);
      writeUint16LE(out, 1);
      writeUint32LE(out, 0);
      writeUint16LE(out, 0);
      out.addByte(typeUdt);
      out.add(us('db'));
      out.add(us('dbo'));
      out.add(us('T'));
      out.add(us('A'));
      out.addByte(1);
      out.add(ucs2('u'));
      out.addByte(tokenRow);
      writeUint64LE(out, payload.length);
      writeUint32LE(out, payload.length);
      out.add(payload);
      writeUint32LE(out, 0);
      out.add(_doneToken(flags: doneFlagCount, rowCount: 1));

      final fed = await _openWithBody(out.toBytes());
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([payload]));
    });

    // ms-tds §2.2.7.6 DONE doneAttn — Attention acknowledgement (no result set)
    test('DONE with doneFlagAttn yields empty QueryResult', () async {
      final body = [..._doneToken(flags: doneFlagAttn)];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
      expect(result.rowsAffected, equals(0));
    });

    test('streamQueryResponse completes on Attention DONE', () async {
      final body = [..._doneToken(flags: doneFlagAttn)];
      final fed = await _openWithBody(body);
      addTearDown(fed.pair.close);

      final rows = <List<Object?>>[];
      await for (final (_, row) in TokenStream(fed.buf).streamQueryResponse()) {
        rows.add(row);
      }
      expect(rows, isEmpty);
    });

    // go-mssqldb buf_test + PR #3: INT4 ROW value straddles TDS packets mid-parse
    test('ROW INT4 value straddling packets stays synced (PR #3)', () async {
      final meta = _colMetaInt('n');
      final done = _doneToken(flags: doneFlagCount, rowCount: 1);
      // 42 = 0x2A little-endian — split after 2 value bytes
      final fed = await _openWithPackets([
        [...meta, tokenRow, 0x2A, 0x00],
        [0x00, 0x00, ...done],
      ]);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals([42]));
    });

    // PR #3: USHORT NVARCHAR length prefix straddles packet boundary
    test('ROW NVARCHAR length prefix straddling packets (PR #3)', () async {
      final meta = _colMetaNVarChar('s');
      final text = ucs2('hi');
      final done = _doneToken(flags: doneFlagCount, rowCount: 1);
      // length 4 LE = 0x04 0x00 — send only first length byte in pkt1
      final fed = await _openWithPackets([
        [...meta, tokenRow, 0x04],
        [0x00, ...text, ...done],
      ]);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.rows.single, equals(['hi']));
    });

    // PR #3: COLMETADATA column-count USHORT straddles packets
    test('COLMETADATA count straddling packets then ROW (PR #3)', () async {
      // tokenColMetadata + low byte of count=1, rest in next packet
      final name = ucs2('n');
      final done = _doneToken(flags: doneFlagCount, rowCount: 1);
      final fed = await _openWithPackets([
        [tokenColMetadata, 0x01],
        [
          0x00, // count high
          0, 0, 0, 0, // userType
          0, 0, // flags
          typeInt4,
          1, // name len
          ...name,
          tokenRow,
          0x07, 0x00, 0x00, 0x00, // 7
          ...done,
        ],
      ]);
      addTearDown(fed.pair.close);

      final result = await TokenStream(fed.buf).processQueryResponse();
      expect(result.columns.single.name, equals('n'));
      expect(result.rows.single, equals([7]));
    });
  });

  group('TokenStream malformed-input mutation coverage', () {
    test('every truncated prefix of a query response rejects promptly',
        () async {
      final valid = <int>[
        ..._colMetaInt('n'),
        ..._rowInt(42),
        ..._doneToken(flags: doneFlagCount, rowCount: 1),
      ];

      for (var length = 0; length < valid.length; length++) {
        final fed = await _openClosedWithBody(valid.sublist(0, length));
        try {
          await _expectPromptRejection(
            TokenStream(fed.buf).processQueryResponse(),
          );
        } finally {
          await fed.pair.close();
        }
      }
    });

    test('corrupted variable-token lengths reject promptly', () async {
      final valid = <int>[..._infoToken('mutation'), ..._doneToken()];
      for (final lengthBytes in const [
        [0x00, 0x00],
        [0x01, 0x00],
        [0xFF, 0x7F],
      ]) {
        final mutated = List<int>.from(valid)
          ..[1] = lengthBytes[0]
          ..[2] = lengthBytes[1];
        final fed = await _openClosedWithBody(mutated);
        try {
          await _expectPromptRejection(
            TokenStream(fed.buf).processQueryResponse(),
          );
        } finally {
          await fed.pair.close();
        }
      }
    });
  });
}
