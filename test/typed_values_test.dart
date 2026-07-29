import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/rpc.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline encode tests for typed SQL binders.
///
/// Sources: go-mssqldb UniqueIdentifier.Value, makeMoneyParam,
/// encodeDateTimeOffset, VarChar / civil.Date / civil.Time; ms-tds TYPE_INFO.

Future<Uint8List> _capture(Future<void> Function(TdsBuffer buf) send) async {
  final pair = await TdsSocketPair.open();
  final completer = Completer<Uint8List>();
  final chunks = BytesBuilder(copy: false);
  pair.server.listen((data) {
    chunks.add(data);
    final all = chunks.toBytes();
    if (all.length >= headerSize) {
      final size = (all[2] << 8) | all[3];
      if (all.length >= size && !completer.isCompleted) {
        completer.complete(Uint8List.fromList(all));
      }
    }
  });
  await send(TdsBuffer(pair.client));
  final pkt = await completer.future.timeout(const Duration(seconds: 2));
  await pair.close();
  return pkt;
}

Uint8List _body(Uint8List pkt) =>
    Uint8List.fromList(pkt.sublist(headerSize, (pkt[2] << 8) | pkt[3]));

bool _containsUcs2(List<int> haystack, String needle) {
  final n = ucs2(needle);
  for (var i = 0; i <= haystack.length - n.length; i++) {
    var ok = true;
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  group('MssqlGuid', () {
    test('toWireBytes uses mixed endian (go-mssqldb UniqueIdentifier)', () {
      // Display: 6F9619FF-8B86-D011-B42D-00C04FC964FF
      final wire = const MssqlGuid('6F9619FF-8B86-D011-B42D-00C04FC964FF')
          .toWireBytes();
      expect(wire.length, equals(16));
      // First group LE on wire: FF 19 96 6F
      expect(wire[0], equals(0xFF));
      expect(wire[1], equals(0x19));
      expect(wire[2], equals(0x96));
      expect(wire[3], equals(0x6F));
      // Second group LE: 86 8B
      expect(wire[4], equals(0x86));
      expect(wire[5], equals(0x8B));
      // Third group LE: 11 D0
      expect(wire[6], equals(0x11));
      expect(wire[7], equals(0xD0));
      // Rest unchanged
      expect(wire.sublist(8), equals([0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF]));
    });

    test('rejects invalid length', () {
      expect(() => const MssqlGuid('not-a-guid').toWireBytes(), throwsArgumentError);
    });
  });

  group('typed param encode', () {
    test('GUID param decl + typeGuid on wire', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @g',
          {'g': const MssqlGuid('6F9619FF-8B86-D011-B42D-00C04FC964FF')},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@g uniqueidentifier'), isTrue);
      expect(body.contains(typeGuid), isTrue);
    });

    test('money + smallmoney decls', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @m, @s',
          {
            'm': MssqlMoney(12.34),
            's': MssqlSmallMoney(1.5),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@m money'), isTrue);
      expect(_containsUcs2(body, '@s smallmoney'), isTrue);
      expect(body.contains(typeMoneyN), isTrue);
    });

    test('datetimeoffset decl + type on wire', () async {
      final dt = DateTime.utc(2024, 3, 15, 10);
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @d',
          {'d': MssqlDateTimeOffset(dt)},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@d datetimeoffset'), isTrue);
      expect(body.contains(typeDateTimeOffsetN), isTrue);
    });

    test('decimal decl + typeDecimalN on wire', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @d',
          {'d': MssqlDecimal(12.34, precision: 10, scale: 2)},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@d decimal(10,2)'), isTrue);
      expect(body.contains(typeDecimalN), isTrue);
    });

    test('varchar / date / time decls + wire types', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @v, @d, @t',
          {
            'v': const MssqlVarchar('hi'),
            'd': MssqlDate(2024, 3, 15),
            't': MssqlTime(hour: 14, minute: 30, second: 45, scale: 7),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@v varchar(8000)'), isTrue);
      expect(_containsUcs2(body, '@d date'), isTrue);
      expect(_containsUcs2(body, '@t time(7)'), isTrue);
      expect(body.contains(typeBigVarChar), isTrue);
      expect(body.contains(typeDateN), isTrue);
      expect(body.contains(typeTimeN), isTrue);
      // Latin-1 'hi' appears as raw bytes, not UCS-2
      expect(body.contains(0x68) && body.contains(0x69), isTrue);
    });

    test('legacy datetime / smalldatetime decls + typeDateTimeN', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @dt, @sd',
          {
            'dt': MssqlDateTime(DateTime.utc(2024, 3, 15, 10, 30, 0)),
            'sd': MssqlSmallDateTime(DateTime.utc(2024, 3, 15, 10, 30)),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@dt datetime'), isTrue);
      expect(_containsUcs2(body, '@sd smalldatetime'), isTrue);
      expect(body.contains(typeDateTimeN), isTrue);
    });
  });

  group('MssqlDateTime / MssqlSmallDateTime', () {
    test('datetime epoch 1900-01-01 midnight is zeros', () {
      final w = MssqlDateTime(DateTime.utc(1900, 1, 1)).toWireBytes();
      expect(w, equals(Uint8List(8)));
    });

    test('datetime days for 1900-01-02', () {
      final w = MssqlDateTime(DateTime.utc(1900, 1, 2, 0, 0, 1)).toWireBytes();
      expect(w[0] | (w[1] << 8) | (w[2] << 16) | (w[3] << 24), equals(1));
      // 1 second = 300 three-hundredths
      expect(w[4] | (w[5] << 8) | (w[6] << 16) | (w[7] << 24), equals(300));
    });

    test('smalldatetime rounds seconds ≥ 30', () {
      final w = MssqlSmallDateTime(DateTime.utc(1900, 1, 1, 0, 0, 30))
          .toWireBytes();
      expect(w[0] | (w[1] << 8), equals(0)); // days
      expect(w[2] | (w[3] << 8), equals(1)); // 1 minute
    });

    test('rejects out of range', () {
      expect(
        () => MssqlDateTime(DateTime.utc(1752, 12, 31)),
        throwsArgumentError,
      );
      expect(
        () => MssqlSmallDateTime(DateTime.utc(2080, 1, 1)),
        throwsArgumentError,
      );
    });
  });

  group('MssqlVarchar / MssqlDate / MssqlTime', () {
    test('varchar rejects non-Latin-1', () {
      expect(
        () => const MssqlVarchar('café€').toWireBytes(),
        throwsArgumentError,
      );
    });

    test('date daysSinceYear1 for 0001-01-01 is 0', () {
      expect(MssqlDate(1, 1, 1).daysSinceYear1, equals(0));
    });

    test('time fromDuration midnight + 1h', () {
      final t = MssqlTime.fromDuration(const Duration(hours: 1, minutes: 2));
      expect(t.hour, equals(1));
      expect(t.minute, equals(2));
    });

    test('invalid date throws', () {
      expect(() => MssqlDate(2024, 2, 30), throwsArgumentError);
    });
  });

  group('MssqlDecimal', () {
    test('parse and toWireBytes match DECIMAL(5,2) golden', () {
      final d = MssqlDecimal.parse('123.45', precision: 5, scale: 2);
      expect(d.unscaled, equals(BigInt.from(12345)));
      final w = d.toWireBytes();
      expect(w.length, equals(5));
      expect(w[0], equals(1)); // positive
      expect(w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24), equals(12345));
    });

    test('fromWire round-trips exact unscaled', () {
      final d = MssqlDecimal.parse('-5.00', precision: 5, scale: 2);
      final again = MssqlDecimal.fromWire(
        d.toWireBytes(),
        precision: 5,
        scale: 2,
      );
      expect(again.unscaled, equals(BigInt.from(-500)));
      expect(again.toString(), equals('-5.00'));
      expect(again.toDouble(), closeTo(-5.0, 1e-9));
    });

    test('negative numeric wire sign byte 0', () {
      final d = MssqlDecimal.parse(
        '-5.00',
        precision: 5,
        scale: 2,
        asNumeric: true,
      );
      expect(d.sqlDecl, equals('numeric(5,2)'));
      expect(d.toWireBytes()[0], equals(0));
      expect(d.unscaled, equals(BigInt.from(-500)));
    });

    test('rejects precision overflow', () {
      expect(
        () => MssqlDecimal.parse('123456', precision: 5, scale: 0),
        throwsArgumentError,
      );
    });
  });

  group('MssqlXml / MssqlVarbinary', () {
    test('xml decl + typeXml schemaPresent=0 on wire', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @x',
          {'x': const MssqlXml('<root/>')},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@x xml'), isTrue);
      var found = false;
      for (var i = 0; i < body.length - 1; i++) {
        if (body[i] == typeXml && body[i + 1] == 0) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
      expect(_containsUcs2(body, '<root/>'), isTrue);
    });

    test('sized varbinary uses USHORT MaxLen not PLP', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @b',
          {
            'b': MssqlVarbinary([0xDE, 0xAD], length: 16),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@b varbinary(16)'), isTrue);
      var found = false;
      for (var i = 0; i < body.length - 4; i++) {
        if (body[i] == typeBigVarBin &&
            body[i + 1] == 16 &&
            body[i + 2] == 0 &&
            body[i + 3] == 2 &&
            body[i + 4] == 0) {
          found = true;
          expect(body[i + 5], equals(0xDE));
          expect(body[i + 6], equals(0xAD));
          break;
        }
      }
      expect(found, isTrue);
    });

    test('varbinary max flag forces PLP MaxLen 0xFFFF', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @b',
          {
            'b': MssqlVarbinary([1, 2, 3], max: true),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@b varbinary(max)'), isTrue);
      var found = false;
      for (var i = 0; i < body.length - 3; i++) {
        if (body[i] == typeBigVarBin &&
            body[i + 1] == 0xFF &&
            body[i + 2] == 0xFF) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
    });

    test('default size follows value length', () {
      expect(MssqlVarbinary([1, 2, 3]).sqlDecl, equals('varbinary(3)'));
      expect(const MssqlVarbinary([]).sqlDecl, equals('varbinary(1)'));
    });

    test('rejects value longer than length', () {
      expect(
        () => MssqlVarbinary([1, 2, 3], length: 2).sqlDecl,
        throwsArgumentError,
      );
    });
  });

  group('MssqlNVarchar / MssqlNChar / MssqlBinary / MssqlRowVersion', () {
    test('nvarchar sized decl + MaxLen chars*2 on wire', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @n',
          {'n': const MssqlNVarchar('hi', length: 16)},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@n nvarchar(16)'), isTrue);
      var found = false;
      for (var i = 0; i < body.length - 3; i++) {
        if (body[i] == typeNVarChar &&
            body[i + 1] == 32 &&
            body[i + 2] == 0) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
    });

    test('nchar pads and uses typeNChar', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @c',
          {'c': MssqlNChar('ab', length: 4)},
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@c nchar(4)'), isTrue);
      expect(body.contains(typeNChar), isTrue);
      expect(_containsUcs2(body, 'ab  '), isTrue);
    });

    test('binary pads with zeros via typeBigBinary', () async {
      final pkt = await _capture(
        (buf) => RpcRequest.sendExecuteSql(
          buf,
          'SELECT @b',
          {
            'b': MssqlBinary([0xAA, 0xBB], length: 4),
          },
        ),
      );
      final body = _body(pkt);
      expect(_containsUcs2(body, '@b binary(4)'), isTrue);
      var found = false;
      for (var i = 0; i < body.length - 6; i++) {
        if (body[i] == typeBigBinary &&
            body[i + 1] == 4 &&
            body[i + 2] == 0 &&
            body[i + 3] == 4 &&
            body[i + 4] == 0 &&
            body[i + 5] == 0xAA &&
            body[i + 6] == 0xBB &&
            body[i + 7] == 0 &&
            body[i + 8] == 0) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
    });

    test('rowversion requires 8 bytes and parses hex', () {
      expect(() => MssqlRowVersion([1, 2, 3]), throwsArgumentError);
      final rv = MssqlRowVersion.parse('0x00000000000000FF');
      expect(rv.bytes.last, equals(0xFF));
      expect(rv.sqlDecl, equals('binary(8)'));
    });
  });
}
