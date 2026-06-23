import 'dart:typed_data';

import 'buf.dart';
import 'constants.dart';

/// Describes a SQL Server column's wire-level type metadata.
class TypeInfo {
  final int typeId;
  final int size; // -1 = PLP / MAX
  final int scale;
  final int precision;
  final Collation? collation;

  const TypeInfo({
    required this.typeId,
    required this.size,
    this.scale = 0,
    this.precision = 0,
    this.collation,
  });

  /// Reads a TYPE_INFO record from the wire (ms-tds §2.2.5.4).
  static Future<TypeInfo> read(TdsBuffer buf) async {
    final typeId = await buf.readUint8();

    // Fixed-length types
    if (_isFixedLen(typeId)) {
      return TypeInfo(typeId: typeId, size: _fixedLen(typeId));
    }

    // BYTELEN types (length prefix is 1 byte)
    if (_isByteLen(typeId)) {
      // DATE has no extra bytes in COLMETADATA — size is always 3.
      if (typeId == typeDateN) {
        return TypeInfo(typeId: typeId, size: 3);
      }
      // TIME/DATETIME2/DATETIMEOFFSET have only a scale byte, no MaxLen byte.
      if (typeId == typeTimeN || typeId == typeDateTime2N || typeId == typeDateTimeOffsetN) {
        final scale = await buf.readUint8();
        return TypeInfo(typeId: typeId, size: scale, scale: scale);
      }
      // All other BYTELEN types: MaxLen byte first.
      final size = await buf.readUint8();
      int scale = 0, prec = 0;
      if (typeId == typeDecimalN || typeId == typeNumericN) {
        prec = await buf.readUint8();
        scale = await buf.readUint8();
      }
      return TypeInfo(typeId: typeId, size: size, scale: scale, precision: prec);
    }

    // USHORTLEN types (length prefix is 2 bytes, collation possible)
    if (_isUshortLen(typeId)) {
      final size = await buf.readUint16LE();
      Collation? collation;
      if (_hasCollation(typeId)) {
        collation = await Collation.read(buf);
      }
      return TypeInfo(typeId: typeId, size: size, collation: collation);
    }

    // LONGLEN types
    if (_isLongLen(typeId)) {
      // XML and UDT have NO MaxLen field in COLMETADATA — only descriptor bytes.
      if (typeId == typeXml) {
        final schemaPresent = await buf.readUint8();
        if (schemaPresent == 1) {
          await _skipBVarChar(buf); // db name
          await _skipBVarChar(buf); // schema name
          await _skipUsVarChar(buf); // xml schema collection
        }
        return TypeInfo(typeId: typeId, size: -1);
      }
      if (typeId == typeUdt) {
        await _skipUsVarChar(buf); // db name
        await _skipUsVarChar(buf); // schema name
        await _skipUsVarChar(buf); // type name
        await _skipUsVarChar(buf); // assembly qualified name
        return TypeInfo(typeId: typeId, size: -1);
      }
      // typeText, typeNText, typeImage, typeVariant: 4-byte MaxLen + optional collation
      final size = await buf.readUint32LE();
      Collation? collation;
      if (_hasCollation(typeId)) {
        collation = await Collation.read(buf);
      }
      return TypeInfo(typeId: typeId, size: size == 0xFFFFFFFF ? -1 : size, collation: collation);
    }

    throw StateError('Unknown typeId: 0x${typeId.toRadixString(16)}');
  }

  /// Reads a value from the wire for this type, returning a Dart-native value.
  Future<Object?> readValue(TdsBuffer buf) async {
    if (_isFixedLen(typeId)) return _readFixed(buf);

    if (_isByteLen(typeId)) {
      final len = await buf.readUint8();
      if (len == 0) return null;
      final data = await buf.readBytes(len);
      return _decodeByteLen(data);
    }

    if (_isUshortLen(typeId)) {
      // size == 0xFFFF means the column was declared as MAX (NVARCHAR(MAX) etc.)
      // In that case the ROW data is PLP-encoded, not USHORT-prefixed.
      if (size == 0xFFFF) return _readPlp(buf);
      final len = await buf.readUint16LE();
      if (len == 0xFFFF) return null; // NULL marker for non-MAX columns
      final data = await buf.readBytes(len);
      return _decodeShortLen(data);
    }

    if (_isLongLen(typeId)) {
      return _readLongLen(buf);
    }

    return null;
  }

