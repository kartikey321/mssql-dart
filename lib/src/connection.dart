import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'auth/azure_ad_auth.dart';
import 'auth/sql_auth.dart';
import 'exception.dart';
import 'result.dart';
import 'tds/buf.dart';
import 'tds/constants.dart';
import 'tds/login7.dart';
import 'tds/prelogin.dart';
import 'tds/rpc.dart';
import 'tds/token_stream.dart';

/// Opens and manages a single connection to SQL Server.
///
/// ```dart
/// final conn = await MssqlConnection.connect(
///   host: 'localhost',
///   port: 1433,
///   user: 'sa',
///   password: 'YourPassword',
///   database: 'master',
/// );
/// final result = await conn.query('SELECT name FROM sys.tables');
/// for (final row in result) print(row['name']);
/// await conn.close();
/// ```
class MssqlConnection {
  final String _host;
  final int _port;
  final String _database;
  final SqlAuth? _sqlAuth;
  final AzureAdAuth? _azureAdAuth;
  final bool _encrypt;
  final bool _trustServerCertificate;
  final Duration _timeout;

  late TdsBuffer _buf;
  late Socket _socket;
  bool _connected = false;
  String _currentDatabase = '';

  MssqlConnection._({
    required String host,
    required int port,
    required String database,
    SqlAuth? sqlAuth,
    AzureAdAuth? azureAdAuth,
    required bool encrypt,
    required bool trustServerCertificate,
    required Duration timeout,
  })  : _host = host,
        _port = port,
        _database = database,
        _sqlAuth = sqlAuth,
        _azureAdAuth = azureAdAuth,
        _encrypt = encrypt,
        _trustServerCertificate = trustServerCertificate,
        _timeout = timeout;

  // ── Factory constructors ───────────────────────────────────────────────────

