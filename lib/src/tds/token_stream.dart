import 'dart:async';

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

  /// Process the server response and return the first result set.
  ///
  /// Drains all result sets from the stream but discards extras beyond the first.
  /// Use [processAllQueryResponses] when multiple result sets are needed.
  Future<QueryResult> processQueryResponse() async {
    final sets = await processAllQueryResponses();
    if (sets.isEmpty) return QueryResult(columns: [], rows: [], rowsAffected: 0);
    // Sum rowsAffected across all sets (matches node-mssql behaviour for DML).
    final totalAffected = sets.fold(0, (s, r) => s + r.rowsAffected);
    final first = sets.first;
    if (sets.length == 1) return first;
    return QueryResult(
      columns: first.columns,
      rows: first.rows,
      rowsAffected: totalAffected,
    );
  }

  /// Process the server response and return every result set.
  ///
  /// Stored procedures that execute multiple SELECT statements produce one
  /// [QueryResult] per SELECT, each with its own column schema and rows.
  Future<List<QueryResult>> processAllQueryResponses() async {
    final results = <QueryResult>[];
    List<ColumnMeta>? columns;
    List<List<Object?>> rows = [];
    int rowsAffected = 0;
    MssqlException? pendingError;

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          // A new COLMETADATA token starts a new result set.
          if (columns != null && columns.isNotEmpty) {
            results.add(QueryResult(columns: columns, rows: rows, rowsAffected: rowsAffected));
            rows = [];
            rowsAffected = 0;
          }
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
          await _readEnvChange();
        case tokenReturnStatus:
          await _buf.readUint32LE();
        case tokenReturnValue:
          await _skipReturnValue();
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
          if ((flags & doneFlagCount) != 0) rowsAffected += count;
          if ((flags & doneFlagMore) == 0) {
            // Flush the last (or only) result set.
            if (columns != null && columns.isNotEmpty) {
              results.add(QueryResult(columns: columns, rows: rows, rowsAffected: rowsAffected));
            } else if (rowsAffected > 0) {
              // DML with no SELECT (INSERT/UPDATE/DELETE) — emit a rowsAffected-only result.
              results.add(QueryResult(columns: [], rows: [], rowsAffected: rowsAffected));
            }
            if (pendingError != null) throw pendingError;
            return results;
          }
        default:
          throw StateError('Unexpected token 0x${tok.toRadixString(16)} in query response');
      }
    }
  }

  /// Streams rows from the server response one at a time.
  ///
  /// Yields rows as they arrive from the network — useful for large result sets
  /// where buffering all rows would be expensive. Only the first result set is
  /// streamed; subsequent sets (from stored procedures) are drained and discarded.
  ///
  /// The stream emits `(columns, row)` pairs so callers always have schema info.
  Stream<(List<ColumnMeta>, List<Object?>)> streamQueryResponse() async* {
    List<ColumnMeta>? columns;
    // inFirstSet: true only while reading the first COLMETADATA group's rows.
    // Rows from subsequent result sets are read and discarded (not yielded).
    bool inFirstSet = false;
    bool seenFirstSet = false;
    MssqlException? pendingError;

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          columns = await _readColMetadata();
          if (!seenFirstSet) {
            seenFirstSet = true;
            inFirstSet = true;
          } else {
            inFirstSet = false; // second+ result set — drain without yielding
          }
        case tokenRow:
          if (columns == null) throw StateError('ROW token before COLMETADATA');
          final row = await _readRow(columns);
          if (inFirstSet) yield (columns, row);
        case tokenNbcRow:
          if (columns == null) throw StateError('NBCROW token before COLMETADATA');
          final row = await _readNbcRow(columns);
          if (inFirstSet) yield (columns, row);
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _readEnvChange();
        case tokenReturnStatus:
          await _buf.readUint32LE();
        case tokenReturnValue:
          await _skipReturnValue();
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
          await _buf.readUint64LE(); // rowCount
          if ((flags & doneFlagMore) == 0) {
            if (pendingError != null) throw pendingError;
            return;
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
    final nameLen = data[5];
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

    if (type == envSqlCollation || type == envRouting) {
      return (type, '', '');
    }

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
      _buf.transactionDescriptor = 0;
      return (type, '', '');
    }

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

  /// Reads and discards a RETURNVALUE token (0xAC).
  ///
  /// Appears in stored procedure responses for OUTPUT parameters.
  /// ms-tds §2.2.7.15 RETURNVALUE.
  Future<void> _skipReturnValue() async {
    await _buf.readUint16LE(); // OrdinalNum
    final nameLen = await _buf.readUint8();
    if (nameLen > 0) await _buf.readBytes(nameLen * 2); // ParamName (UCS-2)
    await _buf.readUint8(); // Status
    await _buf.readUint32LE(); // UserType
    await _buf.readUint16LE(); // Flags
    final ti = await TypeInfo.read(_buf);
    await ti.readValue(_buf); // read and discard the value
  }

  Future<List<ColumnMeta>> _readColMetadata() async {
    final count = await _buf.readUint16LE();
    if (count == 0xFFFF) return [];

    final cols = <ColumnMeta>[];
    for (int i = 0; i < count; i++) {
      final userType = await _buf.readUint32LE();
      final flags = await _buf.readUint16LE();
      final ti = await TypeInfo.read(_buf);
      // TEXT/NTEXT/IMAGE columns carry a multi-part TableName in COLMETADATA (TDS 7.2+):
      // 1 byte numParts, then for each part: UINT16 char count + UTF-16LE chars.
      // Computed (CAST) columns send numParts = 0. ms-tds §2.2.7.4; confirmed by
      // tedious colmetadata-token-parser.js and go-mssqldb types.go.
      if (ti.typeId == typeText || ti.typeId == typeNText || ti.typeId == typeImage) {
        final numParts = await _buf.readUint8();
        for (int p = 0; p < numParts; p++) {
          final partLen = await _buf.readUint16LE();
          if (partLen > 0) await _buf.readBytes(partLen * 2);
        }
      }
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
