import 'dart:async';
import 'dart:typed_data';

import '../auth/azure_ad_auth.dart';
import '../exception.dart';
import '../info_message.dart';
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

/// Always On / Azure SQL routing target from ENVCHANGE type 20.
class MssqlRoutingInfo {
  /// Alternate server (may be `host` or `host\\instance`).
  final String server;
  final int port;

  const MssqlRoutingInfo({required this.server, required this.port});
}

/// Result of processing the server token stream after LOGIN7.
class LoginResult {
  final String database;
  final String serverVersion;
  final int packetSize;

  /// Present when the server sent ENVCHANGE routing (type 20) — caller must
  /// close and reconnect to [routing] (go-mssqldb / Tedious / ms-tds).
  final MssqlRoutingInfo? routing;

  const LoginResult({
    required this.database,
    required this.serverVersion,
    required this.packetSize,
    this.routing,
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

  /// Invoked when ENVCHANGE type 1 (database) is seen — new database name.
  final void Function(String database)? onDatabaseChanged;

  /// Invoked for each INFO token (`0xAB`) — PRINT / low-severity RAISERROR.
  final void Function(MssqlInfoMessage info)? onInfoMessage;

  /// Last `RETURN` status (`tokenReturnStatus` 0x79) from the most recent
  /// response parse. Cleared at the start of each query response method.
  int? lastReturnStatus;

  /// OUTPUT parameter values from `tokenReturnValue` (0xAC), keyed without `@`.
  final Map<String, Object?> lastReturnValues = {};

  TokenStream(
    this._buf, {
    this.onDatabaseChanged,
    this.onInfoMessage,
  });

  void _clearReturnState() {
    lastReturnStatus = null;
    lastReturnValues.clear();
  }

  /// Process the server response after LOGIN7. Returns basic session metadata.
  ///
  /// [onSspi] is invoked when the server sends a [tokenSSPI] challenge (NTLM
  /// Type 2). The returned bytes are sent as [packSSPIMessage] (Type 3).
  ///
  /// [onFedAuthInfo] is invoked when the server sends [tokenFedAuthInfo]
  /// (ADAL). The returned bearer token is sent as [packFedAuthToken]. If null,
  /// the FEDAUTHINFO payload is skipped (SecurityToken / pre-acquired token
  /// path does not need it).
  Future<LoginResult> processLoginResponse({
    Future<List<int>> Function(Uint8List challenge)? onSspi,
    Future<String> Function(FedAuthInfo info)? onFedAuthInfo,
  }) async {
    String database = '';
    String serverVersion = '';
    int packetSize = defaultPacketSize;
    MssqlRoutingInfo? routing;

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenEnvChange:
          final env = await _readEnvChange();
          if (env.type == envDatabase) {
            database = env.newValue;
            onDatabaseChanged?.call(env.newValue);
          }
          if (env.type == envPacketSize) {
            packetSize = int.tryParse(env.newValue) ?? defaultPacketSize;
          }
          if (env.type == envRouting && env.routing != null) {
            routing = env.routing;
          }
        case tokenLoginAck:
          serverVersion = await _readLoginAck();
        case tokenFeatureExtAck:
          await _skipFeatureExtAck();
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          // Login errors are always fatal and always single; throw immediately.
          throw err;
        case tokenSSPI:
          // USHORT length + SSPI blob (go-mssqldb parseSSPIMsg / ms-tds §2.2.7.22)
          final sspiLen = await _buf.readUint16LE();
          final challenge = await _readTokenBytes(sspiLen, 'SSPI token');
          if (onSspi == null) {
            throw StateError(
              'Server sent SSPI challenge but no NTLM/SSPI handler was provided',
            );
          }
          final response = await onSspi(challenge);
          if (response.isNotEmpty) {
            _buf.beginPacket(packSSPIMessage);
            _buf.writeBytes(response);
            await _buf.finishPacket(packSSPIMessage);
          }
          // SSPI reply continues in the next server message.
          await _buf.beginRead();
        case tokenFedAuthInfo:
          // ULONG size + options (go-mssqldb parseFedAuthInfo / ms-tds §2.2.7.12)
          final info = await _readFedAuthInfo();
          if (onFedAuthInfo != null) {
            final token = await onFedAuthInfo(info);
            await _sendFedAuthToken(token);
            await _buf.beginRead();
          }
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
              routing: routing,
            );
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} during login');
      }
    }
  }

  /// Process the server response and return the first result set.
  ///
  /// Drains all result sets from the stream but discards extras beyond the first.
  /// Use [processAllQueryResponses] when multiple result sets are needed.
  Future<QueryResult> processQueryResponse() async {
    final sets = await processAllQueryResponses();
    if (sets.isEmpty) {
      return QueryResult(columns: [], rows: [], rowsAffected: 0);
    }
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
    _clearReturnState();
    final results = <QueryResult>[];
    List<ColumnMeta>? columns;
    List<List<Object?>> rows = [];
    int rowsAffected = 0;
    final errors = <MssqlException>[];

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          // A new COLMETADATA token starts a new result set.
          if (columns != null && columns.isNotEmpty) {
            _addResultSet(
              results,
              QueryResult(
                  columns: columns, rows: rows, rowsAffected: rowsAffected),
            );
            rows = [];
            rowsAffected = 0;
          }
          columns = await _readColMetadata();
        case tokenRow:
          if (columns == null) throw StateError('ROW token before COLMETADATA');
          rows.add(await _readRow(columns));
        case tokenNbcRow:
          if (columns == null) {
            throw StateError('NBCROW token before COLMETADATA');
          }
          rows.add(await _readNbcRow(columns));
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _applyEnvChange();
        case tokenReturnStatus:
          lastReturnStatus = await _buf.readInt32LE();
        case tokenReturnValue:
          final rv = await _readReturnValue();
          lastReturnValues[rv.$1] = rv.$2;
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          errors.add(err);
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          final count = await _buf.readUint64LE();
          if ((flags & doneFlagCount) != 0) rowsAffected += count;
          if ((flags & doneFlagMore) == 0) {
            final attnAck = (flags & doneFlagAttn) != 0;
            if (attnAck) _buf.attentionSent = false;

            // Flush the last (or only) result set.
            if (columns != null && columns.isNotEmpty) {
              _addResultSet(
                results,
                QueryResult(
                    columns: columns, rows: rows, rowsAffected: rowsAffected),
              );
            } else if (rowsAffected > 0) {
              // DML with no SELECT (INSERT/UPDATE/DELETE) — emit a rowsAffected-only result.
              _addResultSet(
                results,
                QueryResult(columns: [], rows: [], rowsAffected: rowsAffected),
              );
            }
            if (errors.isNotEmpty) throw _buildError(errors);

            // Cancel path: server may send a normal DONE for the aborted batch
            // then a separate Attention ACK message — keep draining until ATTN.
            if (_buf.attentionSent && !attnAck) {
              results.clear();
              columns = null;
              rows = [];
              rowsAffected = 0;
              await _buf.beginRead();
              continue;
            }

            // Attention ACK alone — cancelled query yields no result sets.
            if (attnAck) return <QueryResult>[];

            return results;
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} in query response');
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
    _clearReturnState();
    List<ColumnMeta>? columns;
    // inFirstSet: true only while reading the first COLMETADATA group's rows.
    // Rows from subsequent result sets are read and discarded (not yielded).
    bool inFirstSet = false;
    bool seenFirstSet = false;
    var resultSetCount = 0;
    final errors = <MssqlException>[];

    await _buf.beginRead();

    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          resultSetCount++;
          _buf.limits.checkResultSets(resultSetCount, 'result set count');
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
          if (columns == null) {
            throw StateError('NBCROW token before COLMETADATA');
          }
          final row = await _readNbcRow(columns);
          if (inFirstSet) yield (columns, row);
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _applyEnvChange();
        case tokenReturnStatus:
          lastReturnStatus = await _buf.readInt32LE();
        case tokenReturnValue:
          final rv = await _readReturnValue();
          lastReturnValues[rv.$1] = rv.$2;
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          final err = await _readError();
          errors.add(err);
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE(); // curCmd
          await _buf.readUint64LE(); // rowCount
          if ((flags & doneFlagMore) == 0) {
            final attnAck = (flags & doneFlagAttn) != 0;
            if (attnAck) _buf.attentionSent = false;
            if (errors.isNotEmpty) throw _buildError(errors);
            if (_buf.attentionSent && !attnAck) {
              await _buf.beginRead();
              continue;
            }
            return;
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} in query response');
      }
    }
  }

  /// Drains tokens from the current (or next) response until Attention is ACKed
  /// or a final DONE arrives with [attentionSent] already clear.
  ///
  /// Does not call [TdsBuffer.beginRead] first — caller must already be inside a
  /// message (e.g. after a cancelled [streamQueryResponse]), or must beginRead
  /// themselves before invoking this.
  Future<void> drainUntilAttentionAck() async {
    List<ColumnMeta>? columns;
    var resultSetCount = 0;
    while (true) {
      final tok = await _buf.readUint8();
      switch (tok) {
        case tokenColMetadata:
          resultSetCount++;
          _buf.limits.checkResultSets(resultSetCount, 'result set count');
          columns = await _readColMetadata();
        case tokenRow:
          if (columns == null) {
            throw StateError('ROW token before COLMETADATA while draining');
          }
          await _readRow(columns);
        case tokenNbcRow:
          if (columns == null) {
            throw StateError('NBCROW token before COLMETADATA while draining');
          }
          await _readNbcRow(columns);
        case tokenOrder:
          await _skipOrder();
        case tokenEnvChange:
          await _applyEnvChange();
        case tokenReturnStatus:
          lastReturnStatus = await _buf.readInt32LE();
        case tokenReturnValue:
          final rv = await _readReturnValue();
          lastReturnValues[rv.$1] = rv.$2;
        case tokenInfo:
          await _skipInfoOrError();
        case tokenError:
          await _skipInfoOrError();
        case tokenDone:
        case tokenDoneProc:
        case tokenDoneInProc:
          final flags = await _buf.readUint16LE();
          await _buf.readUint16LE();
          await _buf.readUint64LE();
          if ((flags & doneFlagMore) == 0) {
            final attnAck = (flags & doneFlagAttn) != 0;
            if (attnAck) _buf.attentionSent = false;
            if (_buf.attentionSent && !attnAck) {
              columns = null;
              await _buf.beginRead();
              continue;
            }
            return;
          }
        default:
          throw StateError(
              'Unexpected token 0x${tok.toRadixString(16)} while draining');
      }
    }
  }

  // ── Token readers ──────────────────────────────────────────────────────────

  /// Applies ENVCHANGE side effects (txn descriptor, database callback).
  Future<void> _applyEnvChange() async {
    final env = await _readEnvChange();
    if (env.type == envDatabase) {
      onDatabaseChanged?.call(env.newValue);
    }
  }

  /// Builds the exception to throw when a response contains one or more errors.
  ///
  /// SQL Server convention: the last error in the list is the "primary" one
  /// (e.g. "Could not create constraint — see previous errors"), and earlier
  /// errors give context. We surface the last as the main exception and attach
  /// the full ordered list as [MssqlException.precedingErrors].
  static MssqlException _buildError(List<MssqlException> errors) {
    final last = errors.last;
    if (errors.length == 1) return last;
    return MssqlException(
      last.message,
      errorCode: last.errorCode,
      severity: last.severity,
      state: last.state,
      serverName: last.serverName,
      procName: last.procName,
      lineNo: last.lineNo,
      precedingErrors: errors,
    );
  }

  void _addResultSet(List<QueryResult> results, QueryResult result) {
    _buf.limits.checkResultSets(results.length + 1, 'result set count');
    results.add(result);
  }

  Future<Uint8List> _readTokenBytes(int length, String context) {
    _buf.limits.checkTokenBytes(length, context);
    return _buf.readBytes(length);
  }

  static void _requireBytes(
    List<int> data,
    int offset,
    int length,
    String context,
  ) {
    if (offset < 0 || length < 0 || offset + length > data.length) {
      throw FormatException(
        '$context exceeds token body at offset $offset length $length '
        '(body ${data.length} bytes)',
      );
    }
  }

  static int _uint16LEAt(List<int> data, int offset, String context) {
    _requireBytes(data, offset, 2, context);
    return data[offset] | (data[offset + 1] << 8);
  }

  static int _int32LEAt(List<int> data, int offset, String context) {
    _requireBytes(data, offset, 4, context);
    final v = data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  static (String, int) _readBVarCharFrom(
    List<int> data,
    int offset,
    String context,
  ) {
    _requireBytes(data, offset, 1, '$context length');
    final chars = data[offset];
    final start = offset + 1;
    final byteLength = chars * 2;
    _requireBytes(data, start, byteLength, context);
    return (
      _ucs2String(data.sublist(start, start + byteLength), context),
      start + byteLength
    );
  }

  Future<String> _readLoginAck() async {
    final length = await _buf.readUint16LE();
    final data = await _readTokenBytes(length, 'LOGINACK token');
    _requireBytes(data, 0, 10, 'LOGINACK token');
    final nameLen = data[5];
    final nameEnd = 6 + nameLen * 2;
    _requireBytes(data, 6, nameLen * 2, 'LOGINACK program name');
    _requireBytes(data, nameEnd, 4, 'LOGINACK program version');
    return _ucs2String(data.sublist(6, nameEnd), 'LOGINACK program name');
  }

  Future<void> _skipFeatureExtAck() async {
    while (true) {
      final featureId = await _buf.readUint8();
      if (featureId == featExtTerminator) break;
      final len = await _buf.readUint32LE();
      await _readTokenBytes(len, 'FEATUREEXTACK token');
    }
  }

  /// Parses [tokenFedAuthInfo] body (size already unread — reads ULONG size).
  Future<FedAuthInfo> _readFedAuthInfo() async {
    final size = await _buf.readUint32LE();
    _buf.limits.checkTokenBytes(size, 'FEDAUTHINFO token');
    if (size < 4) {
      throw FormatException('FEDAUTHINFO token size $size is smaller than 4');
    }
    final count = await _buf.readUint32LE();
    var offset = 4; // bytes consumed within [size] after reading count
    final opts = <({int id, int dataLength, int dataOffset})>[];
    for (var i = 0; i < count; i++) {
      if (offset + 9 > size) {
        throw FormatException('FEDAUTHINFO option table exceeds token size');
      }
      final id = await _buf.readUint8();
      final dataLength = await _buf.readUint32LE();
      final dataOffset = await _buf.readUint32LE();
      _buf.limits.checkTokenBytes(dataLength, 'FEDAUTHINFO option');
      offset += 1 + 4 + 4;
      opts.add((id: id, dataLength: dataLength, dataOffset: dataOffset));
    }
    final remaining = size - offset;
    if (remaining < 0) {
      throw FormatException('FEDAUTHINFO option table exceeds token size');
    }
    final data = remaining > 0
        ? await _readTokenBytes(remaining, 'FEDAUTHINFO token')
        : <int>[];

    var stsUrl = '';
    var spn = '';
    for (final opt in opts) {
      if (opt.dataOffset < offset) {
        throw FormatException(
          'FEDAUTHINFO dataOffset ${opt.dataOffset} < header end $offset',
        );
      }
      final start = opt.dataOffset - offset;
      final end = start + opt.dataLength;
      if (end > data.length) {
        throw FormatException('FEDAUTHINFO option exceeds token size');
      }
      final raw = data.sublist(start, end);
      final text = _ucs2String(raw, 'FEDAUTHINFO option');
      switch (opt.id) {
        case fedAuthInfoStsUrl:
          stsUrl = text;
        case fedAuthInfoSpn:
          spn = text;
        default:
          // Unknown option — ignore (forward compatible).
          break;
      }
    }
    return FedAuthInfo(stsUrl: stsUrl, serverSpn: spn);
  }

  Future<void> _sendFedAuthToken(String token,
      {List<int> nonce = const []}) async {
    // go-mssqldb sendFedAuthToken / ms-tds packFedAuthToken (type 8)
    final tokenBytes = _ucs2Bytes(token);
    final dataLen = 4 + tokenBytes.length + nonce.length;
    _buf.beginPacket(packFedAuthToken);
    _buf.writeUint32LE(dataLen);
    _buf.writeUint32LE(tokenBytes.length);
    _buf.writeBytes(tokenBytes);
    if (nonce.isNotEmpty) _buf.writeBytes(nonce);
    await _buf.finishPacket(packFedAuthToken);
  }

  static String _ucs2String(List<int> bytes, String context) {
    if (bytes.length.isOdd) {
      throw FormatException(
        '$context has odd UTF-16LE byte length ${bytes.length}',
      );
    }
    final codes = <int>[];
    for (var i = 0; i < bytes.length; i += 2) {
      codes.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(codes);
  }

  static Uint8List _ucs2Bytes(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      out[i * 2] = c & 0xFF;
      out[i * 2 + 1] = (c >> 8) & 0xFF;
    }
    return out;
  }

  Future<_EnvChange> _readEnvChange() async {
    final length = await _buf.readUint16LE();
    final data = await _readTokenBytes(length, 'ENVCHANGE token');
    _requireBytes(data, 0, 1, 'ENVCHANGE token');
    final type = data[0];
    int i = 1;

    if (type == envSqlCollation) {
      return _EnvChange(type: type);
    }

    if (type == envRouting) {
      // NEWVALUE = RoutingData: USHORT len + Protocol BYTE + Port USHORT +
      // AlternateServer US_VARCHAR; OLDVALUE = 0x00 0x00
      // (go-mssqldb processEnvChg / ms-tds §2.2.7.9 type 20).
      final routingValueLen = _uint16LEAt(data, i, 'ENVCHANGE routing length');
      i += 2;
      _requireBytes(data, i, routingValueLen, 'ENVCHANGE routing new value');
      final protocol = data[i++];
      if (protocol != 0) return _EnvChange(type: type);
      final port = _uint16LEAt(data, i, 'ENVCHANGE routing port');
      i += 2;
      final nameChars = _uint16LEAt(data, i, 'ENVCHANGE routing server length');
      i += 2;
      final nameEnd = i + nameChars * 2;
      _requireBytes(data, i, nameChars * 2, 'ENVCHANGE routing server');
      final server = _ucs2String(
        data.sublist(i, nameEnd),
        'ENVCHANGE routing server',
      );
      return _EnvChange(
        type: type,
        routing: MssqlRoutingInfo(
          server: server,
          port: port,
        ),
      );
    }

    if (type == envBeginTran) {
      final newLen = data.length > 1 ? data[1] : 0;
      if (newLen == 8 && data.length >= 10) {
        _buf.transactionDescriptor = data[2] |
            (data[3] << 8) |
            (data[4] << 16) |
            (data[5] << 24) |
            (data[6] << 32) |
            (data[7] << 40) |
            (data[8] << 48) |
            (data[9] << 56);
      }
      return _EnvChange(type: type);
    }
    if (type == envCommitTran || type == envRollbackTran) {
      _buf.transactionDescriptor = 0;
      return _EnvChange(type: type);
    }

    final (newVal, afterNew) =
        _readBVarCharFrom(data, i, 'ENVCHANGE new value');
    i = afterNew;
    final (oldVal, _) = _readBVarCharFrom(data, i, 'ENVCHANGE old value');
    return _EnvChange(type: type, newValue: newVal, oldValue: oldVal);
  }

  Future<MssqlException> _readError() async {
    final info = await _readInfoOrErrorMessage();
    return MssqlException(
      info.message,
      errorCode: info.number,
      severity: info.severity,
      state: info.state,
      serverName: info.serverName.isEmpty ? null : info.serverName,
      procName: info.procName.isEmpty ? null : info.procName,
      lineNo: info.lineNo,
    );
  }

  Future<void> _skipInfoOrError() async {
    final info = await _readInfoOrErrorMessage();
    onInfoMessage?.call(info);
  }

  /// Parses INFO/ERROR body — go-mssqldb `parseInfo` / `parseError72`.
  Future<MssqlInfoMessage> _readInfoOrErrorMessage() async {
    final length = await _buf.readUint16LE();
    final data = await _readTokenBytes(length, 'INFO/ERROR token');
    int i = 0;
    final signedNumber = _int32LEAt(data, i, 'INFO/ERROR number');
    i += 4;
    _requireBytes(data, i, 4, 'INFO/ERROR header');
    final state = data[i++];
    final severity = data[i++];
    final msgLen = _uint16LEAt(data, i, 'INFO/ERROR message length');
    i += 2;
    final msgByteLen = msgLen * 2;
    _requireBytes(data, i, msgByteLen, 'INFO/ERROR message');
    final message =
        _ucs2String(data.sublist(i, i + msgByteLen), 'INFO/ERROR message');
    i += msgByteLen;

    final (serverName, afterServer) =
        _readBVarCharFrom(data, i, 'INFO/ERROR server name');
    i = afterServer;
    final (procName, afterProc) =
        _readBVarCharFrom(data, i, 'INFO/ERROR procedure name');
    i = afterProc;
    final lineNo = _int32LEAt(data, i, 'INFO/ERROR line number');

    return MssqlInfoMessage(
      number: signedNumber,
      state: state,
      severity: severity,
      message: message,
      serverName: serverName,
      procName: procName,
      lineNo: lineNo,
    );
  }

  Future<void> _skipOrder() async {
    final length = await _buf.readUint16LE();
    await _readTokenBytes(length, 'ORDER token');
  }

  /// Reads a RETURNVALUE token (0xAC) — OUTPUT / return parameter.
  ///
  /// Layout matches go-mssqldb `parseReturnValue` / ms-tds §2.2.7.15:
  /// ParamOrdinal, ParamName, Status, UserType, Flags, TypeInfo, Value.
  Future<(String, Object?)> _readReturnValue() async {
    await _buf.readUint16LE(); // OrdinalNum
    final nameLen = await _buf.readUint8();
    var name = '';
    if (nameLen > 0) {
      final nameBytes = await _readTokenBytes(nameLen * 2, 'RETURNVALUE name');
      name = _ucs2String(nameBytes, 'RETURNVALUE name');
    }
    if (name.startsWith('@')) name = name.substring(1);
    await _buf.readUint8(); // Status
    await _buf.readUint32LE(); // UserType
    await _buf.readUint16LE(); // Flags
    final ti = await TypeInfo.read(_buf);
    final value = await ti.readValue(_buf);
    return (name, value);
  }

  Future<List<ColumnMeta>> _readColMetadata() async {
    final count = await _buf.readUint16LE();
    if (count == 0xFFFF) return [];
    _buf.limits.checkColumns(count, 'column count');

    final cols = <ColumnMeta>[];
    for (int i = 0; i < count; i++) {
      final userType = await _buf.readUint32LE();
      final flags = await _buf.readUint16LE();
      final ti = await TypeInfo.read(_buf);
      // TEXT/NTEXT/IMAGE columns carry a multi-part TableName in COLMETADATA (TDS 7.2+):
      // 1 byte numParts, then for each part: UINT16 char count + UTF-16LE chars.
      // Computed (CAST) columns send numParts = 0. ms-tds §2.2.7.4; confirmed by
      // tedious colmetadata-token-parser.js and go-mssqldb types.go.
      if (ti.typeId == typeText ||
          ti.typeId == typeNText ||
          ti.typeId == typeImage) {
        final numParts = await _buf.readUint8();
        for (int p = 0; p < numParts; p++) {
          final partLen = await _buf.readUint16LE();
          if (partLen > 0) {
            await _readTokenBytes(partLen * 2, 'COLMETADATA table name');
          }
        }
      }
      final nameLen = await _buf.readUint8();
      final nameBytes = await _readTokenBytes(nameLen * 2, 'COLMETADATA name');
      final name = _ucs2String(nameBytes, 'COLMETADATA name');
      cols.add(ColumnMeta(
          name: name, typeInfo: ti, userType: userType, flags: flags));
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
    final bitmap = await _readTokenBytes(bitmapBytes, 'NBCROW null bitmap');

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

class _EnvChange {
  final int type;
  final String newValue;
  final String oldValue;
  final MssqlRoutingInfo? routing;

  const _EnvChange({
    required this.type,
    this.newValue = '',
    this.oldValue = '',
    this.routing,
  });
}