  Future<Object?> _readFixed(TdsBuffer buf) async {
    switch (typeId) {
      case typeNull: return null;
      case typeInt1: return await buf.readUint8();
      case typeBit: return (await buf.readUint8()) != 0;
      case typeInt2: return _toSigned(await buf.readUint16LE(), 16);
      case typeInt4: return await buf.readInt32LE();
      case typeInt8:
        final v = await buf.readUint64LE();
        return v;
      case typeFlt4:
        final bytes = await buf.readBytes(4);
        return ByteData.sublistView(Uint8List.fromList(bytes)).getFloat32(0, Endian.little);
      case typeFlt8:
        final bytes = await buf.readBytes(8);
        return ByteData.sublistView(Uint8List.fromList(bytes)).getFloat64(0, Endian.little);
      case typeMoney4:
        final v = await buf.readInt32LE();
        return v / 10000.0;
      case typeMoney:
        final hi = await buf.readInt32LE();
        final lo = await buf.readUint32LE();
        return ((hi * 0x100000000) + lo) / 10000.0;
      case typeDateTime:
        final days = await buf.readInt32LE();
        final ticks = await buf.readUint32LE();
        return _decodeDateTime(days, ticks);
      case typeDateTim4:
        final days = await buf.readUint16LE();
        final mins = await buf.readUint16LE();
        final base = DateTime.utc(1900, 1, 1).add(Duration(days: days, minutes: mins));
        return base;
    }
    return null;
  }

