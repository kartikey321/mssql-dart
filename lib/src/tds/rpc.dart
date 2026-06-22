import 'dart:typed_data';

import 'buf.dart';
import 'constants.dart';

/// Sends an RPC request using sp_executesql for parameterised queries.
///
/// ms-tds §2.2.6.5 RPC Request
class RpcRequest {
  // Well-known RPC procedure IDs (ProcIDSwitch)
  static const int _spExecuteSql = 10;

  /// Sends [sql] as a direct SQL batch (packSQLBatch) without sp_executesql.
  /// Use for parameterless statements, especially DDL — temp tables created
  /// inside sp_executesql are scoped to that call, not the session.
  static Future<void> sendBatch(TdsBuffer buf, String sql) async {
    buf.beginPacket(packSQLBatch);
    _writeAllHeaders(buf);
    buf.writeBytes(_ucs2(sql));
    await buf.finishPacket(packSQLBatch);
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
    buf.writeUint64LE(buf.transactionDescriptor); // updated by server ENVCHANGE type 8
    buf.writeUint32LE(1); // outstanding requests
  }

  static String _buildParamDecl(Map<String, Object?> params) {
    return params.entries.map((e) {
      final typeName = _dartTypeToSql(e.value);
      return '@${e.key} $typeName';
    }).join(', ');
  }

  static String _dartTypeToSql(Object? v) {
    if (v == null) return 'nvarchar(max)';
    if (v is int) return 'bigint';
    if (v is double) return 'float';
    if (v is bool) return 'bit';
    if (v is String) return 'nvarchar(${v.length > 4000 ? 'max' : '4000'})';
    if (v is DateTime) return 'datetime2';
    if (v is List<int>) return 'varbinary(max)';
    return 'nvarchar(max)';
  }

  static void _writeParam(TdsBuffer buf, String name, Object? value) {
    // ParamName: BVarChar — must include the '@' prefix to match the @params declaration.
    final nameBytes = _ucs2('@$name');
    buf.writeByte(nameBytes.length >> 1);
    buf.writeBytes(nameBytes);

    // StatusFlags: 0 (input)
    buf.writeByte(0x00);

    if (value == null) {
      // nvarchar(1), null value
      buf.writeByte(typeNVarChar);
      buf.writeUint16LE(2); // max length hint
      _writeCollation(buf);
      buf.writeUint16LE(0xFFFF); // null
      return;
    }

    switch (value) {
      case int v:
        buf.writeByte(typeIntN);
        buf.writeByte(8); // max len
        buf.writeByte(8); // actual len
        // Write as two 32-bit halves to avoid 64-bit literal overflow.
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
        _writeNVarCharParam(buf, name, v, isOutput: false, skipName: true);
      case DateTime v:
        _writeDateTimeParam(buf, v);
      case List<int> v:
        _writeBinaryParam(buf, Uint8List.fromList(v));
      default:
        final s = value.toString();
        _writeNVarCharParam(buf, name, s, isOutput: false, skipName: true);
    }
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
      buf.writeByte(isOutput ? 0x01 : 0x00);
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
    final epoch = DateTime.utc(1, 1, 1);
    return dt.toUtc().difference(epoch).inDays;
  }
}
