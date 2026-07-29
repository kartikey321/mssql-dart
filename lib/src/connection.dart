import 'dart:async';
import 'dart:io';

import 'auth/azure_ad_auth.dart';
import 'auth/ntlm_auth.dart';
import 'auth/sql_auth.dart';
import 'connection_string.dart';
import 'exception.dart';
import 'info_message.dart';
import 'isolation.dart';
import 'native_tls/native_tls_bridge.dart';
import 'params.dart';
import 'protocol_limits.dart';
import 'result.dart';
import 'server_endpoint.dart';
import 'tcp_options.dart';
import 'tds/buf.dart';
import 'tds/bulk.dart';
import 'tds/constants.dart';
import 'tds/login7.dart';
import 'tds/prelogin.dart';
import 'tds/rpc.dart';
import 'tds/sql_browser.dart';
import 'tds/transport.dart';
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
  String _host;
  InternetAddress? _resolvedAddress;
  int _port;
  String? _instanceName;
  bool _resolveNamedInstancePort;
  final String _database;
  final String _appName;
  final int _packetSize;
  final SqlAuth? _sqlAuth;
  final AzureAdAuth? _azureAdAuth;
  final NtlmAuth? _ntlmAuth;
  final bool _encrypt;
  final bool _trustServerCertificate;
  final String? _trustedCertificateFile;
  final String? _trustedCertificateDirectory;
  final String? _hostNameInCertificate;

  /// Covers TCP + PRELOGIN + optional TLS + LOGIN7 (+ NTLM) — not TCP alone.
  final Duration _timeout;

  /// Default per-query deadline; null means no timeout. Overridable per call.
  final Duration? _queryTimeout;
  final MssqlProtocolLimits _protocolLimits;

  /// Always On ApplicationIntent=ReadOnly (LOGIN7 `fReadOnlyIntent`).
  final bool _readOnlyIntent;

  /// Database mirroring / partner host for initial-connect failover
  /// (go-mssqldb `FailoverPartner`). Tried only when primary connect fails.
  final String? _failoverPartner;
  final int? _failoverPort;

  /// Parallel dial all DNS A/AAAA records (AG multi-subnet listeners).
  final bool _multiSubnetFailover;

  /// TCP keepalive interval (go-mssqldb `keepAlive`). [Duration.zero] disables.
  final Duration _keepAlive;

  /// Optional batch run after login and after [resetSession] (go-mssqldb
  /// `Connector.SessionInitSQL`) — e.g. `SET XACT_ABORT ON; SET LOCK_TIMEOUT 5000`.
  final String? _sessionInitSql;

  late TdsBuffer _buf;
  late Socket _socket;
  bool _connected = false;
  bool _busy = false;
  String _currentDatabase = '';

  /// Database set at login (ENVCHANGE) — pool reset target when config.db empty.
  String _initialDatabase = '';

  /// Optional handler for TDS INFO tokens (PRINT / low-severity RAISERROR).
  ///
  /// Set before running queries (pool sets this from [MssqlPoolConfig.onInfoMessage]).
  void Function(MssqlInfoMessage info)? onInfoMessage;

  MssqlConnection._({
    required String host,
    required int port,
    String? instanceName,
    bool resolveNamedInstancePort = false,
    required String database,
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    SqlAuth? sqlAuth,
    AzureAdAuth? azureAdAuth,
    NtlmAuth? ntlmAuth,
    required bool encrypt,
    required bool trustServerCertificate,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
    String? hostNameInCertificate,
    required Duration timeout,
    Duration? queryTimeout,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    bool readOnlyIntent = false,
    String? failoverPartner,
    int? failoverPort,
    bool multiSubnetFailover = false,
    Duration keepAlive = const Duration(seconds: 30),
    String? sessionInitSql,
  })  : _host = host,
        _resolvedAddress = null,
        _port = port,
        _instanceName = instanceName,
        _resolveNamedInstancePort = resolveNamedInstancePort,
        _database = database,
        _appName = appName,
        _packetSize = packetSize,
        _sqlAuth = sqlAuth,
        _azureAdAuth = azureAdAuth,
        _ntlmAuth = ntlmAuth,
        _encrypt = encrypt,
        _trustServerCertificate = trustServerCertificate,
        _trustedCertificateFile = trustedCertificateFile,
        _trustedCertificateDirectory = trustedCertificateDirectory,
        _hostNameInCertificate = hostNameInCertificate,
        _timeout = timeout,
        _queryTimeout = queryTimeout,
        _protocolLimits = protocolLimits,
        _readOnlyIntent = readOnlyIntent,
        _failoverPartner = failoverPartner,
        _failoverPort = failoverPort,
        _multiSubnetFailover = multiSubnetFailover,
        _keepAlive = keepAlive,
        _sessionInitSql = sessionInitSql;

  // ── Factory constructors ───────────────────────────────────────────────────

  /// Connects using SQL Server authentication (username + password).
  ///
  /// [encrypt] — whether to negotiate TLS (default `true`). Set to `false`
  /// only for local LAN / Docker instances that don't support TLS.
  ///
  /// [trustServerCertificate] — accept self-signed or untrusted certificates.
  /// Required for typical local Docker SQL Server. Has no effect when
  /// [encrypt] is `false`.
  ///
  /// [trustedCertificateFile] / [trustedCertificateDirectory] — optional PEM
  /// trust roots for native OpenSSL certificate validation. Ignored when
  /// [trustServerCertificate] is `true`.
  ///
  /// [hostNameInCertificate] — hostname used for SNI / certificate validation
  /// (defaults to [host]). Use when dialing an IP or Always On listener while
  /// the cert CN/SAN is a different DNS name.
  ///
  /// [timeout] — login deadline for the full handshake (TCP + PRELOGIN +
  /// optional TLS + LOGIN7), not TCP connect alone.
  ///
  /// [queryTimeout] — default deadline for [query] / [queryMultiple] /
  /// [execute] / [queryStream]. On expiry the driver sends Attention and
  /// tries to keep the connection usable. Override per call with `timeout:`.
  ///
  /// [protocolLimits] — optional caps for server-controlled token and value
  /// lengths. Defaults to unlimited for compatibility.
  ///
  /// [appName] — reported to SQL Server as the client application name
  /// (`program_name` in `sys.dm_exec_sessions`).
  ///
  /// Named instances: pass `host: r'HOST\INSTANCE'` (or [instanceName]) and
  /// the driver queries SQL Browser (UDP 1434) unless [port] / `host,port` is
  /// explicit. PRELOGIN INSTOPT always carries the instance name when set.
  ///
  /// [connectRetries] — extra attempts after a transient connect/login failure
  /// (see [MssqlTransient]). Default `0` (single attempt).
  ///
  /// Always On / HA:
  /// - [readOnlyIntent] — `ApplicationIntent=ReadOnly` (LOGIN7 TypeFlags);
  ///   [database] is required. Server may ENVCHANGE-route to a secondary.
  /// - [failoverPartner] / [failoverPort] — tried only if primary connect fails
  ///   (database mirroring partner / go-mssqldb `FailoverPartner`).
  /// - [multiSubnetFailover] — parallel-dial all DNS A/AAAA records (AG
  ///   multi-subnet listeners).
  ///
  /// [keepAlive] — TCP keepalive interval (go-mssqldb default 30s). Pass
  /// [Duration.zero] to disable. Helps LAN firewalls that drop idle sockets.
  ///
  /// [sessionInitSql] — batch executed after login and after [resetSession]
  /// (go-mssqldb `SessionInitSQL`), e.g. `SET XACT_ABORT ON;`.
  static Future<MssqlConnection> connect({
    required String host,
    int port = defaultPort,
    String? instanceName,
    required String user,
    required String password,
    String database = '',
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    bool encrypt = true,
    bool trustServerCertificate = false,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
    String? hostNameInCertificate,
    Duration timeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    int connectRetries = 0,
    bool readOnlyIntent = false,
    String? failoverPartner,
    int? failoverPort,
    bool multiSubnetFailover = false,
    Duration keepAlive = const Duration(seconds: 30),
    String? sessionInitSql,
  }) {
    _validateHaOptions(
      database: database,
      readOnlyIntent: readOnlyIntent,
      failoverPartner: failoverPartner,
    );
    final ep =
        ServerEndpoint.parse(host, port: port, instanceName: instanceName);
    return MssqlTransient.retry(
      () => MssqlConnection._(
        host: ep.host,
        port: ep.port,
        instanceName: ep.instanceName,
        resolveNamedInstancePort: ep.shouldResolvePort,
        database: database,
        appName: appName,
        packetSize: packetSize,
        sqlAuth: SqlAuth(username: user, password: password),
        encrypt: encrypt,
        trustServerCertificate: trustServerCertificate,
        trustedCertificateFile: trustedCertificateFile,
        trustedCertificateDirectory: trustedCertificateDirectory,
        hostNameInCertificate: hostNameInCertificate,
        timeout: timeout,
        queryTimeout: queryTimeout,
        protocolLimits: protocolLimits,
        readOnlyIntent: readOnlyIntent,
        failoverPartner: failoverPartner,
        failoverPort: failoverPort,
        multiSubnetFailover: multiSubnetFailover,
        keepAlive: keepAlive,
        sessionInitSql: sessionInitSql,
      )._open(),
      retries: connectRetries,
    );
  }

  /// Connects using an ADO.NET / ODBC keyword string or `sqlserver://` URL.
  ///
  /// See [MssqlConnectionString.parse]. `User Id=DOMAIN\user` (or URL form)
  /// opens via [connectNtlm].
  static Future<MssqlConnection> connectFromString(
    String connectionString, {
    String? sessionInitSql,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
  }) {
    final c = MssqlConnectionString.parse(connectionString);
    if (c.useNtlm) {
      return connectNtlm(
        host: c.host,
        port: c.port,
        instanceName: c.instanceName,
        domain: c.ntlmDomain!,
        user: c.user,
        password: c.password,
        workstation: c.workstation,
        database: c.database,
        appName: c.appName,
        packetSize: c.packetSize,
        encrypt: c.encrypt,
        trustServerCertificate: c.trustServerCertificate,
        trustedCertificateFile:
            trustedCertificateFile ?? c.trustedCertificateFile,
        trustedCertificateDirectory:
            trustedCertificateDirectory ?? c.trustedCertificateDirectory,
        hostNameInCertificate: c.hostNameInCertificate,
        timeout: c.connectionTimeout,
        queryTimeout: c.queryTimeout,
        protocolLimits: protocolLimits,
        readOnlyIntent: c.readOnlyIntent,
        failoverPartner: c.failoverPartner,
        failoverPort: c.failoverPort,
        multiSubnetFailover: c.multiSubnetFailover,
        keepAlive: c.keepAlive,
        sessionInitSql: sessionInitSql,
      );
    }
    return connect(
      host: c.host,
      port: c.port,
      instanceName: c.instanceName,
      user: c.user,
      password: c.password,
      database: c.database,
      appName: c.appName,
      packetSize: c.packetSize,
      encrypt: c.encrypt,
      trustServerCertificate: c.trustServerCertificate,
      trustedCertificateFile:
          trustedCertificateFile ?? c.trustedCertificateFile,
      trustedCertificateDirectory:
          trustedCertificateDirectory ?? c.trustedCertificateDirectory,
      hostNameInCertificate: c.hostNameInCertificate,
      timeout: c.connectionTimeout,
      queryTimeout: c.queryTimeout,
      protocolLimits: protocolLimits,
      readOnlyIntent: c.readOnlyIntent,
      failoverPartner: c.failoverPartner,
      failoverPort: c.failoverPort,
      multiSubnetFailover: c.multiSubnetFailover,
      keepAlive: c.keepAlive,
      sessionInitSql: sessionInitSql,
    );
  }

  /// Connects using Azure AD authentication (bearer token).
  static Future<MssqlConnection> connectAzureAd({
    required String host,
    int port = defaultPort,
    String? instanceName,
    required AzureAdAuth azureAdAuth,
    String database = '',
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    bool trustServerCertificate = false,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
    String? hostNameInCertificate,
    Duration timeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    int connectRetries = 0,
    bool readOnlyIntent = false,
    String? failoverPartner,
    int? failoverPort,
    bool multiSubnetFailover = false,
    Duration keepAlive = const Duration(seconds: 30),
    String? sessionInitSql,
  }) {
    _validateHaOptions(
      database: database,
      readOnlyIntent: readOnlyIntent,
      failoverPartner: failoverPartner,
    );
    final ep =
        ServerEndpoint.parse(host, port: port, instanceName: instanceName);
    return MssqlTransient.retry(
      () => MssqlConnection._(
        host: ep.host,
        port: ep.port,
        instanceName: ep.instanceName,
        resolveNamedInstancePort: ep.shouldResolvePort,
        database: database,
        appName: appName,
        packetSize: packetSize,
        azureAdAuth: azureAdAuth,
        encrypt: true, // Azure AD always requires TLS
        trustServerCertificate: trustServerCertificate,
        trustedCertificateFile: trustedCertificateFile,
        trustedCertificateDirectory: trustedCertificateDirectory,
        hostNameInCertificate: hostNameInCertificate,
        timeout: timeout,
        queryTimeout: queryTimeout,
        protocolLimits: protocolLimits,
        readOnlyIntent: readOnlyIntent,
        failoverPartner: failoverPartner,
        failoverPort: failoverPort,
        multiSubnetFailover: multiSubnetFailover,
        keepAlive: keepAlive,
        sessionInitSql: sessionInitSql,
      )._open(),
      retries: connectRetries,
    );
  }

  /// Connects using Windows NTLM (SSPI) authentication.
  ///
  /// Sends LOGIN7 with a Type 1 negotiate blob, then completes the handshake
  /// when the server returns [tokenSSPI] (Type 2) by sending Type 3 as
  /// [packSSPIMessage]. Useful for domain-joined LAN SQL Servers.
  static Future<MssqlConnection> connectNtlm({
    required String host,
    int port = defaultPort,
    String? instanceName,
    required String domain,
    required String user,
    required String password,
    String? workstation,
    String database = '',
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    bool encrypt = true,
    bool trustServerCertificate = false,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
    String? hostNameInCertificate,
    Duration timeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    int connectRetries = 0,
    bool readOnlyIntent = false,
    String? failoverPartner,
    int? failoverPort,
    bool multiSubnetFailover = false,
    Duration keepAlive = const Duration(seconds: 30),
    String? sessionInitSql,
  }) {
    _validateHaOptions(
      database: database,
      readOnlyIntent: readOnlyIntent,
      failoverPartner: failoverPartner,
    );
    final ep =
        ServerEndpoint.parse(host, port: port, instanceName: instanceName);
    return MssqlTransient.retry(
      () => MssqlConnection._(
        host: ep.host,
        port: ep.port,
        instanceName: ep.instanceName,
        resolveNamedInstancePort: ep.shouldResolvePort,
        database: database,
        appName: appName,
        packetSize: packetSize,
        ntlmAuth: NtlmAuth(
          domain: domain,
          username: user,
          password: password,
          workstation: workstation,
        ),
        encrypt: encrypt,
        trustServerCertificate: trustServerCertificate,
        trustedCertificateFile: trustedCertificateFile,
        trustedCertificateDirectory: trustedCertificateDirectory,
        hostNameInCertificate: hostNameInCertificate,
        timeout: timeout,
        queryTimeout: queryTimeout,
        protocolLimits: protocolLimits,
        readOnlyIntent: readOnlyIntent,
        failoverPartner: failoverPartner,
        failoverPort: failoverPort,
        multiSubnetFailover: multiSubnetFailover,
        keepAlive: keepAlive,
        sessionInitSql: sessionInitSql,
      )._open(),
      retries: connectRetries,
    );
  }

  // ── Public query API ───────────────────────────────────────────────────────

  /// Executes [sql] with optional named [parameters] and returns all rows.
  ///
  /// Use `@paramName` placeholders:
  /// ```dart
  /// await conn.query('SELECT * FROM users WHERE id = @id', {'id': 42});
  /// ```
  ///
  /// [timeout] overrides the connection's default [queryTimeout] for this call
  /// (pass an empty map when you need a timeout without parameters).
  Future<MssqlResult> query(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    _assertOpen();
    _assertNotBusy();
    _busy = true;
    try {
      await _send(sql, parameters);
      final internal = await _awaitQuery(
        _tokenStream().processQueryResponse(),
        timeout: timeout,
      );
      return MssqlResult(internal: internal);
    } finally {
      _busy = false;
    }
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
    Duration? timeout,
  ]) async {
    _assertOpen();
    _assertNotBusy();
    _busy = true;
    try {
      await _send(sql, parameters);
      final sets = await _awaitQuery(
        _tokenStream().processAllQueryResponses(),
        timeout: timeout,
      );
      return MssqlMultiResult(sets);
    } finally {
      _busy = false;
    }
  }

  /// Streams rows one at a time without buffering the full result set.
  ///
  /// Rows are yielded as they arrive from the network. Useful for large result
  /// sets. Only the first result set is streamed; extras are drained silently.
  ///
  /// To stop early and keep the connection open, call [cancel] from another
  /// async context (sends TDS Attention). Breaking out of the `await for`
  /// without cancel closes the connection to avoid protocol desync.
  ///
  /// When [timeout] (or the connection [queryTimeout]) elapses, Attention is
  /// sent so the stream can finish and the connection stay reusable.
  ///
  /// ```dart
  /// await for (final row in conn.queryStream('SELECT * FROM bigTable')) {
  ///   process(row);
  /// }
  /// ```
  Stream<MssqlRow> queryStream(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async* {
    _assertOpen();
    _assertNotBusy();
    _busy = true;
    bool streamCompleted = false;
    final effective = timeout ?? _queryTimeout;
    Timer? deadline;
    try {
      await _send(sql, parameters);
      if (effective != null) {
        deadline = Timer(effective, () {
          unawaited(_buf.sendAttention());
        });
      }
      await for (final (cols, values) in _tokenStream().streamQueryResponse()) {
        yield MssqlRow(cols, values);
      }
      streamCompleted = true;
    } on MssqlProtocolLimitException {
      await _forceClose();
      rethrow;
    } finally {
      deadline?.cancel();
      if (!streamCompleted && _connected) {
        // Caller broke out early — TDS buffer has unread tokens.
        // Kill the connection to prevent protocol desync and pool poisoning.
        // Prefer [cancel] instead of breaking when reuse is required.
        _connected = false;
        unawaited(_socket.close().catchError((_) {}));
      }
      _busy = false;
    }
  }

  /// Executes [sql] and returns the number of rows affected.
  Future<int> execute(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    final result = await query(sql, parameters, timeout);
    return result.rowsAffected;
  }

  /// High-performance multi-row insert via TDS Bulk Load BCP.
  ///
  /// Sends `INSERT BULK` then a [packBulkLoadBCP] stream (COLMETADATA + ROW +
  /// DONE) — same path as go-mssqldb `CopyIn` / `Bulk`. Column SQL types are
  /// inferred from the first non-null value in each column (`int`→bigint,
  /// `String`→nvarchar(4000), `bool`→bit, `double`→float, `DateTime`→datetime2).
  ///
  /// [table] may be `dbo.MyTable`. [table] and [columns] are bracket-quoted.
  /// Returns rows inserted. Empty [rows] is a no-op (returns 0).
  ///
  ///
  /// ```dart
  /// await conn.bulkInsert(
  ///   'dbo.Items',
  ///   ['Id', 'Name', 'Active'],
  ///   [
  ///     [1, 'a', true],
  ///     [2, 'b', false],
  ///   ],
  /// );
  /// ```
  Future<int> bulkInsert(
    String table,
    List<String> columns,
    List<List<Object?>> rows, {
    List<BulkColumn>? columnTypes,
    Duration? timeout,
  }) async {
    _assertOpen();
    _assertNotBusy();
    if (columns.isEmpty) {
      throw ArgumentError('columns must not be empty');
    }
    if (rows.isEmpty) return 0;
    for (final row in rows) {
      if (row.length != columns.length) {
        throw ArgumentError(
          'Each row must have ${columns.length} values (got ${row.length})',
        );
      }
    }

    final cols = columnTypes ?? BulkLoad.inferColumns(columns, rows);
    if (cols.length != columns.length) {
      throw ArgumentError('columnTypes length must match columns');
    }

    _busy = true;
    try {
      final sql = BulkLoad.insertBulkSql(table, cols);
      await RpcRequest.sendBatch(_buf, sql);
      await _awaitQuery(
        _tokenStream().processQueryResponse(),
        timeout: timeout,
      );

      await BulkLoad.send(_buf, cols, rows);
      final result = await _awaitQuery(
        _tokenStream().processQueryResponse(),
        timeout: timeout,
      );
      return result.rowsAffected > 0 ? result.rowsAffected : rows.length;
    } finally {
      _busy = false;
    }
  }

  /// Invokes a stored procedure via TDS RPC (not `EXEC` batch).
  ///
  /// Mark OUTPUT / INPUT-OUTPUT parameters with [MssqlOutput]. The response
  /// includes [MssqlProcedureResult.returnStatus] (`RETURN` integer) and
  /// [MssqlProcedureResult.output] (RETURNVALUE tokens).
  ///
  /// ```dart
  /// final r = await conn.call('dbo.dart_sp_output', {
  ///   'in': 5,
  ///   'out': MssqlOutput(0),
  /// });
  /// print(r.output['out']); // 15
  /// ```
  Future<MssqlProcedureResult> call(
    String procedure, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    _assertOpen();
    _assertNotBusy();
    _busy = true;
    try {
      await RpcRequest.sendProcedure(_buf, procedure, parameters);
      final ts = _tokenStream();
      final sets = await _awaitQuery(
        ts.processAllQueryResponses(),
        timeout: timeout,
      );
      return MssqlProcedureResult(
        returnStatus: ts.lastReturnStatus,
        output:
            Map.unmodifiable(Map<String, Object?>.from(ts.lastReturnValues)),
        resultSets: [for (final s in sets) MssqlResult.fromInternal(s)],
      );
    } finally {
      _busy = false;
    }
  }

  /// Cancels the query currently in progress by sending a TDS Attention packet.
  ///
  /// No-op when the connection is idle. The in-flight [query] / [queryMultiple]
  /// / [queryStream] should finish after the server's Attention acknowledgement
  /// (DONE with `doneAttn`). Does not close the connection.
  Future<void> cancel() async {
    _assertOpen();
    if (!_busy) return;
    await _buf.sendAttention();
  }

  /// The database currently active on this connection.
  ///
  /// Updated from login ENVCHANGE and any later `USE` / ENVCHANGE type 1.
  String get database => _currentDatabase;

  /// Database established at login (before any mid-session `USE`).
  String get initialDatabase => _initialDatabase;

  /// Whether this connection is open.
  ///
  /// Becomes `false` after [close], login failure, or when the underlying
  /// socket reports done/error (server KILL, firewall drop, etc.).
  bool get isOpen => _connected;

  /// Application name sent at login (`program_name` in DMVs).
  String get appName => _appName;

  /// Switches the session database with `USE` if needed.
  ///
  /// [database] defaults to [initialDatabase]. No-op when already on target
  /// (case-insensitive). Returns `false` and closes the connection on failure.
  Future<bool> resetDatabase([String? database]) async {
    final target =
        (database == null || database.isEmpty) ? _initialDatabase : database;
    if (target.isEmpty) return true;
    if (!_connected) return false;
    if (_busy) {
      throw StateError('Cannot resetDatabase while a query is in progress');
    }
    if (_dbEquals(_currentDatabase, target)) return true;
    try {
      await query('USE ${_bracketIdent(target)}');
      return _connected && _dbEquals(_currentDatabase, target);
    } catch (_) {
      await close();
      return false;
    }
  }

  /// Marks the next Batch/RPC packet with TDS [statusResetConn] (0x08).
  ///
  /// The server clears session state (temp tables, `SET` options, context,
  /// database → login default) before running that request — same as
  /// go-mssqldb `ResetSession`. Prefer [resetSession] when the wipe must
  /// happen immediately (e.g. pool release).
  void requestSessionReset() {
    _assertOpen();
    _buf.resetConnectionPending = true;
  }

  /// Resets session state via TDS RESETCONNECTION, then a cheap `SELECT 1`.
  ///
  /// Clears temp tables and most session settings; restores the login
  /// database (ENVCHANGE). Returns `false` and closes on failure. Used by
  /// [MssqlPool] when [MssqlPoolConfig.resetOnRelease] is enabled.
  Future<bool> resetSession() async {
    if (!_connected) return false;
    if (_busy) {
      throw StateError('Cannot resetSession while a query is in progress');
    }
    try {
      requestSessionReset();
      final r = await query('SELECT 1 AS ok');
      if (r.isEmpty || r[0]['ok'] != 1) {
        await close();
        return false;
      }
      // Prefer ENVCHANGE; fall back to known login DB if server omitted it.
      if (_initialDatabase.isNotEmpty &&
          !_dbEquals(_currentDatabase, _initialDatabase)) {
        _currentDatabase = _initialDatabase;
      }
      // Re-apply session defaults wiped by RESETCONNECTION (go-mssqldb).
      await _runSessionInitSql();
      return true;
    } catch (_) {
      await close();
      return false;
    }
  }

  /// Runs a cheap `SELECT 1` to verify the session is still alive.
  ///
  /// Returns `false` and closes the connection on failure. Used by
  /// [MssqlPool] when [MssqlPoolConfig.validateOnAcquire] is enabled.
  Future<bool> validate({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!_connected) return false;
    if (_busy) return true; // in use — assume still valid
    try {
      final r = await query('SELECT 1 AS ok', const {}, timeout);
      return !r.isEmpty && r[0]['ok'] == 1;
    } catch (_) {
      await close();
      return false;
    }
  }

  /// Closes the connection.
  ///
  Future<void> close() async {
    _connected = false;
    try {
      await _socket.close();
    } catch (_) {}
  }

  // ── Transaction helpers ────────────────────────────────────────────────────

  /// Begins a transaction.
  ///
  /// When [isolation] is set, runs `SET TRANSACTION ISOLATION LEVEL …` first
  /// (session-scoped until changed again).
  Future<void> beginTransaction({MssqlIsolationLevel? isolation}) async {
    if (isolation != null) {
      await execute(
        'SET TRANSACTION ISOLATION LEVEL ${isolation.sqlName}',
      );
    }
    await execute('BEGIN TRANSACTION');
  }

  Future<void> commitTransaction() => execute('COMMIT TRANSACTION');
  Future<void> rollbackTransaction() => execute('ROLLBACK TRANSACTION');

  /// Creates a SQL Server savepoint (`SAVE TRANSACTION [name]`).
  ///
  /// [name] must be a simple identifier (`^[A-Za-z_][A-Za-z0-9_]*$`, ≤32 chars).
  /// Roll back to it with [rollbackTo] — the outer transaction stays open.
  Future<void> savepoint(String name) async {
    assertSavepointName(name);
    await execute('SAVE TRANSACTION [$name]');
  }

  /// Rolls back to a [savepoint] (`ROLLBACK TRANSACTION [name]`).
  ///
  /// Does not end the outer transaction — call [commitTransaction] or
  /// [rollbackTransaction] when finished.
  Future<void> rollbackTo(String name) async {
    assertSavepointName(name);
    await execute('ROLLBACK TRANSACTION [$name]');
  }

  /// Runs [fn] inside a transaction; commits on success, rolls back on error.
  ///
  /// Optional [isolation] is applied before `BEGIN TRANSACTION`.
  Future<T> transaction<T>(
    Future<T> Function(MssqlConnection conn) fn, {
    MssqlIsolationLevel? isolation,
  }) async {
    await beginTransaction(isolation: isolation);
    try {
      final result = await fn(this);
      await commitTransaction();
      return result;
    } catch (_) {
      try {
        await rollbackTransaction();
      } catch (_) {}
      rethrow;
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<MssqlConnection> _open() async {
    try {
      return await _openWithFailover();
    } on SocketException catch (e) {
      unawaited(_forceClose());
      throw MssqlException('TCP connect failed: $e');
    }
  }

  /// Primary connect (with Always On routing); on failure try [failoverPartner].
  Future<MssqlConnection> _openWithFailover() async {
    try {
      return await _openWithRouting();
    } catch (e) {
      final partner = _failoverPartner;
      if (partner == null || partner.isEmpty) rethrow;
      await _forceClose();
      final ep = ServerEndpoint.parse(
        partner,
        port: _failoverPort ?? defaultPort,
      );
      _host = ep.host;
      _resolvedAddress = null;
      _port = ep.port;
      _instanceName = ep.instanceName;
      _resolveNamedInstancePort = ep.shouldResolvePort;
      return await _openWithRouting();
    }
  }

  /// Completes handshake; if LOGIN ENVCHANGE routing is present, reconnect once.
  Future<MssqlConnection> _openWithRouting() async {
    var redirected = false;
    while (true) {
      final loginResult = await _openHandshakeTimed();
      final routing = loginResult.routing;
      if (routing == null) {
        await _runSessionInitSql();
        return this;
      }
      if (redirected) {
        await _forceClose();
        throw MssqlException(
          'Server requested a second Always On routing redirect '
          '(${routing.server}:${routing.port}); only one is allowed',
        );
      }
      redirected = true;
      await _forceClose();
      final parts = routing.server.split(r'\');
      _host = parts[0];
      _resolvedAddress = null;
      _instanceName = parts.length > 1 ? parts[1] : null;
      _port = routing.port;
      _resolveNamedInstancePort = false; // port is explicit from ENVCHANGE
    }
  }

  Future<LoginResult> _openHandshakeTimed() async {
    try {
      return await _openHandshake().timeout(
        _timeout,
        onTimeout: () {
          unawaited(_forceClose());
          throw MssqlException(
            'Login timed out after ${_timeout.inMilliseconds}ms '
            '(host=$_host port=$_port)',
          );
        },
      );
    } on MssqlProtocolLimitException {
      unawaited(_forceClose());
      rethrow;
    } on SocketException catch (e) {
      unawaited(_forceClose());
      throw MssqlException('TCP connect failed: $e');
    }
  }

  Future<LoginResult> _openHandshake() async {
    // 0. Named instance → SQL Browser (UDP 1434) when no explicit port
    if (_resolveNamedInstancePort && _instanceName != null) {
      final resolved = await SqlBrowser.resolve(_host, _instanceName!);
      _resolvedAddress = resolved.address;
      _port = resolved.port;
    }

    // 1. TCP
    _socket = await _dialTcp(_resolvedAddress ?? _host, _port);
    _watchSocket(_socket);
    _buf = TdsBuffer(
      _socket,
      packetSize: _packetSize,
      limits: _protocolLimits,
    );

    // 2. PRELOGIN
    // encryptNotSupported (0x02) = client will not do TLS (cleartext / LAN).
    // encryptOn (0x01) = request TLS for the whole session.
    // Do not advertise encryptOff and then upgrade. If the server requires
    // encryption, fail with a clear error instead.
    final wantEncrypt =
        (_encrypt || _azureAdAuth != null) ? encryptOn : encryptNotSupported;

    await Prelogin.send(
      _buf,
      requestEncrypt: wantEncrypt,
      fedAuthRequired: _azureAdAuth != null,
      instanceName: _instanceName,
    );
    final prelogin = await Prelogin.read(_buf);

    // 3. TLS upgrade only when the client requested encryption.
    if (prelogin.requiresTls) {
      if (!_encrypt && _azureAdAuth == null) {
        throw MssqlException(
          'Server requires encryption, but encrypt: false was set. '
          'Pass encrypt: true (and trustServerCertificate: true for '
          'self-signed certificates).',
        );
      }
      await _upgradeTls();
    } else if (_encrypt && _azureAdAuth == null) {
      throw MssqlException(
        'Server does not support encryption. '
        'Pass encrypt: false for local LAN / Docker instances without TLS.',
      );
    }

    // 4. LOGIN7
    await _sendLogin7();

    // 5. Login response (may include SSPI challenge for NTLM)
    final loginResult = await _tokenStream().processLoginResponse(
      onSspi: _ntlmAuth == null
          ? null
          : (challengeBytes) async {
              final challenge = NtlmChallenge.parse(challengeBytes);
              return _ntlmAuth.authenticateMessage(challenge);
            },
    );
    _currentDatabase = loginResult.database;
    _initialDatabase =
        loginResult.database.isNotEmpty ? loginResult.database : _database;
    _buf.packetSize = loginResult.packetSize;
    // Encrypted TDS: keep packets within one TLS plaintext fragment (≤16 383).
    if ((_encrypt || _azureAdAuth != null) && _buf.packetSize > 16383) {
      _buf.packetSize = 16383;
    }
    // Routing: stay unconnected until caller reconnects to the alternate.
    if (loginResult.routing == null) {
      _connected = true;
    }
    return loginResult;
  }

  /// TCP dial — optionally races all DNS addresses ([multiSubnetFailover]).
  Future<Socket> _dialTcp(Object host, int port) async {
    if (!_multiSubnetFailover || host is InternetAddress) {
      final sock = await Socket.connect(host, port, timeout: _timeout);
      applyMssqlTcpOptions(sock, keepAlive: _keepAlive);
      return sock;
    }
    final addrs = await InternetAddress.lookup(host as String);
    if (addrs.isEmpty) {
      throw SocketException('Failed host lookup: "$host"');
    }
    final unique = <InternetAddress>[];
    final seen = <String>{};
    for (final a in addrs) {
      if (seen.add(a.address)) unique.add(a);
    }
    if (unique.length == 1) {
      final sock = await Socket.connect(unique.first, port, timeout: _timeout);
      applyMssqlTcpOptions(sock, keepAlive: _keepAlive);
      return sock;
    }

    final completer = Completer<Socket>();
    var failures = 0;
    Object? lastError;
    for (final addr in unique) {
      unawaited(
        Socket.connect(addr, port, timeout: _timeout).then((sock) {
          if (completer.isCompleted) {
            sock.destroy();
          } else {
            applyMssqlTcpOptions(sock, keepAlive: _keepAlive);
            completer.complete(sock);
          }
        }, onError: (Object e) {
          lastError = e;
          failures++;
          if (failures >= unique.length && !completer.isCompleted) {
            completer.completeError(lastError!);
          }
        }),
      );
    }
    return completer.future;
  }

  /// Runs [sessionInitSql] after login / reset (go-mssqldb SessionInitSQL).
  Future<void> _runSessionInitSql() async {
    final sql = _sessionInitSql;
    if (sql == null || sql.trim().isEmpty) return;
    await execute(sql);
  }

  static void _validateHaOptions({
    required String database,
    required bool readOnlyIntent,
    String? failoverPartner,
  }) {
    if (readOnlyIntent && database.isEmpty) {
      throw ArgumentError(
        'database must be specified when ApplicationIntent / readOnlyIntent '
        'is ReadOnly (Always On read-only routing)',
      );
    }
    if (failoverPartner != null && failoverPartner.isEmpty) {
      throw ArgumentError('failoverPartner must not be empty when set');
    }
  }

  TokenStream _tokenStream() => TokenStream(
        _buf,
        onDatabaseChanged: (db) {
          _currentDatabase = db;
        },
        onInfoMessage: onInfoMessage,
      );

  static bool _dbEquals(String a, String b) =>
      a.toLowerCase() == b.toLowerCase();

  /// Bracket-quotes a SQL identifier (`]` → `]]`).
  static String _bracketIdent(String name) => '[${name.replaceAll(']', ']]')}]';

  /// Marks the connection dead when the peer closes or errors.
  void _watchSocket(Socket sock) {
    sock.done.then((_) {
      _connected = false;
    }, onError: (_) {
      _connected = false;
    });
  }

  /// Performs the TDS-wrapped TLS handshake (ms-tds §2.1.1 PRELOGIN encryption).
  ///
  /// TLS handshake records are carried in PRELOGIN packets; afterwards the
  /// native transport owns the encrypted TCP byte stream.
  Future<void> _upgradeTls() async {
    final rawSocket = _socket;
    final nativeTransport = await NativeTlsBridge.upgrade(
      rawSocket: rawSocket,
      rawReader: _buf.rawReader,
      host: _hostNameInCertificate ?? _host,
      trustServerCertificate: _trustServerCertificate,
      trustedCertificateFile: _trustedCertificateFile,
      trustedCertificateDirectory: _trustedCertificateDirectory,
    );
    final ntlm = _ntlmAuth;
    if (ntlm != null) {
      final certificate = nativeTransport.peerCertificateDer();
      if (certificate.isNotEmpty) {
        ntlm.channelBindings =
            NtlmAuth.channelBindingTokenFromCertificate(certificate);
      }
    }
    nativeTransport.start();
    _buf.replaceTransport(NativeTlsTdsTransport(nativeTransport));
  }

  Future<void> _sendLogin7() async {
    // go-mssqldb: ServerName includes instance when set (host\INSTANCE).
    final serverName = _instanceName != null && _instanceName!.isNotEmpty
        ? '$_host\\$_instanceName'
        : _host;

    final ntlm = _ntlmAuth;
    // Negotiate TDS packets that fit in one native TLS plaintext fragment.
    // This is sent in LOGIN7, so SQL Server agrees to the larger size rather
    // than the client changing its packet boundary after login.
    final loginPacketSize =
        _encrypt || _azureAdAuth != null ? 16383 : _packetSize;
    if (ntlm != null) {
      await Login7.send(
        _buf,
        LoginConfig(
          host: _host,
          username: '',
          password: '',
          appName: _appName,
          serverName: serverName,
          database: _database,
          packetSize: loginPacketSize,
          sspi: ntlm.negotiateMessage(),
          readOnlyIntent: _readOnlyIntent,
        ),
      );
      return;
    }

    final auth = _sqlAuth;
    await Login7.send(
      _buf,
      LoginConfig(
        host: _host,
        username: auth?.username ?? '',
        password: auth?.password ?? '',
        appName: _appName,
        serverName: serverName,
        database: _database,
        packetSize: loginPacketSize,
        fedAuthToken: _azureAdAuth?.bearerToken,
        readOnlyIntent: _readOnlyIntent,
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

  /// Awaits a query response, applying [timeout] or the connection default.
  ///
  /// On timeout: send Attention, drain the in-flight response, then throw.
  Future<T> _awaitQuery<T>(
    Future<T> response, {
    Duration? timeout,
  }) async {
    final effective = timeout ?? _queryTimeout;
    try {
      if (effective == null) return await response;
      return await response.timeout(effective);
    } on MssqlProtocolLimitException {
      await _forceClose();
      rethrow;
    } on TimeoutException {
      final timedOutAfter = effective!;
      try {
        await _buf.sendAttention();
      } catch (_) {}
      try {
        await response.timeout(const Duration(seconds: 10));
      } on MssqlProtocolLimitException {
        await _forceClose();
        rethrow;
      } catch (_) {}
      throw MssqlException(
        'Query timed out after ${timedOutAfter.inMilliseconds}ms',
      );
    }
  }

  Future<void> _forceClose() async {
    _connected = false;
    try {
      await _socket.close();
    } catch (_) {}
  }

  void _assertOpen() {
    if (!_connected) throw StateError('Connection is not open');
  }

  void _assertNotBusy() {
    if (_busy) {
      throw StateError('A query is already in progress on this connection');
    }
  }
}
