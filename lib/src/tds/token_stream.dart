import '../exception.dart';
import 'buf.dart';
import 'constants.dart';
import 'type_info.dart';

/// A fully parsed column descriptor.
class ColumnMeta {
  final String name;
  final TypeInfo typeInfo;
  final int userType;
  final int flags;

  const ColumnMeta({
    required this.name,
    required this.typeInfo,
    required this.userType,
    required this.flags,
  });

  bool get nullable => (flags & 0x01) != 0;
}

/// Result of processing the server token stream after LOGIN7.
class LoginResult {
  final String database;
  final String serverVersion;
  final int packetSize;

  const LoginResult({
    required this.database,
    required this.serverVersion,
    required this.packetSize,
  });
}

/// Result of processing a query's token stream.
class QueryResult {
  final List<ColumnMeta> columns;
  final List<List<Object?>> rows;
  final int rowsAffected;

  const QueryResult({
    required this.columns,
    required this.rows,
    required this.rowsAffected,
  });
}

/// Processes the TDS response token stream from the server.
///
/// A single call to [processResponse] reads tokens until a final DONE token.
/// It handles COLMETADATA, ROW, NBCROW, ENVCHANGE, ERROR, INFO, and DONE tokens.
class TokenStream {
  final TdsBuffer _buf;

  TokenStream(this._buf);

