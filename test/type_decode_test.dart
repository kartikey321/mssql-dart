import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/type_info.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline TypeInfo decode tests.
///
/// Sources:
/// - microsoft/go-mssqldb `types_unit_test.go` / PR #323 type conversion coverage
/// - ms-tds §2.2.5.4 TYPE_INFO, §2.2.5.5.3 sql_variant / PLP
/// - Mirrors live cases in `types_test.dart` but runs without SQL Server
Future<(TdsBuffer, TdsSocketPair)> _bufWith(List<int> body) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  return (TdsBuffer(pair.client), pair);
}

Future<(TdsBuffer, TdsSocketPair)> _bufWithLimits(
  List<int> body,
  MssqlProtocolLimits limits,
) async {
  final pair = await TdsSocketPair.open();
  await tdsSend(pair.server, tdsPacket(type: packReply, body: body));
  return (TdsBuffer(pair.client, limits: limits), pair);
}

/// Default collation (5 zero bytes) for string TYPE_INFO.
List<int> get _collation => [0, 0, 0, 0, 0];

Future<Object?> _decode({
  required List<int> typeInfoBytes,
  required List<int> valueBytes,
  MssqlProtocolLimits limits = MssqlProtocolLimits.unlimited,
}) async {
  final (buf, pair) = limits == MssqlProtocolLimits.unlimited
      ? await _bufWith([...typeInfoBytes, ...valueBytes])
      : await _bufWithLimits([...typeInfoBytes, ...valueBytes], limits);
  addTearDown(pair.close);
  await buf.beginRead();
  final ti = await TypeInfo.read(buf);
  return ti.readValue(buf);
}

