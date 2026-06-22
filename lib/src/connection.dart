import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    required bool trustServerCertificate,
    required Duration timeout,
  })  : _host = host,
        _port = port,
        _database = database,
        _sqlAuth = sqlAuth,
        _azureAdAuth = azureAdAuth,
        _trustServerCertificate = trustServerCertificate,
        _timeout = timeout;

  // ── Factory constructors ───────────────────────────────────────────────────

  /// Connects using SQL Server authentication (username + password).
  ///
  /// Set [trustServerCertificate] to `true` for local dev / self-signed certs.
  static Future<MssqlConnection> connect({
    required String host,
    int port = defaultPort,
    required String user,
    required String password,
    String database = '',
    bool trustServerCertificate = false,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return MssqlConnection._(
      host: host,
      port: port,
      database: database,
      sqlAuth: SqlAuth(username: user, password: password),
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
    Duration timeout = const Duration(seconds: 30),
  }) {
    return MssqlConnection._(
      host: host,
      port: port,
      database: database,
      azureAdAuth: azureAdAuth,
      trustServerCertificate: false,
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
    //
    // When trustServerCertificate=true (local dev) we ask for no encryption.
    // A Docker/dev SQL Server with default settings accepts this and skips TLS,
    // letting us test the rest of the protocol without implementing TDS-wrapped TLS.
    //
    // When trustServerCertificate=false (production) or Azure AD is in use we
    // request encryption and then perform the TDS-wrapped TLS handshake.
    // encryptNotSupported (0x02) = "client cannot do TLS" → server skips it for dev containers.
    // encryptOn (0x01) = request TLS → required for production / Azure SQL.
    final wantEncrypt = (_trustServerCertificate && _azureAdAuth == null)
        ? encryptNotSupported
        : encryptOn;

    await Prelogin.send(_buf, requestEncrypt: wantEncrypt, fedAuthRequired: _azureAdAuth != null);
    final prelogin = await Prelogin.read(_buf);

    // 3. TLS upgrade (only if both sides agreed to encrypt)
    if (prelogin.requiresTls) {
      await _upgradeTls();
    } else if (!_trustServerCertificate) {
      // We requested encryption but server refused — reject unless explicitly trusted.
      throw MssqlException(
        'Server does not support encryption. '
        'Pass trustServerCertificate: true for local dev / self-signed certs.',
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

  /// Performs a TDS-wrapped TLS handshake.
  ///
  /// SQL Server (non-strict mode) requires TLS ClientHello / ServerHello to be
  /// wrapped inside TDS PRELOGIN packets during the handshake. After the
  /// handshake the connection switches to raw TLS for all subsequent packets.
  ///
  /// We implement this with a localhost loopback bridge:
  ///   [SecureSocket] ↔ [loopback] ↔ [Bridge] ↔ [raw TCP to SQL Server]
  /// The bridge wraps/unwraps TDS PRELOGIN packets during the handshake, then
  /// switches to raw forwarding once the TLS session is established.
  Future<void> _upgradeTls() async {
    // Set up the loopback pair.
    final loopServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final loopClientFuture = Socket.connect(InternetAddress.loopbackIPv4, loopServer.port);
    final bridgeSide = await loopServer.first; // bridge controls this side
    await loopServer.close();
    final secSide = await loopClientFuture; // SecureSocket uses this side

    // State: true after TLS Finished is confirmed (we switch to raw forwarding).
    bool handshakeDone = false;

    // Bridge: secSide → [wrap in TDS PRELOGIN] → real SQL Server socket
    bridgeSide.listen((data) {
      if (handshakeDone) {
        _socket.add(data);
      } else {
        // Wrap each Write from SecureSocket in a TDS PRELOGIN packet.
        final size = headerSize + data.length;
        final pkt = Uint8List(size);
        pkt[0] = packPrelogin;
        pkt[1] = statusEOM;
        pkt[2] = (size >> 8) & 0xFF;
        pkt[3] = size & 0xFF;
        pkt[6] = 1;
        pkt.setRange(headerSize, size, data);
        _socket.add(pkt);
        _socket.flush();
      }
    });

    // Bridge: real SQL Server socket → [unwrap TDS] → secSide
    // We reuse _buf's ChunkedStreamReader which already has a subscription.
    // Read TDS packets via _buf directly.
    _startTlsBridgeRead(bridgeSide, () => handshakeDone);

    // Perform the TLS handshake through the loopback.
    final tls = await SecureSocket.secure(
      secSide,
      host: _host,
      onBadCertificate: _trustServerCertificate ? (_) => true : null,
    );
    handshakeDone = true;

    // Replace our underlying socket + buffer reader with the TLS connection.
    // All subsequent reads/writes go: TdsBuffer ↔ SecureSocket ↔ loopback ↔ bridge ↔ raw TCP.
    _socket = tls;
    _buf.replaceSocket(tls);
  }

  void _startTlsBridgeRead(Socket bridgeSide, bool Function() isDone) {
    // Run a background loop reading TDS PRELOGIN packets from the real SQL
    // Server during the handshake and forwarding the unwrapped bodies to the
    // bridge side (which feeds SecureSocket).
    _bridgeReadLoop(bridgeSide, isDone);
  }

  Future<void> _bridgeReadLoop(Socket bridgeSide, bool Function() isDone) async {
    try {
      while (!isDone()) {
        // Read one TDS packet header (8 bytes).
        final hdr = await _buf.readBytesRaw(headerSize);
        if (hdr == null) break;
        final size = (hdr[2] << 8) | hdr[3];
        final bodyLen = size - headerSize;
        if (bodyLen > 0) {
          final body = await _buf.readBytesRaw(bodyLen);
          if (body == null) break;
          bridgeSide.add(body);
          await bridgeSide.flush();
        }
        final status = hdr[1];
        if (status & statusEOM != 0 && isDone()) break;
      }
    } catch (_) {
      // Handshake done or connection closed — expected.
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
