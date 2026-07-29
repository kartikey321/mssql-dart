import 'dart:typed_data';

import '../params.dart';
import '../typed_values.dart';
import 'buf.dart';
import 'constants.dart';
import 'tvp.dart';

/// Sends an RPC request using sp_executesql for parameterised queries.
///
/// ms-tds §2.2.6.5 RPC Request
class RpcRequest {
  // Well-known RPC procedure IDs (ProcIDSwitch)
  static const int _spExecuteSql = 10;

  /// StatusFlags: by-ref / OUTPUT parameter (ms-tds RPC ParameterData).
  static const int _fByRefValue = 0x01;

  /// Sends [sql] as a direct SQL batch (packSQLBatch) without sp_executesql.
  /// Use for parameterless statements, especially DDL — temp tables created
  /// inside sp_executesql are scoped to that call, not the session.
  static Future<void> sendBatch(TdsBuffer buf, String sql) async {
    buf.beginPacket(packSQLBatch);
    _writeAllHeaders(buf);
    buf.writeBytes(_ucs2(sql));
    await buf.finishPacket(packSQLBatch);
  }

  /// Sends a named stored-procedure RPC (ProcName form, not ProcID).
  ///
  /// [procedure] may be `dbo.MyProc` or `MyProc`. Parameters marked with
  /// [MssqlOutput] are sent with fByRefValue so the server returns
  /// RETURNVALUE tokens.
  static Future<void> sendProcedure(
    TdsBuffer buf,
    String procedure,
    Map<String, Object?> parameters,
  ) async {
    buf.beginPacket(packRPCRequest);
    _writeAllHeaders(buf);

    final nameBytes = _ucs2(procedure);
    buf.writeUint16LE(nameBytes.length >> 1);
    buf.writeBytes(nameBytes);
    buf.writeUint16LE(0); // OptionFlags

    for (final entry in parameters.entries) {
      _writeParam(buf, entry.key, entry.value);
    }

    await buf.finishPacket(packRPCRequest);
  }