void main() {
  group('TypeInfo fixed-length decode', () {
    // go-mssqldb types_unit_test.go fixed-size ints/floats/bit
    test('INT4', () async {
      final v = await _decode(
        typeInfoBytes: [typeInt4],
        valueBytes: [0x2A, 0x00, 0x00, 0x00],
      );
      expect(v, equals(42));
    });

    test('BIGINT', () async {
      final v = await _decode(
        typeInfoBytes: [typeInt8],
        valueBytes: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
      );
      expect(v, equals(1));
    });

    test('BIT true/false', () async {
      expect(
        await _decode(typeInfoBytes: [typeBit], valueBytes: [1]),
        isTrue,
      );
      expect(
        await _decode(typeInfoBytes: [typeBit], valueBytes: [0]),
        isFalse,
      );
    });

    test('FLOAT (flt8)', () async {
      final bd = ByteData(8)..setFloat64(0, 3.5, Endian.little);
      final v = await _decode(
        typeInfoBytes: [typeFlt8],
        valueBytes: bd.buffer.asUint8List(),
      );
      expect(v, equals(3.5));
    });

    test('REAL (flt4)', () async {
      final bd = ByteData(4)..setFloat32(0, 1.5, Endian.little);
      final v = await _decode(
        typeInfoBytes: [typeFlt4],
        valueBytes: bd.buffer.asUint8List(),
      );
      expect(v as double, closeTo(1.5, 1e-6));
    });
  });

  group('TypeInfo byte-len decode', () {
    // go-mssqldb: INTN/MONEY/DATE/TIME/GUID/DECIMAL decode helpers
    test('INTN null', () async {
      final v = await _decode(
        typeInfoBytes: [typeIntN, 4],
        valueBytes: [0], // len 0 = null
      );
      expect(v, isNull);
    });

    test('INTN int32', () async {
      final v = await _decode(
        typeInfoBytes: [typeIntN, 4],
        valueBytes: [4, 0x64, 0x00, 0x00, 0x00],
      );
      expect(v, equals(100));
    });

    test('MONEYN smallmoney', () async {
      // 123.4500 → 1234500 / 10000
      final raw = 1234500;
      final v = await _decode(
        typeInfoBytes: [typeMoneyN, 4],
        valueBytes: [
          4,
          raw & 0xFF,
          (raw >> 8) & 0xFF,
          (raw >> 16) & 0xFF,
          (raw >> 24) & 0xFF,
        ],
      );
      expect((v as MssqlSmallMoney).toDouble(), closeTo(123.45, 0.0001));
    });

    test('DATE', () async {
      // days since 0001-01-01 for 2024-03-15
      final target = DateTime.utc(2024, 3, 15);
      final days = target.difference(DateTime.utc(1, 1, 1)).inDays;
      final v = await _decode(
        typeInfoBytes: [typeDateN], // no MaxLen in metadata
        valueBytes: [
          3,
          days & 0xFF,
          (days >> 8) & 0xFF,
          (days >> 16) & 0xFF,
        ],
      );
      final d = v as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(3));
      expect(d.day, equals(15));
    });

    test('TIME scale 0', () async {
      // 14:30:45 → 52245 seconds since midnight
      const seconds = 14 * 3600 + 30 * 60 + 45;
      final v = await _decode(
        typeInfoBytes: [typeTimeN, 0], // scale byte only
        valueBytes: [
          3,
          seconds & 0xFF,
          (seconds >> 8) & 0xFF,
          (seconds >> 16) & 0xFF,
        ],
      );
      final t = v as DateTime;
      expect(t.hour, equals(14));
      expect(t.minute, equals(30));
      expect(t.second, equals(45));
    });

    test('GUID mixed endian', () async {
      // Wire bytes for 6F9619FF-8B86-D011-B42D-00C04FC964FF
      final wire = [
        0xFF, 0x19, 0x96, 0x6F, // LE dword
        0x86, 0x8B, // LE word
        0x11, 0xD0, // LE word
        0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF,
      ];
      final v = await _decode(
        typeInfoBytes: [typeGuid, 16],
        valueBytes: [16, ...wire],
      );
      expect(
        (v as String).toLowerCase(),
        equals('6f9619ff-8b86-d011-b42d-00c04fc964ff'),
      );
    });

    test('DECIMAL(5,2) positive', () async {
      // 123.45 → sign=1, integer 12345
      const scaled = 12345;
      final v = await _decode(
        typeInfoBytes: [typeDecimalN, 5, 5, 2], // MaxLen, prec, scale
        valueBytes: [
          5, // len
          1, // positive
          scaled & 0xFF,
          (scaled >> 8) & 0xFF,
          (scaled >> 16) & 0xFF,
          (scaled >> 24) & 0xFF,
        ],
      );
      expect((v as MssqlDecimal).toDouble(), closeTo(123.45, 0.001));
    });

    test('NUMERIC negative', () async {
      const scaled = 500; // -5.00 at scale 2
      final v = await _decode(
        typeInfoBytes: [typeNumericN, 5, 5, 2],
        valueBytes: [
          5,
          0, // negative
          scaled & 0xFF,
          (scaled >> 8) & 0xFF,
          (scaled >> 16) & 0xFF,
          (scaled >> 24) & 0xFF,
        ],
      );
      expect((v as MssqlDecimal).toDouble(), closeTo(-5.0, 0.001));
    });

    test('DATETIME2 scale 3', () async {
      final days =
          DateTime.utc(2024, 6, 1).difference(DateTime.utc(1, 1, 1)).inDays;
      // 12:30:45.123 at scale 3 → millisecond ticks
      const ticks = ((12 * 3600 + 30 * 60 + 45) * 1000) + 123;
      final v = await _decode(
        typeInfoBytes: [typeDateTime2N, 3],
        valueBytes: [
          7, // 4 time + 3 date
          ticks & 0xFF,
          (ticks >> 8) & 0xFF,
          (ticks >> 16) & 0xFF,
          (ticks >> 24) & 0xFF,
          days & 0xFF,
          (days >> 8) & 0xFF,
          (days >> 16) & 0xFF,
        ],
      );
      final d = v as DateTime;
      expect(d.year, equals(2024));
      expect(d.month, equals(6));
      expect(d.day, equals(1));
      expect(d.hour, equals(12));
      expect(d.minute, equals(30));
      expect(d.second, equals(45));
      expect(d.millisecond, equals(123));
    });

    test('DATETIMEOFFSET scale 0 returns UTC', () async {
      // Local 12:30 +05:30 → UTC 07:00; driver stores UTC and ignores offset.
      final days =
          DateTime.utc(2024, 6, 1).difference(DateTime.utc(1, 1, 1)).inDays;
      const seconds = 7 * 3600; // UTC 07:00:00
      const offsetMinutes = 5 * 60 + 30;
      final v = await _decode(
        typeInfoBytes: [typeDateTimeOffsetN, 0],
        valueBytes: [
          8, // 3 time + 3 date + 2 offset
          seconds & 0xFF,
          (seconds >> 8) & 0xFF,
          (seconds >> 16) & 0xFF,
          days & 0xFF,
          (days >> 8) & 0xFF,
          (days >> 16) & 0xFF,
          offsetMinutes & 0xFF,
          (offsetMinutes >> 8) & 0xFF,
        ],
      );
      final d = v as DateTime;
      expect(d.isUtc, isTrue);
      expect(d.hour, equals(7));
      expect(d.minute, equals(0));
    });

    test('DATETIME2 null', () async {
      final v = await _decode(
        typeInfoBytes: [typeDateTime2N, 7],
        valueBytes: [0],
      );
      expect(v, isNull);
    });
  });

  group('TypeInfo short-len / PLP decode', () {
    // go-mssqldb PLP / USHORTLEN nvarchar/varchar/varbinary; ms-tds PLP
    test('NVARCHAR', () async {
      final text = ucs2('hi');
      final v = await _decode(
        typeInfoBytes: [typeNVarChar, 0x64, 0x00, ..._collation], // size 100
        valueBytes: [text.length & 0xFF, (text.length >> 8) & 0xFF, ...text],
      );
      expect(v, equals('hi'));
    });

    test('NVARCHAR with odd byte length is rejected', () async {
      expect(
        _decode(
          typeInfoBytes: [typeNVarChar, 0x64, 0x00, ..._collation],
          valueBytes: [1, 0, 0x61],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('NVARCHAR null marker', () async {
      final v = await _decode(
        typeInfoBytes: [typeNVarChar, 0x64, 0x00, ..._collation],
        valueBytes: [0xFF, 0xFF],
      );
      expect(v, isNull);
    });

    test('VARCHAR', () async {
      final v = await _decode(
        typeInfoBytes: [typeBigVarChar, 0x32, 0x00, ..._collation],
        valueBytes: [3, 0, 0x61, 0x62, 0x63],
      );
      expect(v, equals('abc'));
    });

    test('NVARCHAR(MAX) PLP chunked', () async {
      final chunk = ucs2('ab');
      final v = await _decode(
        typeInfoBytes: [
          typeNVarChar,
          0xFF, 0xFF, // MAX
          ..._collation,
        ],
        valueBytes: [
          // PLP total length unknown
          0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
          // chunk len 4
          4, 0, 0, 0,
          ...chunk,
          // terminator
          0, 0, 0, 0,
        ],
      );
      expect(v, equals('ab'));
    });

    test('NVARCHAR(MAX) PLP multi-chunk', () async {
      final c1 = ucs2('ab');
      final c2 = ucs2('cd');
      final v = await _decode(
        typeInfoBytes: [
          typeNVarChar,
          0xFF,
          0xFF,
          ..._collation,
        ],
        valueBytes: [
          0xFE,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          4,
          0,
          0,
          0,
          ...c1,
          4,
          0,
          0,
          0,
          ...c2,
          0,
          0,
          0,
          0,
        ],
      );
      expect(v, equals('abcd'));
    });

    test('NVARCHAR(MAX) PLP with odd UTF-16 length is rejected', () async {
      expect(
        _decode(
          typeInfoBytes: [
            typeNVarChar,
            0xFF,
            0xFF,
            ..._collation,
          ],
          valueBytes: [
            3,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            3,
            0,
            0,
            0,
            0x61,
            0x00,
            0x62,
            0,
            0,
            0,
            0,
          ],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('VARBINARY(MAX) PLP null', () async {
      final v = await _decode(
        typeInfoBytes: [typeBigVarBin, 0xFF, 0xFF],
        valueBytes: [
          // plpNull
          0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ],
      );
      expect(v, isNull);
    });

    test('VARBINARY short', () async {
      final v = await _decode(
        typeInfoBytes: [typeBigVarBin, 0x0A, 0x00],
        valueBytes: [3, 0, 0xDE, 0xAD, 0xBE],
      );
      expect(v, equals([0xDE, 0xAD, 0xBE]));
    });

    test('short value length respects maximumValueBytes', () async {
      expect(
        _decode(
          typeInfoBytes: [typeBigVarBin, 0x0A, 0x00],
          valueBytes: [5, 0, 0xDE, 0xAD, 0xBE],
          limits: const MssqlProtocolLimits(maximumValueBytes: 4),
        ),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });

    test('known PLP total length respects maximumValueBytes', () async {
      expect(
        _decode(
          typeInfoBytes: [
            typeNVarChar,
            0xFF,
            0xFF,
            ..._collation,
          ],
          valueBytes: [
            6,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
          ],
          limits: const MssqlProtocolLimits(maximumValueBytes: 4),
        ),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });

    test('PLP chunk length respects maximumPlpChunkBytes', () async {
      expect(
        _decode(
          typeInfoBytes: [typeBigVarBin, 0xFF, 0xFF],
          valueBytes: [
            8,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            8,
            0,
            0,
            0,
          ],
          limits: const MssqlProtocolLimits(
            maximumValueBytes: 8,
            maximumPlpChunkBytes: 4,
          ),
        ),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });

    test('unknown PLP accumulated length respects maximumValueBytes', () async {
      final c1 = ucs2('ab');
      final c2 = ucs2('cd');
      expect(
        _decode(
          typeInfoBytes: [
            typeNVarChar,
            0xFF,
            0xFF,
            ..._collation,
          ],
          valueBytes: [
            0xFE,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            4,
            0,
            0,
            0,
            ...c1,
            4,
            0,
            0,
            0,
            ...c2,
          ],
          limits: const MssqlProtocolLimits(maximumValueBytes: 6),
        ),
        throwsA(isA<MssqlProtocolLimitException>()),
      );
    });
  });

  group('TypeInfo sql_variant decode', () {
    // go-mssqldb types.go sql_variant; ms-tds §2.2.5.5.3; live types_test sql_variant
    test('INT inside sql_variant', () async {
      // TYPE_INFO: variant + MaxLen; value: varLen + baseType + propCount + int32
      final v = await _decode(
        typeInfoBytes: [typeVariant, 0x09, 0x1F, 0x00, 0x00], // MaxLen 8009
        valueBytes: [
          6, 0, 0, 0, // varLen = 1+1+4
          typeInt4,
          0, // propCount
          0x14, 0x00, 0x00, 0x00, // 20
        ],
      );
      expect(v, equals(20));
    });

    test('NVARCHAR inside sql_variant', () async {
      final text = ucs2('ab');
      // props: 5 collation + 2 maxLen = 7; valueLen = 4
      final varLen = 2 + 7 + text.length;
      final v = await _decode(
        typeInfoBytes: [typeVariant, 0x09, 0x1F, 0x00, 0x00],
        valueBytes: [
          varLen & 0xFF, (varLen >> 8) & 0xFF, 0, 0,
          typeNVarChar,
          7, // propCount
          0, 0, 0, 0, 0, // collation
          0x00, 0x20, // max length hint
          ...text,
        ],
      );
      expect(v, equals('ab'));
    });

    test('NULL sql_variant', () async {
      final v = await _decode(
        typeInfoBytes: [typeVariant, 0x09, 0x1F, 0x00, 0x00],
        valueBytes: [0, 0, 0, 0],
      );
      expect(v, isNull);
    });

    test('sql_variant shorter than declared metadata is rejected', () async {
      expect(
        _decode(
          typeInfoBytes: [typeVariant, 0x09, 0x1F, 0x00, 0x00],
          valueBytes: [
            2, 0, 0, 0, // varLen: only base type + propCount
            typeNVarChar,
            7, // propCount requires 7 metadata bytes
          ],
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('TypeInfo TEXT/NTEXT/IMAGE decode', () {
    // ms-tds §2.2.5.2.3 long-len; go-mssqldb types.go text/image; Tedious text
    List<int> lobValue(List<int> data, {bool isNull = false}) {
      if (isNull) return [0];
      return [
        16, // textPtrLen
        ...List.filled(16, 0x01),
        ...List.filled(8, 0x00), // timestamp
        data.length & 0xFF,
        (data.length >> 8) & 0xFF,
        (data.length >> 16) & 0xFF,
        (data.length >> 24) & 0xFF,
        ...data,
      ];
    }

    test('TEXT value', () async {
      final v = await _decode(
        typeInfoBytes: [typeText, 0xFF, 0xFF, 0xFF, 0x7F, ..._collation],
        valueBytes: lobValue('ok'.codeUnits),
      );
      expect(v, equals('ok'));
    });

    test('NTEXT value', () async {
      final v = await _decode(
        typeInfoBytes: [typeNText, 0xFF, 0xFF, 0xFF, 0x7F, ..._collation],
        valueBytes: lobValue(ucs2('xy')),
      );
      expect(v, equals('xy'));
    });

    test('IMAGE value and NULL', () async {
      final bytes = await _decode(
        typeInfoBytes: [typeImage, 0xFF, 0xFF, 0xFF, 0x7F],
        valueBytes: lobValue([0xCA, 0xFE]),
      );
      expect(bytes, equals([0xCA, 0xFE]));

      final n = await _decode(
        typeInfoBytes: [typeImage, 0xFF, 0xFF, 0xFF, 0x7F],
        valueBytes: lobValue(const [], isNull: true),
      );
      expect(n, isNull);
    });
  });

  group('TypeInfo XML / UDT decode', () {
    // ms-tds §2.2.5.5.3 XMLTYPE / UDTINFO; go-mssqldb types.go; Tedious xml/udt
    List<int> bVarChar(String s) => [s.length, ...ucs2(s)];
    List<int> usVarChar(String s) => [
          s.length & 0xFF,
          (s.length >> 8) & 0xFF,
          ...ucs2(s),
        ];

    List<int> plp(List<int> data) => [
          data.length & 0xFF,
          (data.length >> 8) & 0xFF,
          (data.length >> 16) & 0xFF,
          (data.length >> 24) & 0xFF,
          0,
          0,
          0,
          0,
          data.length & 0xFF,
          (data.length >> 8) & 0xFF,
          (data.length >> 16) & 0xFF,
          (data.length >> 24) & 0xFF,
          ...data,
          0,
          0,
          0,
          0, // terminator
        ];

    List<int> plpNull() => [
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
        ];

    test('XML without schema + PLP string', () async {
      final xml = ucs2('<a/>');
      final v = await _decode(
        typeInfoBytes: [typeXml, 0], // schemaPresent = 0
        valueBytes: plp(xml),
      );
      expect(v, equals('<a/>'));
    });

    test('XML with schema descriptor skips names then decodes PLP', () async {
      final xml = ucs2('<r/>');
      final v = await _decode(
        typeInfoBytes: [
          typeXml,
          1, // schemaPresent
          ...bVarChar('db'),
          ...bVarChar('dbo'),
          ...usVarChar('MySchema'),
        ],
        valueBytes: plp(xml),
      );
      expect(v, equals('<r/>'));
    });

    test('XML NULL PLP', () async {
      final v = await _decode(
        typeInfoBytes: [typeXml, 0],
        valueBytes: plpNull(),
      );
      expect(v, isNull);
    });

    test('UDT skips four US_VARCHARs then returns PLP bytes', () async {
      final payload = [0x01, 0x02, 0x03];
      final v = await _decode(
        typeInfoBytes: [
          typeUdt,
          ...usVarChar('db'),
          ...usVarChar('dbo'),
          ...usVarChar('Point'),
          ...usVarChar('Asm, Version=1.0.0.0'),
        ],
        valueBytes: plp(payload),
      );
      expect(v, equals(payload));
    });

    test('UDT NULL PLP', () async {
      final v = await _decode(
        typeInfoBytes: [
          typeUdt,
          ...usVarChar(''),
          ...usVarChar(''),
          ...usVarChar('T'),
          ...usVarChar(''),
        ],
        valueBytes: plpNull(),
      );
      expect(v, isNull);
    });
  });
}