  /// Connects using SQL Server authentication (username + password).
  ///
  /// [encrypt] — whether to negotiate TLS (default `true`). Set to `false`
  /// only for local dev containers that don't support TLS.
  ///
  /// [trustServerCertificate] — accept self-signed or untrusted certificates.
  /// Required for local Docker SQL Server instances. Has no effect when
  /// [encrypt] is `false`.
  static Future<MssqlConnection> connect({
    required String host,
    int port = defaultPort,
    required String user,
    required String password,
    String database = '',
    bool encrypt = true,
    bool trustServerCertificate = false,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return MssqlConnection._(
      host: host,
      port: port,
      database: database,
      sqlAuth: SqlAuth(username: user, password: password),
      encrypt: encrypt,
      trustServerCertificate: trustServerCertificate,
      timeout: timeout,
    )._open();
  }

  /// Connects using Azure AD authentication (bearer token).
  static Future<MssqlConnection> connectAzureAd({
    required String host,
    int port = defaultPort,
    required AzureAdAuth azureAdAuth,
    String database = '',
    bool trustServerCertificate = false,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return MssqlConnection._(
      host: host,
      port: port,
      database: database,
      azureAdAuth: azureAdAuth,
      encrypt: true, // Azure AD always requires TLS
      trustServerCertificate: trustServerCertificate,
      timeout: timeout,
    )._open();
  }

  // ── Public query API ───────────────────────────────────────────────────────

  /// Executes [sql] with optional named [parameters] and returns all rows.
  ///
  /// Use `@paramName` placeholders:
  /// ```dart
  /// await conn.query('SELECT * FROM users WHERE id = @id', {'id': 42});
  /// ```
  Future<MssqlResult> query(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    _assertOpen();
    await _send(sql, parameters);
    final internal = await TokenStream(_buf).processQueryResponse();
    return MssqlResult(internal: internal);
  }

  /// Executes [sql] and returns all result sets (one per SELECT statement).
  ///
  /// Use this when calling stored procedures that return multiple SELECT results.
  ///
  /// ```dart
  /// final multi = await conn.queryMultiple('EXEC dbo.MyProc');
  /// final users = multi.first;
  /// final orders = multi.second;
  /// ```
  Future<MssqlMultiResult> queryMultiple(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    _assertOpen();
    await _send(sql, parameters);
    final sets = await TokenStream(_buf).processAllQueryResponses();
    return MssqlMultiResult(sets);
  }

  /// Streams rows one at a time without buffering the full result set.
  ///
  /// Rows are yielded as they arrive from the network. Useful for large result
  /// sets. Only the first result set is streamed; extras are drained silently.
  ///
  /// ```dart
  /// await for (final row in conn.queryStream('SELECT * FROM bigTable')) {
  ///   process(row);
  /// }
  /// ```
  Stream<MssqlRow> queryStream(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async* {
    _assertOpen();
    await _send(sql, parameters);
    await for (final (cols, values) in TokenStream(_buf).streamQueryResponse()) {
      yield MssqlRow(cols, values);
    }
  }

  /// Executes [sql] and returns the number of rows affected.
  Future<int> execute(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final result = await query(sql, parameters);
    return result.rowsAffected;
  }

  /// The database currently active on this connection.
  String get database => _currentDatabase;

  /// Whether this connection is open.
  bool get isOpen => _connected;

  /// Closes the connection.
  Future<void> close() async {
    _connected = false;
    await _socket.close();
  }

  // ── Transaction helpers ────────────────────────────────────────────────────

  Future<void> beginTransaction() => execute('BEGIN TRANSACTION');
  Future<void> commitTransaction() => execute('COMMIT TRANSACTION');
  Future<void> rollbackTransaction() => execute('ROLLBACK TRANSACTION');

  /// Runs [fn] inside a transaction; commits on success, rolls back on error.
  Future<T> transaction<T>(Future<T> Function(MssqlConnection conn) fn) async {
    await beginTransaction();
    try {
      final result = await fn(this);
      await commitTransaction();
      return result;
    } catch (_) {
      await rollbackTransaction();
      rethrow;
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<MssqlConnection> _open() async {
    // 1. TCP
    _socket = await Socket.connect(_host, _port, timeout: _timeout);
    _buf = TdsBuffer(_socket);

    // 2. PRELOGIN
    // encryptNotSupported (0x02) = client cannot do TLS → server skips it.
    // encryptOn (0x01) = request TLS → required for production / Azure SQL.
    final wantEncrypt = (_encrypt || _azureAdAuth != null)
        ? encryptOn
        : encryptNotSupported;

    await Prelogin.send(_buf, requestEncrypt: wantEncrypt, fedAuthRequired: _azureAdAuth != null);
    final prelogin = await Prelogin.read(_buf);

    // 3. TLS upgrade (only if both sides agreed to encrypt)
    if (prelogin.requiresTls) {
      await _upgradeTls();
    } else if (_encrypt && _azureAdAuth == null) {
      throw MssqlException(
        'Server does not support encryption. '
        'Pass encrypt: false for local dev containers that do not have TLS.',
      );
    }

    // 4. LOGIN7
    await _sendLogin7();

    // 5. Login response
    final loginResult = await TokenStream(_buf).processLoginResponse();
    _currentDatabase = loginResult.database;
    _buf.packetSize = loginResult.packetSize;
    _connected = true;
    return this;
  }

  /// Performs the TDS-wrapped TLS handshake (ms-tds §2.1.1 PRELOGIN encryption).
  ///
  /// SQL Server wraps TLS handshake messages inside TDS PRELOGIN packets.
  /// After the handshake, subsequent packets are sent as raw TLS records.
  ///
  /// Architecture (modeled on go-mssqldb's tlsHandshakeConn + passthroughConn):
  ///
  ///   _buf writes → _socket(=tls) → encrypt → secSide → loopback → bridgeSide
  ///   bridgeSide → rawSocket  (forwarded: raw encrypted TLS bytes)
  ///
  ///   rawSocket → rawReader (bridge loop) → unwrap/pass-through → bridgeSide
  ///   bridgeSide → loopback → secSide → tls decrypt → _buf reads
  ///
  /// During the handshake the bridge loop strips TDS PRELOGIN headers.
  /// After the handshake it forwards raw TLS bytes without modification.
  Future<void> _upgradeTls() async {
    // Capture the raw TCP socket and its reader before we replace them.
    // The bridge loop must keep using these even after _socket/_buf are swapped.
    final rawSocket = _socket;
    final rawReader = _buf.rawReader;

    // Loopback pair: SecureSocket talks to secSide; bridge controls bridgeSide.
    final loopServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final secSideFuture = Socket.connect(InternetAddress.loopbackIPv4, loopServer.port);
    final bridgeSide = await loopServer.first;
    await loopServer.close();
    final secSide = await secSideFuture;

    bool handshakeDone = false;

    // Direction A: SecureSocket writes → secSide → loopback → bridgeSide → rawSocket.
    //   Handshake phase: wrap TLS bytes in a TDS PRELOGIN packet.
    //   Post-handshake: forward raw encrypted TLS records.
    bridgeSide.listen((data) {
      if (handshakeDone) {
        rawSocket.add(data);
        rawSocket.flush();
      } else {
        final size = headerSize + data.length;
        final pkt = Uint8List(size);
        pkt[0] = packPrelogin;
        pkt[1] = statusEOM;
        pkt[2] = (size >> 8) & 0xFF;
        pkt[3] = size & 0xFF;
        pkt[6] = 1;
        pkt.setRange(headerSize, size, data);
        rawSocket.add(pkt);
        rawSocket.flush();
      }
    });

    // Direction B: rawSocket → rawReader (bridge loop) → bridgeSide → secSide.
    //   Runs for the entire lifetime of the connection; do not await.
    unawaited(_bridgeReadLoop(rawReader, bridgeSide, () => handshakeDone));

    // Perform the TLS handshake through the loopback.
    final tls = await SecureSocket.secure(
      secSide,
      host: _host,
      onBadCertificate: _trustServerCertificate ? (_) => true : null,
    );
    handshakeDone = true;

    // Swap _socket and _buf to the SecureSocket.
    // Writes: _buf → tls (encrypt) → secSide → loopback → bridgeSide → rawSocket → server
    // Reads:  server → rawSocket → bridge loop → bridgeSide → secSide → tls (decrypt) → _buf
    _socket = tls;
    _buf.replaceSocket(tls);
  }

  /// Continuously forwards bytes between the raw TCP socket and the loopback bridge.
  ///
  /// During the TLS handshake: strips TDS PRELOGIN headers, forwards bodies.
  /// After the handshake: forwards raw TLS records verbatim.
  /// Runs as a fire-and-forget background task for the connection lifetime.
  Future<void> _bridgeReadLoop(
    ChunkedStreamReader<int> rawReader,
    Socket bridgeSide,
    bool Function() isDone,
  ) async {
    try {
      // ── Phase 1: PRELOGIN handshake mode ────────────────────────────────────
      //
      // Read 8-byte PRELOGIN headers, strip them, forward the body.
      // We re-check isDone() AFTER each readChunk because the handshake can
      // complete while we are blocked in readChunk, leaving us mid-read on
      // raw TLS bytes rather than PRELOGIN-wrapped bytes.
      while (true) {
        final hdr = await rawReader.readChunk(headerSize);
        if (hdr.length < headerSize) return;

        if (isDone()) {
          // Race: the TLS handshake completed while we awaited readChunk(8).
          // The 8 bytes we just read are actually the start of a TLS record
          // (5-byte TLS header + 3 bytes of payload) — not a PRELOGIN header.
          // Reconstruct and forward the complete TLS record, then break to
          // enter the TLS passthrough phase.
          final payloadLen = (hdr[3] << 8) | hdr[4];
          final alreadyHave = hdr.sublist(5); // 3 bytes already read past TLS hdr
          final remaining = payloadLen - alreadyHave.length;
          final rest = remaining > 0 ? await rawReader.readChunk(remaining) : const <int>[];
          if (remaining > 0 && rest.length < remaining) return;
          final record = Uint8List(5 + payloadLen);
          record.setRange(0, 5, hdr.sublist(0, 5));
          record.setRange(5, 5 + alreadyHave.length, alreadyHave);
          if (remaining > 0) record.setRange(5 + alreadyHave.length, 5 + payloadLen, rest);
          bridgeSide.add(record);
          await bridgeSide.flush();
          break;
        }

        final bodyLen = ((hdr[2] << 8) | hdr[3]) - headerSize;
        if (bodyLen > 0) {
          final body = await rawReader.readChunk(bodyLen);
          if (body.isEmpty) return;
          bridgeSide.add(Uint8List.fromList(body));
          await bridgeSide.flush();
        }
      }

      // ── Phase 2: TLS passthrough mode ───────────────────────────────────────
      //
      // Forward complete TLS records verbatim (5-byte header + payload).
      while (true) {
        final tlsHdr = await rawReader.readChunk(5);
        if (tlsHdr.length < 5) break;
        final payloadLen = (tlsHdr[3] << 8) | tlsHdr[4];
        final payload = payloadLen > 0 ? await rawReader.readChunk(payloadLen) : const <int>[];
        if (payloadLen > 0 && payload.length < payloadLen) break;
        final record = Uint8List(5 + payloadLen);
        record.setRange(0, 5, tlsHdr);
        if (payloadLen > 0) record.setRange(5, 5 + payloadLen, payload);
        bridgeSide.add(record);
        await bridgeSide.flush();
      }
    } catch (_) {
      // Connection closed or bridge loop ended — expected at shutdown.
    }
  }

  Future<void> _sendLogin7() async {
    final auth = _sqlAuth;
    await Login7.send(
      _buf,
      LoginConfig(
        host: _host,
        username: auth?.username ?? '',
        password: auth?.password ?? '',
        serverName: _host,
        database: _database,
        fedAuthToken: _azureAdAuth?.bearerToken,
      ),
    );
  }

  Future<void> _send(String sql, Map<String, Object?> parameters) async {
    // Parameterless queries use a direct batch so temp tables and SET statements
    // are session-scoped (sp_executesql scopes them to the procedure call).
    if (parameters.isEmpty) {
      await RpcRequest.sendBatch(_buf, sql);
    } else {
      await RpcRequest.sendExecuteSql(_buf, sql, parameters);
    }
  }

  void _assertOpen() {
    if (!_connected) throw StateError('Connection is not open');
  }
}