  /// Sends `sp_executesql @statement, @params, @p1=v1, ...`.
  static Future<void> sendExecuteSql(
    TdsBuffer buf,
    String sql,
    Map<String, Object?> parameters,
  ) async {
    buf.beginPacket(packRPCRequest);

    // ALL_HEADERS (ms-tds §2.2.5.3) – required from TDS 7.2+
    _writeAllHeaders(buf);

    // ProcIDSwitch: 0xFFFF + uint16 proc ID
    buf.writeUint16LE(0xFFFF);
    buf.writeUint16LE(_spExecuteSql);

    // OptionFlags: 0 (no flags)
    buf.writeUint16LE(0);

    // Parameter 1: @statement (nvarchar, input)
    _writeNVarCharParam(buf, '', sql, isOutput: false);

    if (parameters.isNotEmpty) {
      // Parameter 2: @params (nvarchar, input) – type declaration string
      final paramDecl = _buildParamDecl(parameters);
      _writeNVarCharParam(buf, '', paramDecl, isOutput: false);

      // Remaining parameters
      for (final entry in parameters.entries) {
        _writeParam(buf, entry.key, entry.value);
      }
    }

    await buf.finishPacket(packRPCRequest);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static void _writeAllHeaders(TdsBuffer buf) {
    const headerDataLen = 18;
    const totalLen = 4 + headerDataLen;
    buf.writeUint32LE(totalLen);
    buf.writeUint32LE(headerDataLen);
    buf.writeUint16LE(0x0002); // transaction descriptor header
    buf.writeUint64LE(
        buf.transactionDescriptor); // updated by server ENVCHANGE type 8
    buf.writeUint32LE(1); // outstanding requests
  }

  static String _buildParamDecl(Map<String, Object?> params) {
    return params.entries.map((e) {
      final out = e.value is MssqlOutput;
      final typeName = _dartTypeToSql(e.value);
      return '@${e.key} $typeName${out ? ' OUTPUT' : ''}';
    }).join(', ');
  }

  static String _dartTypeToSql(Object? v) {
    if (v is MssqlOutput) {
      if (v.sqlType != null && v.sqlType!.isNotEmpty) return v.sqlType!;
      if (v.value == null) return 'int';
      return _dartTypeToSql(v.value);
    }
    if (v == null) return 'nvarchar(max)';
    if (v is MssqlTvp) return v.readonlyDecl;
    if (v is MssqlGuid) return 'uniqueidentifier';
    if (v is MssqlMoney) return 'money';
    if (v is MssqlSmallMoney) return 'smallmoney';
    if (v is MssqlDateTimeOffset) return 'datetimeoffset';
    if (v is MssqlDecimal) return v.sqlDecl;
    if (v is MssqlVarchar) return v.sqlDecl;
    if (v is MssqlDate) return 'date';
    if (v is MssqlTime) return v.sqlDecl;
    if (v is MssqlDateTime) return 'datetime';
    if (v is MssqlSmallDateTime) return 'smalldatetime';
    if (v is MssqlXml) return v.sqlDecl;
    if (v is MssqlVarbinary) return v.sqlDecl;
    if (v is MssqlNVarchar) return v.sqlDecl;
    if (v is MssqlNChar) return v.sqlDecl;
    if (v is MssqlBinary) return v.sqlDecl;
    if (v is MssqlRowVersion) return v.sqlDecl;
    if (v is int) return 'bigint';
    if (v is double) return 'float';
    if (v is bool) return 'bit';
    if (v is String) return 'nvarchar(${v.length > 4000 ? 'max' : '4000'})';
    if (v is DateTime) return 'datetime2';
    if (v is List<int>) return 'varbinary(max)';
    return 'nvarchar(max)';
  }

  static void _writeParam(TdsBuffer buf, String name, Object? value) {
    final nameBytes = _ucs2('@$name');
    buf.writeByte(nameBytes.length >> 1);
    buf.writeBytes(nameBytes);

    var isOutput = false;
    Object? actual = value;
    String? sqlType;
    if (value is MssqlOutput) {
      isOutput = true;
      actual = value.value;
      sqlType = value.sqlType;
    }

    buf.writeByte(isOutput ? _fByRefValue : 0x00);
    _writeParamValue(
      buf,
      actual,
      sqlType: sqlType ?? (isOutput && actual == null ? 'int' : null),
    );
  }

  static void _writeParamValue(
    TdsBuffer buf,
    Object? value, {
    String? sqlType,
  }) {
    if (value == null) {
      if (sqlType != null) {
        _writeNullParam(buf, sqlType);
      } else {
        // Untyped null in sp_executesql / query params → nvarchar NULL
        // (historical default; matches prior driver behaviour).
        buf.writeByte(typeNVarChar);
        buf.writeUint16LE(2); // max length hint
        _writeCollation(buf);
        buf.writeUint16LE(0xFFFF); // null
      }
      return;
    }

    switch (value) {
      case MssqlTvp v:
        v.writeTypeAndValue(buf);
      case MssqlGuid v:
        _writeGuidParam(buf, v);
      case MssqlMoney v:
        _writeMoneyParam(buf, v.scaled, small: false);
      case MssqlSmallMoney v:
        _writeMoneyParam(buf, v.scaled, small: true);
      case MssqlDateTimeOffset v:
        _writeDateTimeOffsetParam(buf, v);
      case MssqlDecimal v:
        _writeDecimalParam(buf, v);
      case MssqlVarchar v:
        _writeVarCharParam(buf, v);
      case MssqlDate v:
        _writeDateParam(buf, v);
      case MssqlTime v:
        _writeTimeParam(buf, v);
      case MssqlDateTime v:
        _writeLegacyDateTimeParam(buf, v.toWireBytes(), small: false);
      case MssqlSmallDateTime v:
        _writeLegacyDateTimeParam(buf, v.toWireBytes(), small: true);
      case MssqlXml v:
        _writeXmlParam(buf, v);
      case MssqlVarbinary v:
        _writeVarBinaryParam(buf, v);
      case MssqlNVarchar v:
        _writeNVarCharSizedParam(buf, v);
      case MssqlNChar v:
        _writeNCharParam(buf, v);
      case MssqlBinary v:
        _writeFixedBinaryParam(buf, v.padded);
      case MssqlRowVersion v:
        _writeFixedBinaryParam(buf, v.bytes);
      case int v:
        buf.writeByte(typeIntN);
        buf.writeByte(8); // max len
        buf.writeByte(8); // actual len
        final lo = v & 0xFFFFFFFF;
        final hi = (v >> 32) & 0xFFFFFFFF;
        buf.writeUint32LE(lo);
        buf.writeUint32LE(hi);
      case double v:
        buf.writeByte(typeFltN);
        buf.writeByte(8);
        buf.writeByte(8);
        final bytes = Uint8List(8);
        ByteData.sublistView(bytes).setFloat64(0, v, Endian.little);
        buf.writeBytes(bytes);
      case bool v:
        buf.writeByte(typeBitN);
        buf.writeByte(1);
        buf.writeByte(1);
        buf.writeByte(v ? 1 : 0);
      case String v:
        _writeNVarCharParam(buf, '', v, isOutput: false, skipName: true);
      case DateTime v:
        _writeDateTimeParam(buf, v);
      case List<int> v:
        _writeBinaryParam(buf, Uint8List.fromList(v));
      default:
        final s = value.toString();
        _writeNVarCharParam(buf, '', s, isOutput: false, skipName: true);
    }
  }

  static void _writeNullParam(TdsBuffer buf, String? sqlType) {
    final t = (sqlType ?? 'int').trim().toLowerCase();
    if (t.startsWith('nvarchar') || t.startsWith('nchar')) {
      final nchar = RegExp(r'^nchar\s*\(\s*(\d+)\s*\)$').firstMatch(t);
      if (nchar != null) {
        final n = int.parse(nchar.group(1)!).clamp(1, 4000);
        buf.writeByte(typeNChar);
        buf.writeUint16LE(n * 2);
        _writeCollation(buf);
        buf.writeUint16LE(0xFFFF);
        return;
      }
      final sized = RegExp(r'^nvarchar\s*\(\s*(\d+)\s*\)$').firstMatch(t);
      buf.writeByte(typeNVarChar);
      if (sized != null) {
        final n = int.parse(sized.group(1)!).clamp(1, 4000);
        buf.writeUint16LE(n * 2);
      } else {
        buf.writeUint16LE(2);
      }
      _writeCollation(buf);
      buf.writeUint16LE(0xFFFF);
      return;
    }
    if (t.startsWith('varchar') || t.startsWith('char')) {
      buf.writeByte(typeBigVarChar);
      buf.writeUint16LE(1);
      _writeCollation(buf);
      buf.writeUint16LE(0xFFFF);
      return;
    }
    if (t == 'bit') {
      buf.writeByte(typeBitN);
      buf.writeByte(1);
      buf.writeByte(0);
      return;
    }
    if (t == 'float' || t == 'real' || t == 'double') {
      buf.writeByte(typeFltN);
      buf.writeByte(8);
      buf.writeByte(0);
      return;
    }
    if (t.startsWith('varbinary') ||
        t.startsWith('binary') ||
        t == 'image' ||
        t == 'timestamp' ||
        t == 'rowversion') {
      final fixed = RegExp(r'^binary\s*\(\s*(\d+)\s*\)$').firstMatch(t);
      if (fixed != null || t == 'timestamp' || t == 'rowversion') {
        final n = fixed != null
            ? int.parse(fixed.group(1)!).clamp(1, 8000)
            : 8;
        buf.writeByte(typeBigBinary);
        buf.writeUint16LE(n);
        buf.writeUint16LE(0xFFFF); // null
        return;
      }
      buf.writeByte(typeBigVarBin);
      final sized = RegExp(r'^varbinary\s*\(\s*(\d+)\s*\)$').firstMatch(t);
      if (sized != null) {
        final n = int.parse(sized.group(1)!).clamp(1, 8000);
        buf.writeUint16LE(n);
        buf.writeUint16LE(0xFFFF); // null
      } else {
        buf.writeUint16LE(0xFFFF);
        buf.writeUint64LE(plpNull);
      }
      return;
    }
    if (t == 'xml') {
      buf.writeByte(typeXml);
      buf.writeByte(0); // schemaPresent
      buf.writeUint64LE(plpNull);
      return;
    }
    if (t.startsWith('datetimeoffset')) {
      buf.writeByte(typeDateTimeOffsetN);
      buf.writeByte(7);
      buf.writeByte(0);
      return;
    }
    if (t == 'date') {
      buf.writeByte(typeDateN);
      buf.writeByte(0);
      return;
    }
    if (t.startsWith('time')) {
      buf.writeByte(typeTimeN);
      buf.writeByte(7);
      buf.writeByte(0);
      return;
    }
    if (t == 'smalldatetime') {
      buf.writeByte(typeDateTimeN);
      buf.writeByte(4);
      buf.writeByte(0);
      return;
    }
    if (t == 'datetime') {
      buf.writeByte(typeDateTimeN);
      buf.writeByte(8);
      buf.writeByte(0);
      return;
    }
    if (t.startsWith('datetime2')) {
      buf.writeByte(typeDateTime2N);
      buf.writeByte(7);
      buf.writeByte(0);
      return;
    }
    if (t == 'uniqueidentifier' || t == 'guid') {
      buf.writeByte(typeGuid);
      buf.writeByte(16);
      buf.writeByte(0);
      return;
    }
    if (t == 'money') {
      buf.writeByte(typeMoneyN);
      buf.writeByte(8);
      buf.writeByte(0);
      return;
    }
    if (t == 'smallmoney') {
      buf.writeByte(typeMoneyN);
      buf.writeByte(4);
      buf.writeByte(0);
      return;
    }
    final dec = RegExp(r'^(decimal|numeric)\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)$')
        .firstMatch(t);
    if (dec != null) {
      final prec = int.parse(dec.group(2)!);
      final scale = int.parse(dec.group(3)!);
      final maxLen = MssqlDecimal.maxLenForPrecision(prec);
      buf.writeByte(
        dec.group(1) == 'numeric' ? typeNumericN : typeDecimalN,
      );
      buf.writeByte(maxLen);
      buf.writeByte(prec);
      buf.writeByte(scale);
      buf.writeByte(0);
      return;
    }
    // int / bigint / smallint / tinyint / default
    final maxLen = (t == 'bigint')
        ? 8
        : (t == 'smallint')
            ? 2
            : (t == 'tinyint')
                ? 1
                : 4;
    buf.writeByte(typeIntN);
    buf.writeByte(maxLen);
    buf.writeByte(0); // null
  }

  static void _writeNVarCharParam(
    TdsBuffer buf,
    String name,
    String value, {
    bool isOutput = false,
    bool skipName = false,
  }) {
    if (!skipName) {
      final nameBytes = _ucs2(name);
      buf.writeByte(nameBytes.length >> 1);
      buf.writeBytes(nameBytes);
      buf.writeByte(isOutput ? _fByRefValue : 0x00);
    }

    final valueBytes = _ucs2(value);
    final isMax = valueBytes.length > 8000;

    buf.writeByte(typeNVarChar);
    buf.writeUint16LE(isMax ? 0xFFFF : 8000); // MaxLength
    _writeCollation(buf);

    if (isMax) {
      // PLP form
      buf.writeUint64LE(valueBytes.length); // total length
      buf.writeUint32LE(valueBytes.length); // chunk length
      buf.writeBytes(valueBytes);
      buf.writeUint32LE(plpTerminator); // terminator
    } else {
      buf.writeUint16LE(valueBytes.length);
      buf.writeBytes(valueBytes);
    }
  }

  static void _writeDecimalParam(TdsBuffer buf, MssqlDecimal d) {
    final bytes = d.toWireBytes();
    buf.writeByte(d.asNumeric ? typeNumericN : typeDecimalN);
    buf.writeByte(bytes.length); // MaxLen
    buf.writeByte(d.precision);
    buf.writeByte(d.scale);
    buf.writeByte(bytes.length); // value len
    buf.writeBytes(bytes);
  }

  /// `varchar` / typeBigVarChar (go-mssqldb VarChar) — Latin-1, not UCS-2.
  static void _writeVarCharParam(TdsBuffer buf, MssqlVarchar v) {
    final valueBytes = Uint8List.fromList(v.toWireBytes());
    final isMax = v.max || valueBytes.length > 8000;

    buf.writeByte(typeBigVarChar);
    buf.writeUint16LE(isMax ? 0xFFFF : 8000);
    _writeCollation(buf);

    if (isMax) {
      buf.writeUint64LE(valueBytes.length);
      buf.writeUint32LE(valueBytes.length);
      buf.writeBytes(valueBytes);
      buf.writeUint32LE(plpTerminator);
    } else {
      buf.writeUint16LE(valueBytes.length);
      buf.writeBytes(valueBytes);
    }
  }

  /// `date` / typeDateN — 3-byte days since 0001-01-01.
  static void _writeDateParam(TdsBuffer buf, MssqlDate d) {
    final days = d.daysSinceYear1;
    buf.writeByte(typeDateN);
    buf.writeByte(3);
    buf.writeByte(days & 0xFF);
    buf.writeByte((days >> 8) & 0xFF);
    buf.writeByte((days >> 16) & 0xFF);
  }

  /// `time(s)` / typeTimeN — scale + time ticks (no date).
  static void _writeTimeParam(TdsBuffer buf, MssqlTime t) {
    final scale = t.scale.clamp(0, 7);
    final dt = DateTime.utc(
      1970,
      1,
      1,
      t.hour,
      t.minute,
      t.second,
      t.microsecond ~/ 1000,
      t.microsecond % 1000,
    );
    final timeBytes = _encodeTimeBytes(dt, scale);
    buf.writeByte(typeTimeN);
    buf.writeByte(scale);
    buf.writeByte(timeBytes.length);
    buf.writeBytes(timeBytes);
  }

  /// Legacy `datetime` / `smalldatetime` via typeDateTimeN (go-mssqldb DateTime1).
  static void _writeLegacyDateTimeParam(
    TdsBuffer buf,
    Uint8List bytes, {
    required bool small,
  }) {
    buf.writeByte(typeDateTimeN);
    buf.writeByte(small ? 4 : 8); // MaxLen
    buf.writeByte(bytes.length); // value len
    buf.writeBytes(bytes);
  }

  static void _writeGuidParam(TdsBuffer buf, MssqlGuid guid) {
    final bytes = guid.toWireBytes();
    buf.writeByte(typeGuid);
    buf.writeByte(16); // MaxLen
    buf.writeByte(16); // value len
    buf.writeBytes(bytes);
  }

  static void _writeMoneyParam(TdsBuffer buf, int scaled, {required bool small}) {
    buf.writeByte(typeMoneyN);
    if (small) {
      buf.writeByte(4); // MaxLen
      buf.writeByte(4); // value len
      buf.writeInt32LE(scaled);
    } else {
      buf.writeByte(8);
      buf.writeByte(8);
      // Same layout as decode: signed hi INT32 + lo UINT32.
      final hi = scaled >> 32;
      final lo = scaled & 0xFFFFFFFF;
      buf.writeInt32LE(hi);
      buf.writeUint32LE(lo);
    }
  }

  static void _writeDateTimeOffsetParam(
    TdsBuffer buf,
    MssqlDateTimeOffset dto,
  ) {
    final scale = dto.scale.clamp(0, 7);
    final utc = dto.value.toUtc();
    final timeBytes = _encodeTimeBytes(utc, scale);
    final days = _daysSinceYear1(utc);
    final offsetMins = dto.wireOffset.inMinutes;

    buf.writeByte(typeDateTimeOffsetN);
    buf.writeByte(scale);
    buf.writeByte(timeBytes.length + 3 + 2);
    buf.writeBytes(timeBytes);
    buf.writeByte(days & 0xFF);
    buf.writeByte((days >> 8) & 0xFF);
    buf.writeByte((days >> 16) & 0xFF);
    buf.writeByte(offsetMins & 0xFF);
    buf.writeByte((offsetMins >> 8) & 0xFF);
  }

  /// Encodes TIME portion for DATETIME2 / DATETIMEOFFSET at [scale].
  static Uint8List _encodeTimeBytes(DateTime dt, int scale) {
    final micros = dt.hour * 3600000000 +
        dt.minute * 60000000 +
        dt.second * 1000000 +
        dt.millisecond * 1000 +
        dt.microsecond;
    // scale 7 = 100ns ticks; reduce for lower scales.
    var ticks = micros * 10;
    for (var s = 7; s > scale; s--) {
      ticks = ticks ~/ 10;
    }
    final size = scale <= 2
        ? 3
        : scale <= 4
            ? 4
            : 5;
    final out = Uint8List(size);
    for (var i = 0; i < size; i++) {
      out[i] = (ticks >> (8 * i)) & 0xFF;
    }
    return out;
  }

  static void _writeDateTimeParam(TdsBuffer buf, DateTime dt) {
    buf.writeByte(typeDateTime2N);
    buf.writeByte(7); // scale=7 (DateTime2N has no MaxLen byte in TypeInfo)

    // Encode as DateTime2: time(5 bytes at scale 7) + date(3 bytes)
    final micros = dt.hour * 3600000000 +
        dt.minute * 60000000 +
        dt.second * 1000000 +
        dt.millisecond * 1000 +
        dt.microsecond;
    final ticks = micros * 10; // scale 7 = 100ns ticks
    final days = _daysSinceYear1(dt);

    buf.writeByte(8); // data len (5 time + 3 date)
    buf.writeByte(ticks & 0xFF);
    buf.writeByte((ticks >> 8) & 0xFF);
    buf.writeByte((ticks >> 16) & 0xFF);
    buf.writeByte((ticks >> 24) & 0xFF);
    buf.writeByte((ticks >> 32) & 0xFF);
    buf.writeByte(days & 0xFF);
    buf.writeByte((days >> 8) & 0xFF);
    buf.writeByte((days >> 16) & 0xFF);
  }

  static void _writeBinaryParam(TdsBuffer buf, Uint8List data) {
    buf.writeByte(typeBigVarBin);
    buf.writeUint16LE(0xFFFF); // MAX
    // PLP form
    buf.writeUint64LE(data.length);
    buf.writeUint32LE(data.length);
    buf.writeBytes(data);
    buf.writeUint32LE(plpTerminator);
  }

  /// `xml` / typeXml — schemaPresent=0 + UCS-2 PLP (ms-tds XMLTYPE).
  static void _writeXmlParam(TdsBuffer buf, MssqlXml v) {
    final valueBytes = _ucs2(v.value);
    buf.writeByte(typeXml);
    buf.writeByte(0); // SchemaPresent
    buf.writeUint64LE(valueBytes.length);
    buf.writeUint32LE(valueBytes.length);
    buf.writeBytes(valueBytes);
    buf.writeUint32LE(plpTerminator);
  }

  /// `varbinary(n)` USHORTLEN or `varbinary(max)` PLP (go-mssqldb []byte size).
  static void _writeVarBinaryParam(TdsBuffer buf, MssqlVarbinary v) {
    final data = Uint8List.fromList(v.value);
    buf.writeByte(typeBigVarBin);
    if (v.useMax) {
      buf.writeUint16LE(0xFFFF);
      buf.writeUint64LE(data.length);
      buf.writeUint32LE(data.length);
      buf.writeBytes(data);
      buf.writeUint32LE(plpTerminator);
      return;
    }
    final maxLen = v.wireMaxLength;
    buf.writeUint16LE(maxLen);
    buf.writeUint16LE(data.length);
    buf.writeBytes(data);
  }

  /// `nvarchar(n)` USHORTLEN or `nvarchar(max)` PLP.
  static void _writeNVarCharSizedParam(TdsBuffer buf, MssqlNVarchar v) {
    final valueBytes = _ucs2(v.value);
    buf.writeByte(typeNVarChar);
    if (v.useMax) {
      buf.writeUint16LE(0xFFFF);
      _writeCollation(buf);
      buf.writeUint64LE(valueBytes.length);
      buf.writeUint32LE(valueBytes.length);
      buf.writeBytes(valueBytes);
      buf.writeUint32LE(plpTerminator);
      return;
    }
    final chars = v.wireCharLength;
    buf.writeUint16LE(chars * 2);
    _writeCollation(buf);
    buf.writeUint16LE(valueBytes.length);
    buf.writeBytes(valueBytes);
  }

  /// `nchar(n)` — fixed MaxLen, space-padded UCS-2.
  static void _writeNCharParam(TdsBuffer buf, MssqlNChar v) {
    final valueBytes = _ucs2(v.padded);
    buf.writeByte(typeNChar);
    buf.writeUint16LE(v.length * 2);
    _writeCollation(buf);
    buf.writeUint16LE(valueBytes.length);
    buf.writeBytes(valueBytes);
  }

  /// `binary(n)` / rowversion — typeBigBinary, fixed MaxLen, zero-padded.
  static void _writeFixedBinaryParam(TdsBuffer buf, Uint8List data) {
    buf.writeByte(typeBigBinary);
    buf.writeUint16LE(data.length);
    buf.writeUint16LE(data.length);
    buf.writeBytes(data);
  }

  static void _writeCollation(TdsBuffer buf) {
    // Default collation: en-US, case-insensitive
    buf.writeBytes([0x09, 0x04, 0xD0, 0x00, 0x34]);
  }

  static Uint8List _ucs2(String s) {
    final out = Uint8List(s.length * 2);
    for (int i = 0; i < s.length; i++) {
      out[i * 2] = s.codeUnitAt(i) & 0xFF;
      out[i * 2 + 1] = (s.codeUnitAt(i) >> 8) & 0xFF;
    }
    return out;
  }

  static int _daysSinceYear1(DateTime dt) {
    // Use the date fields (year/month/day) directly with UTC arithmetic so that
    // timezone conversions and DST transitions cannot shift the date component.
    return DateTime.utc(dt.year, dt.month, dt.day)
        .difference(DateTime.utc(1, 1, 1))
        .inDays;
  }
}