  /// Process the server response after LOGIN7. Returns basic session metadata.
  Future<LoginResult> processLoginResponse() async {
    String database = '';
    String serverVersion = '';
    int packetSize = defaultPacketSize;

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenEnvChange:
          final env = await _readEnvChange();
          if (env.$1 == envDatabase) database = env.$2;
          if (env.$1 == envPacketSize) {
            packetSize = int.tryParse(env.$2) ?? defaultPacketSize;
          }
        case tokenLoginAck:
          serverVersion = await _readLoginAck();
        case tokenFeatureExtAck:
          await _skipFeatureExtAck();
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          throw MssqlException(err.$1, errorCode: err.$2);
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          await _buf.readUint64LE(); // rowCount
          if ((flags & doneFlagMore) == 0) {
            return LoginResult(
              database: database,
              serverVersion: serverVersion,
              packetSize: packetSize,
            );
          }
        default:
          throw StateError('Unexpected token 0x${tok.toRadixString(16)} during login');
      }
    }
  }

  /// Process the server response after a query packet.
  Future<QueryResult> processQueryResponse() async {
    List<ColumnMeta>? columns;
    final rows = <List<Object?>>[];
    int rowsAffected = 0;
    // Accumulate the first error rather than throwing immediately, so we always
    // read through to the final DONE token and leave the stream clean for the
    // next query (avoids stale-packet corruption on multi-packet error responses).
    MssqlException? pendingError;

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          columns = await _readColMetadata();
        case tokenRow:
          if (columns == null) throw StateError('ROW token before COLMETADATA');
          rows.add(await _readRow(columns));
        case tokenNbcRow:
          if (columns == null) throw StateError('NBCROW token before COLMETADATA');
          rows.add(await _readNbcRow(columns));
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _readEnvChange(); // discard but consume
        case tokenReturnStatus:
          await _buf.readUint32LE(); // consume return status
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          pendingError ??= MssqlException(err.$1, errorCode: err.$2);
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          final count = await _buf.readUint64LE();
          if ((flags & doneFlagCount) != 0) rowsAffected = count;
          if ((flags & doneFlagMore) == 0) {
            if (pendingError != null) throw pendingError;
            return QueryResult(
              columns: columns ?? [],
              rows: rows,
              rowsAffected: rowsAffected,
            );
          }
        default:
          throw StateError('Unexpected token 0x${tok.toRadixString(16)} in query response');
      }
    }
  }

  // ── Token readers ──────────────────────────────────────────────────────────

  Future<String> _readLoginAck() async {
    final length = await _buf.readUint16LE();
    final data = await _buf.readBytes(length);
    // data[0] = interface (1 = SQL), data[1..4] = tds version, rest = prog name + ver
    // Extract program version (last 4 bytes: major, minor, build hi, build lo)
    final nameLen = data[5]; // BVarChar length (char count)
    final nameBytes = data.sublist(6, 6 + nameLen * 2);
    final name = String.fromCharCodes(
      [for (int i = 0; i < nameBytes.length; i += 2) nameBytes[i] | (nameBytes[i + 1] << 8)],
    );
    return name;
  }

  Future<void> _skipFeatureExtAck() async {
    while (true) {
      final featureId = await _buf.readUint8();
      if (featureId == featExtTerminator) break;
      final len = await _buf.readUint32LE();
      await _buf.readBytes(len);
    }
  }

  Future<(int, String, String)> _readEnvChange() async {
    final length = await _buf.readUint16LE();
    final data = await _buf.readBytes(length);
    final type = data[0];
    int i = 1;

    // SQL Collation and routing use non-string formats; discard.
    if (type == envSqlCollation || type == envRouting) {
      return (type, '', '');
    }

    // Transaction lifecycle: parse/reset the 8-byte transaction descriptor.
    if (type == envBeginTran) {
      final newLen = data.length > 1 ? data[1] : 0;
      if (newLen == 8 && data.length >= 10) {
        _buf.transactionDescriptor =
            data[2] | (data[3] << 8) | (data[4] << 16) | (data[5] << 24) |
            (data[6] << 32) | (data[7] << 40) | (data[8] << 48) | (data[9] << 56);
      }
      return (type, '', '');
    }
    if (type == envCommitTran || type == envRollbackTran) {
      _buf.transactionDescriptor = 0; // back to autocommit
      return (type, '', '');
    }

    // Standard B_VARCHAR: BYTE(charCount) + charCount * 2 bytes UTF-16LE
    String readBVarChar() {
      final len = data[i++];
      final chars = <int>[];
      for (int j = 0; j < len; j++) {
        chars.add(data[i] | (data[i + 1] << 8));
        i += 2;
      }
      return String.fromCharCodes(chars);
    }

    final newVal = readBVarChar();
    final oldVal = readBVarChar();
    return (type, newVal, oldVal);
  }

  Future<(String, int)> _readError() async => _readInfoOrError();

  Future<void> _skipInfoOrError() async {
    await _readInfoOrError();
  }

  Future<(String, int)> _readInfoOrError() async {
    final length = await _buf.readUint16LE();
    final data = await _buf.readBytes(length);
    int i = 0;
    final number = data[i] | (data[i+1] << 8) | (data[i+2] << 16) | (data[i+3] << 24);
    i += 4;
    i++; // state
    i++; // class
    // message: USVarChar (uint16 len in chars)
    final msgLen = data[i] | (data[i + 1] << 8); i += 2;
    final chars = <int>[];
    for (int j = 0; j < msgLen; j++) {
      chars.add(data[i] | (data[i + 1] << 8));
      i += 2;
    }
    final message = String.fromCharCodes(chars);
    return (message, number);
  }

  Future<void> _skipOrder() async {
    final length = await _buf.readUint16LE();
    await _buf.readBytes(length);
  }

  Future<List<ColumnMeta>> _readColMetadata() async {
    final count = await _buf.readUint16LE();
    if (count == 0xFFFF) return []; // no metadata (e.g. for INSERT)

    final cols = <ColumnMeta>[];
    for (int i = 0; i < count; i++) {
      final userType = await _buf.readUint32LE();
      final flags = await _buf.readUint16LE();
      final ti = await TypeInfo.read(_buf);
      // ColName: BVarChar (length in chars, UTF-16LE)
      final nameLen = await _buf.readUint8();
      final nameBytes = await _buf.readBytes(nameLen * 2);
      final name = String.fromCharCodes(
        [for (int j = 0; j < nameBytes.length; j += 2) nameBytes[j] | (nameBytes[j + 1] << 8)],
      );
      cols.add(ColumnMeta(name: name, typeInfo: ti, userType: userType, flags: flags));
    }
    return cols;
  }

  Future<List<Object?>> _readRow(List<ColumnMeta> cols) async {
    final row = <Object?>[];
    for (final col in cols) {
      row.add(await col.typeInfo.readValue(_buf));
    }
    return row;
  }

  Future<List<Object?>> _readNbcRow(List<ColumnMeta> cols) async {
    // Null-bitmap compressed row: bitmap covers all columns.
    final bitmapBytes = (cols.length + 7) >> 3;
    final bitmap = await _buf.readBytes(bitmapBytes);

    bool isNull(int i) => (bitmap[i >> 3] & (1 << (i & 7))) != 0;

    final row = <Object?>[];
    for (int i = 0; i < cols.length; i++) {
      if (isNull(i)) {
        row.add(null);
      } else {
        row.add(await cols[i].typeInfo.readValue(_buf));
      }
    }
    return row;
  }
}