  Object? _decodeByteLen(Uint8List data) {
    switch (typeId) {
      case typeIntN:
        switch (data.length) {
          case 1: return data[0];
          case 2: return _toSigned(data[0] | (data[1] << 8), 16);
          case 4: return _toSigned32(data);
          case 8: return ByteData.sublistView(data).getInt64(0, Endian.little);
        }
      case typeBitN:
        return data[0] != 0;
      case typeFltN:
        if (data.length == 4) return ByteData.sublistView(data).getFloat32(0, Endian.little);
        if (data.length == 8) return ByteData.sublistView(data).getFloat64(0, Endian.little);
      case typeMoneyN:
        if (data.length == 4) {
          return _toSigned32(data) / 10000.0;
        }
        final hi = _toSigned32(data);
        final lo = data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24);
        return ((hi * 0x100000000) + lo) / 10000.0;
      case typeDateTimeN:
        if (data.length == 4) {
          // SmallDateTime: 2-byte days + 2-byte minutes since midnight
          final days = data[0] | (data[1] << 8);
          final mins = data[2] | (data[3] << 8);
          return DateTime.utc(1900, 1, 1).add(Duration(days: days, minutes: mins));
        }
        final days = _toSigned32(data);
        final ticks = data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24);
        return _decodeDateTime(days, ticks);
      case typeGuid:
        return _formatGuid(data);
      case typeDateN:
        final days = data[0] | (data[1] << 8) | (data[2] << 16);
        return DateTime.utc(1, 1, 1).add(Duration(days: days));
      case typeTimeN:
        return _decodeTime(data, scale);
      case typeDateTime2N:
        final time = _decodeTime(data.sublist(0, data.length - 3), scale);
        final dayBytes = data.sublist(data.length - 3);
        final days = dayBytes[0] | (dayBytes[1] << 8) | (dayBytes[2] << 16);
        final base = DateTime.utc(1, 1, 1).add(Duration(days: days));
        return DateTime.utc(base.year, base.month, base.day,
            time.hour, time.minute, time.second, time.millisecond, time.microsecond);
      case typeDateTimeOffsetN:
        // SQL Server stores UTC time on the wire; the offset is display-only.
        // Strip the 2 offset bytes and decode the UTC time + date directly.
        final inner = data.sublist(0, data.length - 2);
        final time = _decodeTime(inner.sublist(0, inner.length - 3), scale);
        final dayBytes = inner.sublist(inner.length - 3);
        final days = dayBytes[0] | (dayBytes[1] << 8) | (dayBytes[2] << 16);
        final base = DateTime.utc(1, 1, 1).add(Duration(days: days));
        return DateTime.utc(base.year, base.month, base.day,
            time.hour, time.minute, time.second, time.millisecond, time.microsecond);
      case typeDecimalN:
      case typeNumericN:
        return _decodeDecimal(data, scale);
    }
    return data;
  }

  Object? _decodeShortLen(Uint8List data) {
    switch (typeId) {
      case typeBigVarChar:
      case typeBigChar:
        return String.fromCharCodes(data); // server collation determines encoding; treat as latin-1
      case typeNVarChar:
      case typeNChar:
        return String.fromCharCodes(
          [for (int i = 0; i < data.length; i += 2) data[i] | (data[i + 1] << 8)],
        );
      case typeBigVarBin:
      case typeBigBinary:
        return data;
    }
    return data;
  }

  Future<Object?> _readLongLen(TdsBuffer buf) async {
    switch (typeId) {
      case typeText:
      case typeNText:
      case typeImage:
        // 24-byte text pointer + 8-byte timestamp, then 4-byte length
        final textPtr = await buf.readUint8();
        if (textPtr == 0) return null;
        await buf.readBytes(textPtr); // text pointer
        await buf.readBytes(8);       // timestamp
        final len = await buf.readUint32LE();
        final data = await buf.readBytes(len);
        if (typeId == typeNText) {
          return String.fromCharCodes(
            [for (int i = 0; i < data.length; i += 2) data[i] | (data[i + 1] << 8)],
          );
        }
        return typeId == typeImage ? data : String.fromCharCodes(data);
      case typeXml:
      case typeUdt:
        return _readPlp(buf);
      case typeVariant:
        final varLen = await buf.readUint32LE();
        if (varLen == 0) return null;
        return await _readVariant(buf, varLen);
    }
    return null;
  }

  // Decodes a sql_variant value from the wire.
  // Format (ms-tds §2.2.5.5.3, confirmed by go-mssqldb types.go:645):
  //   varLen bytes already consumed by caller; wire contains:
  //   BYTE baseTypeId, BYTE propCount, propCount metadata bytes, then value bytes.
  static Future<Object?> _readVariant(TdsBuffer buf, int varLen) async {
    final baseTypeId = await buf.readUint8();
    final propCount  = await buf.readUint8();
    final valueLen   = varLen - 2 - propCount;

    switch (baseTypeId) {
      // ── No-metadata fixed-size types ────────────────────────────────────────
      case typeGuid:
        final d = Uint8List.fromList(await buf.readBytes(valueLen));
        return _formatGuid(d);
      case typeBit:
        return (await buf.readUint8()) != 0;
      case typeInt1:
        return await buf.readUint8();
      case typeInt2:
        return _toSigned(await buf.readUint16LE(), 16);
      case typeInt4:
        return await buf.readInt32LE();
      case typeInt8:
        return await buf.readUint64LE();
      case typeFlt4:
        final d = Uint8List.fromList(await buf.readBytes(4));
        return ByteData.sublistView(d).getFloat32(0, Endian.little);
      case typeFlt8:
        final d = Uint8List.fromList(await buf.readBytes(8));
        return ByteData.sublistView(d).getFloat64(0, Endian.little);
      case typeMoney4:
        return (await buf.readInt32LE()) / 10000.0;
      case typeMoney:
        final hi = await buf.readInt32LE();
        final lo = await buf.readUint32LE();
        return ((hi * 0x100000000) + lo) / 10000.0;
      case typeDateTime:
        final days  = await buf.readInt32LE();
        final ticks = await buf.readUint32LE();
        return _decodeDateTime(days, ticks);
      case typeDateTim4:
        final days = await buf.readUint16LE();
        final mins = await buf.readUint16LE();
        return DateTime.utc(1900, 1, 1).add(Duration(days: days, minutes: mins));
      case typeDateN:
        final d    = Uint8List.fromList(await buf.readBytes(3));
        final days = d[0] | (d[1] << 8) | (d[2] << 16);
        return DateTime.utc(1, 1, 1).add(Duration(days: days));
      // ── 1 metadata byte: scale ───────────────────────────────────────────────
      case typeTimeN:
        final scale = await buf.readUint8();
        final d = Uint8List.fromList(await buf.readBytes(valueLen));
        return _decodeTime(d, scale);
      case typeDateTime2N:
        final scale = await buf.readUint8();
        final d     = Uint8List.fromList(await buf.readBytes(valueLen));
        final time  = _decodeTime(d.sublist(0, d.length - 3), scale);
        final db    = d.sublist(d.length - 3);
        final days  = db[0] | (db[1] << 8) | (db[2] << 16);
        final base  = DateTime.utc(1, 1, 1).add(Duration(days: days));
        return DateTime.utc(base.year, base.month, base.day,
            time.hour, time.minute, time.second, time.millisecond, time.microsecond);
      case typeDateTimeOffsetN:
        final scale = await buf.readUint8();
        final d     = Uint8List.fromList(await buf.readBytes(valueLen));
        final inner = d.sublist(0, d.length - 2); // strip 2-byte offset
        final time  = _decodeTime(inner.sublist(0, inner.length - 3), scale);
        final db    = inner.sublist(inner.length - 3);
        final days  = db[0] | (db[1] << 8) | (db[2] << 16);
        final base  = DateTime.utc(1, 1, 1).add(Duration(days: days));
        return DateTime.utc(base.year, base.month, base.day,
            time.hour, time.minute, time.second, time.millisecond, time.microsecond);
      // ── 2 metadata bytes: max-length (ignored) ───────────────────────────────
      case typeBigVarBin:
      case typeBigBinary:
        await buf.readUint16LE(); // max length — not needed
        return await buf.readBytes(valueLen);
      // ── 2 metadata bytes: precision + scale ──────────────────────────────────
      case typeDecimalN:
      case typeNumericN:
        await buf.readUint8(); // precision — not needed for decoding
        final scale = await buf.readUint8();
        final d = Uint8List.fromList(await buf.readBytes(valueLen));
        return _decodeDecimal(d, scale);
      // ── 7 metadata bytes: 5-byte collation + 2-byte max-length ───────────────
      case typeBigVarChar:
      case typeBigChar:
        await buf.readBytes(5); // collation (skip)
        await buf.readUint16LE(); // max length (ignore)
        return String.fromCharCodes(await buf.readBytes(valueLen));
      case typeNVarChar:
      case typeNChar:
        await buf.readBytes(5); // collation (skip)
        await buf.readUint16LE(); // max length (ignore)
        final d = Uint8List.fromList(await buf.readBytes(valueLen));
        return String.fromCharCodes(
          [for (int i = 0; i < d.length; i += 2) d[i] | (d[i + 1] << 8)],
        );
      default:
        // Unrecognised inner type — consume bytes and return null.
        if (valueLen > 0) await buf.readBytes(valueLen);
        return null;
    }
  }

  Future<Object?> _readPlp(TdsBuffer buf) async {
    final totalLen = await buf.readUint64LE();
    if (totalLen == plpNull) return null;

    final parts = <List<int>>[];
    while (true) {
      final chunkLen = await buf.readUint32LE();
      if (chunkLen == plpTerminator) break;
      parts.add(await buf.readBytes(chunkLen));
    }

    final data = Uint8List(parts.fold<int>(0, (s, p) => s + p.length));
    int offset = 0;
    for (final p in parts) {
      data.setRange(offset, offset + p.length, p);
      offset += p.length;
    }

    if (typeId == typeNVarChar || typeId == typeNChar || typeId == typeXml) {
      return String.fromCharCodes(
        [for (int i = 0; i < data.length; i += 2) data[i] | (data[i + 1] << 8)],
      );
    }
    if (typeId == typeBigVarChar || typeId == typeBigChar) {
      return String.fromCharCodes(data);
    }
    return data;
  }

  // ── Decoding helpers ───────────────────────────────────────────────────────

  static DateTime _decodeDateTime(int days, int ticks) {
    final base = DateTime.utc(1900, 1, 1)
        .add(Duration(days: days))
        .add(Duration(milliseconds: (ticks * 1000 / 300).round()));
    return base;
  }

  static DateTime _decodeTime(Uint8List data, int scale) {
    int ticks = 0;
    for (int i = 0; i < data.length; i++) {
      ticks |= data[i] << (i * 8);
    }
    final microseconds = (ticks * 1000000) ~/ _scaleToBase(scale);
    return DateTime.utc(0).add(Duration(microseconds: microseconds));
  }

  static int _scaleToBase(int scale) {
    int base = 1;
    for (int i = 0; i < scale; i++) {
      base *= 10;
    }
    return base;
  }

  static double _decodeDecimal(Uint8List data, int scale) {
    final positive = data[0] != 0;
    // SQL Server sends up to 4 × uint32 LE parts (precision 1-9 uses 5 bytes,
    // 10-19 → 9 bytes, 20-28 → 13 bytes, 29-38 → 17 bytes).
    BigInt bigVal = BigInt.zero;
    for (int part = 0; part * 4 + 1 < data.length; part++) {
      final base = part * 4 + 1;
      final chunk = data[base] |
          (data[base + 1] << 8) |
          (data[base + 2] << 16) |
          (data[base + 3] << 24);
      bigVal += BigInt.from(chunk & 0xFFFFFFFF) << (part * 32);
    }
    final divisor = BigInt.from(10).pow(scale);
    final intPart = bigVal ~/ divisor;
    final fracPart = bigVal % divisor;
    final result = intPart.toDouble() + fracPart.toDouble() / divisor.toDouble();
    return positive ? result : -result;
  }

  static String _formatGuid(Uint8List d) {
    if (d.length != 16) return d.toString();
    // SQL Server stores GUID with mixed endianness
    String hex(int v, [int width = 2]) => v.toRadixString(16).padLeft(width, '0');
    final p1 = hex(d[3]) + hex(d[2]) + hex(d[1]) + hex(d[0]);
    final p2 = hex(d[5]) + hex(d[4]);
    final p3 = hex(d[7]) + hex(d[6]);
    final p4 = [for (int i = 8; i < 10; i++) hex(d[i])].join();
    final p5 = [for (int i = 10; i < 16; i++) hex(d[i])].join();
    return '$p1-$p2-$p3-$p4-$p5';
  }

  static int _toSigned(int v, int bits) {
    final max = 1 << (bits - 1);
    return v >= max ? v - (1 << bits) : v;
  }

  static int _toSigned32(Uint8List d) {
    final v = d[0] | (d[1] << 8) | (d[2] << 16) | (d[3] << 24);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  static Future<void> _skipBVarChar(TdsBuffer buf) async {
    final len = await buf.readUint8();
    await buf.readBytes(len * 2);
  }

  static Future<void> _skipUsVarChar(TdsBuffer buf) async {
    final len = await buf.readUint16LE();
    await buf.readBytes(len * 2);
  }

  // ── Type classification ────────────────────────────────────────────────────

  static bool _isFixedLen(int t) => const {
    typeNull, typeInt1, typeBit, typeInt2, typeInt4, typeInt8,
    typeFlt4, typeFlt8, typeMoney, typeMoney4, typeDateTime, typeDateTim4,
  }.contains(t);

  static int _fixedLen(int t) => const {
    typeNull: 0, typeInt1: 1, typeBit: 1, typeInt2: 2, typeInt4: 4,
    typeInt8: 8, typeFlt4: 4, typeFlt8: 8, typeMoney: 8, typeMoney4: 4,
    typeDateTime: 8, typeDateTim4: 4,
  }[t]!;

  static bool _isByteLen(int t) => const {
    typeGuid, typeIntN, typeDecimalN, typeNumericN, typeBitN, typeFltN,
    typeMoneyN, typeDateTimeN, typeDateN, typeTimeN, typeDateTime2N,
    typeDateTimeOffsetN,
  }.contains(t);

  static bool _isUshortLen(int t) => const {
    typeBigVarBin, typeBigVarChar, typeBigBinary, typeBigChar,
    typeNVarChar, typeNChar,
  }.contains(t);

  static bool _isLongLen(int t) => const {
    typeText, typeImage, typeNText, typeVariant, typeXml, typeUdt,
  }.contains(t);

  static bool _hasCollation(int t) => const {
    typeBigVarChar, typeBigChar, typeNVarChar, typeNChar, typeText, typeNText,
  }.contains(t);
}

/// SQL Server collation descriptor (5 bytes on wire).
class Collation {
  final int lcid;
  final int flags;
  final int sortId;

  const Collation({required this.lcid, required this.flags, required this.sortId});

  static Future<Collation> read(TdsBuffer buf) async {
    final b0 = await buf.readUint8();
    final b1 = await buf.readUint8();
    final b2 = await buf.readUint8();
    final b3 = await buf.readUint8();
    final sortId = await buf.readUint8();
    final lcid = b0 | (b1 << 8) | ((b2 & 0x0F) << 16);
    final flags = (b2 >> 4) | (b3 << 4);
    return Collation(lcid: lcid, flags: flags, sortId: sortId);
  }
}
