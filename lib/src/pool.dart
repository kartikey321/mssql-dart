import 'dart:async';

import 'auth/azure_ad_auth.dart';
import 'connection.dart';
import 'connection_string.dart';
import 'exception.dart';
import 'info_message.dart';
import 'isolation.dart';
import 'params.dart';
import 'protocol_limits.dart';
import 'result.dart';
import 'tds/constants.dart';

/// Configuration for [MssqlPool].
class MssqlPoolConfig {
  final String host;
  final int port;

  /// Optional named instance (`SQLEXPRESS`, etc.). Also parsed from
  /// `host\INSTANCE` / `host\INSTANCE,port` in [host].
  final String? instanceName;
  final String user;
  final String password;
  final String database;
  final String appName;
  final int packetSize;
  final bool encrypt;
  final bool trustServerCertificate;

  /// Optional PEM trust roots for native TLS certificate validation.
  final String? trustedCertificateFile;
  final String? trustedCertificateDirectory;

  /// Hostname for SNI / certificate validation (defaults to [host]).
  final String? hostNameInCertificate;

  final Duration connectionTimeout;

  /// Default query deadline applied to pooled connections (null = none).
  final Duration? queryTimeout;

  /// Optional caps for server-controlled token and value lengths.
  final MssqlProtocolLimits protocolLimits;

  /// When non-null, [MssqlPool] opens connections via
  /// [MssqlConnection.connectAzureAd] (FedAuth). Takes precedence over
  /// [ntlmDomain] and SQL auth.
  final AzureAdAuth? azureAdAuth;

  /// When non-null (and [azureAdAuth] is null), [MssqlPool] opens connections
  /// via [MssqlConnection.connectNtlm] (Windows SSPI / NTLMv2).
  final String? ntlmDomain;

  /// Optional workstation name for NTLM (used only when [ntlmDomain] is set).
  final String? ntlmWorkstation;

  /// Minimum number of idle connections to keep open (default 0).
  final int min;

  /// Maximum number of total connections (default 10).
  final int max;

  /// Close idle connections that have been unused for this duration (default 30s).
  final Duration idleTimeout;

  /// Throw [MssqlException] if a connection cannot be acquired within this duration (default 15s).
  final Duration acquireTimeout;

  /// When true (default), idle connections are probed with `SELECT 1` before
  /// reuse so half-open LAN sockets (server KILL, reboot, firewall) are
  /// discarded instead of handed to callers.
  final bool validateOnAcquire;

  /// When true (default), [MssqlPool.release] runs [MssqlConnection.resetSession]
  /// (TDS RESETCONNECTION) so temp tables / `SET` options / `USE` from the
  /// previous borrower do not leak to the next acquire.
  final bool resetOnRelease;

  /// Extra connect attempts on transient failure (default `2`). See
  /// [MssqlTransient].
  final int connectRetries;

  /// Always On ApplicationIntent=ReadOnly.
  final bool readOnlyIntent;

  /// Database mirroring partner for initial-connect failover.
  final String? failoverPartner;
  final int? failoverPort;

  /// Parallel-dial all DNS A/AAAA records (AG multi-subnet listeners).
  final bool multiSubnetFailover;

  /// TCP keepalive (go-mssqldb default 30s). [Duration.zero] disables.
  final Duration keepAlive;

  /// Batch run after each new connection login and after [resetSession]
  /// (go-mssqldb `SessionInitSQL`).
  final String? sessionInitSql;

  /// Optional INFO token handler applied to every pooled connection.
  final void Function(MssqlInfoMessage info)? onInfoMessage;

  /// Optional pool lifecycle observer (acquire/release/create/…); see
  /// [MssqlPoolEvent]. Also assignable on [MssqlPool.onEvent] after construct.
  final void Function(MssqlPoolEvent event)? onPoolEvent;

  const MssqlPoolConfig({
    required this.host,
    this.port = 1433,
    this.instanceName,
    required this.user,
    required this.password,
    this.database = '',
    this.appName = 'mssql-dart',
    this.packetSize = defaultPacketSize,
    this.encrypt = true,
    this.trustServerCertificate = false,
    this.trustedCertificateFile,
    this.trustedCertificateDirectory,
    this.hostNameInCertificate,
    this.connectionTimeout = const Duration(seconds: 15),
    this.queryTimeout,
    this.protocolLimits = const MssqlProtocolLimits(),
    this.azureAdAuth,
    this.ntlmDomain,
    this.ntlmWorkstation,
    this.min = 0,
    this.max = 10,
    this.idleTimeout = const Duration(seconds: 30),
    this.acquireTimeout = const Duration(seconds: 15),
    this.validateOnAcquire = true,
    this.resetOnRelease = true,
    this.connectRetries = 2,
    this.readOnlyIntent = false,
    this.failoverPartner,
    this.failoverPort,
    this.multiSubnetFailover = false,
    this.keepAlive = const Duration(seconds: 30),
    this.sessionInitSql,
    this.onInfoMessage,
    this.onPoolEvent,
  });

  /// Builds pool config from an ADO.NET / `sqlserver://` connection string.
  ///
  /// Pool sizing knobs ([min], [max], …) are not part of the string — pass
  /// them here. NTLM is used when the string has `DOMAIN\user`.
  factory MssqlPoolConfig.fromConnectionString(
    String connectionString, {
    int min = 0,
    int max = 10,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration acquireTimeout = const Duration(seconds: 15),
    bool validateOnAcquire = true,
    bool resetOnRelease = true,
    int connectRetries = 2,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    String? sessionInitSql,
    void Function(MssqlInfoMessage info)? onInfoMessage,
    void Function(MssqlPoolEvent event)? onPoolEvent,
  }) {
    final c = MssqlConnectionString.parse(connectionString);
    if (c.useNtlm) {
      return MssqlPoolConfig.ntlm(
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
        trustedCertificateFile: c.trustedCertificateFile,
        trustedCertificateDirectory: c.trustedCertificateDirectory,
        hostNameInCertificate: c.hostNameInCertificate,
        connectionTimeout: c.connectionTimeout,
        queryTimeout: c.queryTimeout,
        protocolLimits: protocolLimits,
        min: min,
        max: max,
        idleTimeout: idleTimeout,
        acquireTimeout: acquireTimeout,
        validateOnAcquire: validateOnAcquire,
        resetOnRelease: resetOnRelease,
        connectRetries: connectRetries,
        readOnlyIntent: c.readOnlyIntent,
        failoverPartner: c.failoverPartner,
        failoverPort: c.failoverPort,
        multiSubnetFailover: c.multiSubnetFailover,
        keepAlive: c.keepAlive,
        sessionInitSql: sessionInitSql,
        onInfoMessage: onInfoMessage,
        onPoolEvent: onPoolEvent,
      );
    }
    return MssqlPoolConfig(
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
      trustedCertificateFile: c.trustedCertificateFile,
      trustedCertificateDirectory: c.trustedCertificateDirectory,
      hostNameInCertificate: c.hostNameInCertificate,
      connectionTimeout: c.connectionTimeout,
      queryTimeout: c.queryTimeout,
      protocolLimits: protocolLimits,
      min: min,
      max: max,
      idleTimeout: idleTimeout,
      acquireTimeout: acquireTimeout,
      validateOnAcquire: validateOnAcquire,
      resetOnRelease: resetOnRelease,
      connectRetries: connectRetries,
      readOnlyIntent: c.readOnlyIntent,
      failoverPartner: c.failoverPartner,
      failoverPort: c.failoverPort,
      multiSubnetFailover: c.multiSubnetFailover,
      keepAlive: c.keepAlive,
      sessionInitSql: sessionInitSql,
      onInfoMessage: onInfoMessage,
      onPoolEvent: onPoolEvent,
    );
  }

  /// Pool config that opens connections with Azure AD (FedAuth).
  ///
  /// [encrypt] is always true (Azure AD requires TLS). [user]/[password] are
  /// unused placeholders for the shared config shape.
  factory MssqlPoolConfig.azureAd({
    required String host,
    int port = 1433,
    String? instanceName,
    required AzureAdAuth azureAdAuth,
    String database = '',
    String appName = 'mssql-dart',
    int packetSize = defaultPacketSize,
    bool trustServerCertificate = false,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
    String? hostNameInCertificate,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    int min = 0,
    int max = 10,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration acquireTimeout = const Duration(seconds: 15),
    bool validateOnAcquire = true,
    bool resetOnRelease = true,
    int connectRetries = 2,
    bool readOnlyIntent = false,
    String? failoverPartner,
    int? failoverPort,
    bool multiSubnetFailover = false,
    Duration keepAlive = const Duration(seconds: 30),
    String? sessionInitSql,
    void Function(MssqlInfoMessage info)? onInfoMessage,
    void Function(MssqlPoolEvent event)? onPoolEvent,
  }) {
    return MssqlPoolConfig(
      host: host,
      port: port,
      instanceName: instanceName,
      user: '',
      password: '',
      database: database,
      appName: appName,
      packetSize: packetSize,
      encrypt: true,
      trustServerCertificate: trustServerCertificate,
      trustedCertificateFile: trustedCertificateFile,
      trustedCertificateDirectory: trustedCertificateDirectory,
      hostNameInCertificate: hostNameInCertificate,
      connectionTimeout: connectionTimeout,
      queryTimeout: queryTimeout,
      protocolLimits: protocolLimits,
      azureAdAuth: azureAdAuth,
      min: min,
      max: max,
      idleTimeout: idleTimeout,
      acquireTimeout: acquireTimeout,
      validateOnAcquire: validateOnAcquire,
      resetOnRelease: resetOnRelease,
      connectRetries: connectRetries,
      readOnlyIntent: readOnlyIntent,
      failoverPartner: failoverPartner,
      failoverPort: failoverPort,
      multiSubnetFailover: multiSubnetFailover,
      keepAlive: keepAlive,
      sessionInitSql: sessionInitSql,
      onInfoMessage: onInfoMessage,
      onPoolEvent: onPoolEvent,
    );
  }

  /// Pool config that opens connections with Windows NTLM (SSPI).
  factory MssqlPoolConfig.ntlm({
    required String host,
    int port = 1433,
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
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration? queryTimeout,
    MssqlProtocolLimits protocolLimits = const MssqlProtocolLimits(),
    int min = 0,
    int max = 10,
    Duration idleTimeout = const Duration(seconds: 30),
    Duration acquireTimeout = const Duration(seconds: 15),
    bool validateOnAcquire = true,
    bool resetOnRelease = true,
    int connectRetries = 2,
    bool readOnlyIntent = false,
    String? failoverPartner,
    int? failoverPort,
    bool multiSubnetFailover = false,
    Duration keepAlive = const Duration(seconds: 30),
    String? sessionInitSql,
    void Function(MssqlInfoMessage info)? onInfoMessage,
    void Function(MssqlPoolEvent event)? onPoolEvent,
  }) {
    return MssqlPoolConfig(
      host: host,
      port: port,
      instanceName: instanceName,
      user: user,
      password: password,
      database: database,
      appName: appName,
      packetSize: packetSize,
      encrypt: encrypt,
      trustServerCertificate: trustServerCertificate,
      trustedCertificateFile: trustedCertificateFile,
      trustedCertificateDirectory: trustedCertificateDirectory,
      hostNameInCertificate: hostNameInCertificate,
      connectionTimeout: connectionTimeout,
      queryTimeout: queryTimeout,
      protocolLimits: protocolLimits,
      ntlmDomain: domain,
      ntlmWorkstation: workstation,
      min: min,
      max: max,
      idleTimeout: idleTimeout,
      acquireTimeout: acquireTimeout,
      validateOnAcquire: validateOnAcquire,
      resetOnRelease: resetOnRelease,
      connectRetries: connectRetries,
      readOnlyIntent: readOnlyIntent,
      failoverPartner: failoverPartner,
      failoverPort: failoverPort,
      multiSubnetFailover: multiSubnetFailover,
      keepAlive: keepAlive,
      sessionInitSql: sessionInitSql,
      onInfoMessage: onInfoMessage,
      onPoolEvent: onPoolEvent,
    );
  }
}

/// Snapshot of [MssqlPool] sizing + lifetime counters (node-mssql / tarn style).
///
/// [total] = [idle] + [inUse]. [pending] is waiters blocked on [MssqlPool.acquire]
/// when the pool is at [max].
class MssqlPoolStats {
  /// Open connections (idle + borrowed).
  final int total;

  /// Connections sitting in the idle list.
  final int idle;

  /// Connections currently checked out (`total - idle`).
  final int inUse;

  /// Callers waiting for a free connection.
  final int pending;

  /// Configured [MssqlPoolConfig.max].
  final int max;

  /// Successful new TCP/login opens.
  final int created;

  /// Connections removed (reap, validate fail, reset fail, discard, close).
  final int destroyed;

  /// Successful [MssqlPool.acquire] completions (including waiter handoff).
  final int acquired;

  /// Successful [MssqlPool.release] completions (idle return or waiter handoff).
  final int released;

  /// [MssqlPool.acquire] futures that hit [MssqlPoolConfig.acquireTimeout].
  final int acquireTimeouts;

  /// Idle probes that failed under [MssqlPoolConfig.validateOnAcquire].
  final int validationFailures;

  /// [MssqlConnection.resetSession] / [MssqlConnection.resetDatabase] failures
  /// during [MssqlPool.release].
  final int resetFailures;

  const MssqlPoolStats({
    required this.total,
    required this.idle,
    required this.inUse,
    required this.pending,
    required this.max,
    required this.created,
    required this.destroyed,
    required this.acquired,
    required this.released,
    required this.acquireTimeouts,
    required this.validationFailures,
    required this.resetFailures,
  });

  @override
  String toString() =>
      'MssqlPoolStats(total=$total idle=$idle inUse=$inUse pending=$pending '
      'max=$max created=$created destroyed=$destroyed acquired=$acquired '
      'released=$released timeouts=$acquireTimeouts '
      'validateFails=$validationFailures resetFails=$resetFailures)';
}

/// Pool lifecycle event kinds for [MssqlPoolEvent] / [MssqlPool.onEvent].
enum MssqlPoolEventKind {
  created,
  destroyed,
  acquired,
  released,
  acquireTimeout,
  validationFailed,
  resetFailed,
}

/// One pool lifecycle notification (create/acquire/release/…).
class MssqlPoolEvent {
  final MssqlPoolEventKind kind;
  final DateTime at;
  final MssqlPoolStats stats;

  const MssqlPoolEvent({
    required this.kind,
    required this.at,
    required this.stats,
  });

  @override
  String toString() => 'MssqlPoolEvent($kind at=$at stats=$stats)';
}

class _IdleEntry {
  final MssqlConnection connection;
  final DateTime idleSince;
  _IdleEntry(this.connection) : idleSince = DateTime.now();
}

/// A pool of [MssqlConnection]s.
///
/// Mirrors the node-mssql / tarn pattern:
/// - [min] idle connections are kept alive.
/// - [max] caps total open connections.
/// - Callers that exceed [max] are queued until a connection is released.
/// - Idle connections older than [idleTimeout] are closed.
/// - [stats] / [onEvent] expose sizing + lifetime counters for LAN ops.
///
/// ```dart
/// final pool = MssqlPool(MssqlPoolConfig(
///   host: 'localhost', user: 'sa', password: 'P@ssw0rd',
/// ));
/// await pool.open();
/// print(pool.stats); // total/idle/inUse/pending + counters
///
/// final result = await pool.query('SELECT * FROM users WHERE id = @id', {'id': 1});
///
/// await pool.close();
/// ```
///
/// Auth variants:
/// - SQL: default [MssqlPoolConfig] constructor
/// - Azure AD: [MssqlPoolConfig.azureAd]
/// - Windows NTLM: [MssqlPoolConfig.ntlm] (domain-joined SQL that accepts SSPI)
class MssqlPool {
  final MssqlPoolConfig config;

  final _idle = <_IdleEntry>[];
  final _pending = <Completer<MssqlConnection>>[];
  int _total = 0;
  bool _closed = false;
  Timer? _idleTimer;

  int _created = 0;
  int _destroyed = 0;
  int _acquired = 0;
  int _released = 0;
  int _acquireTimeouts = 0;
  int _validationFailures = 0;
  int _resetFailures = 0;

  /// Optional lifecycle observer; seeded from [MssqlPoolConfig.onPoolEvent].
  void Function(MssqlPoolEvent event)? onEvent;

  MssqlPool(this.config) : onEvent = config.onPoolEvent;

  /// Current sizing + lifetime counters (safe to call anytime).
  MssqlPoolStats get stats => MssqlPoolStats(
        total: _total,
        idle: _idle.length,
        inUse: _total - _idle.length,
        pending: _pending.length,
        max: config.max,
        created: _created,
        destroyed: _destroyed,
        acquired: _acquired,
        released: _released,
        acquireTimeouts: _acquireTimeouts,
        validationFailures: _validationFailures,
        resetFailures: _resetFailures,
      );

  /// Alias for [MssqlPoolStats.total] (node-mssql `pool.size`).
  int get size => _total;

  /// Alias for [MssqlPoolStats.idle] (node-mssql `pool.available`).
  int get available => _idle.length;

  /// Alias for [MssqlPoolStats.inUse] (node-mssql `pool.borrowed`).
  int get borrowed => _total - _idle.length;

  /// Alias for [MssqlPoolStats.pending] (node-mssql `pool.pending`).
  int get pending => _pending.length;

  /// Opens the pool and pre-creates [config.min] connections.
  Future<void> open() async {
    _startIdleTimer();
    if (config.min > 0) {
      await Future.wait([
        for (int i = 0; i < config.min; i++) _createAndIdle(),
      ]);
    }
  }

  /// Acquires a connection from the pool.
  ///
  /// Returns immediately if an idle connection is available or total < max.
  /// Otherwise queues the caller until a connection is released.
  /// Throws [MssqlException] if [config.acquireTimeout] is exceeded.
  ///
  /// When [MssqlPoolConfig.validateOnAcquire] is true, idle connections are
  /// probed before reuse; dead ones are discarded and replaced.
  Future<MssqlConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');

    // Return an idle connection if available (and still healthy).
    while (_idle.isNotEmpty) {
      final entry = _idle.removeLast();
      if (!entry.connection.isOpen) {
        _accountDestroyed();
        continue;
      }
      if (config.validateOnAcquire) {
        final ok = await entry.connection.validate();
        if (!ok) {
          _validationFailures++;
          _emit(MssqlPoolEventKind.validationFailed);
          _accountDestroyed();
          continue;
        }
      }
      _noteAcquired();
      return entry.connection;
    }

    // Create a new connection if under the cap.
    if (_total < config.max) {
      _total++;
      var reserved = true;
      try {
        final conn = await _openConnection();
        if (_closed) {
          // Pool was closed while we were connecting — discard the new connection.
          unawaited(conn.close());
          _accountDestroyed();
          reserved = false;
          throw MssqlException('Pool closed');
        }
        _created++;
        _emit(MssqlPoolEventKind.created);
        _noteAcquired();
        return conn;
      } catch (_) {
        // Failed open: undo the reservation (not a destroy — never opened).
        if (reserved) _total--;
        rethrow;
      }
    }

    // Pool is at max — queue.
    final completer = Completer<MssqlConnection>();
    _pending.add(completer);
    return completer.future.timeout(
      config.acquireTimeout,
      onTimeout: () {
        _pending.remove(completer);
        _acquireTimeouts++;
        _emit(MssqlPoolEventKind.acquireTimeout);
        throw MssqlException(
          'Pool acquire timeout: no connection available within '
          '${config.acquireTimeout.inSeconds}s (pool size: ${config.max})',
        );
      },
    );
  }

  /// Releases a connection back to the pool.
  ///
  /// When [MssqlPoolConfig.resetOnRelease] is true, runs
  /// [MssqlConnection.resetSession] (TDS RESETCONNECTION + `SELECT 1`) before
  /// reuse. Failed resets discard the connection.
  ///
  /// If there are pending callers, the connection is handed directly to the
  /// next waiter. Otherwise it goes to the idle list.
  Future<void> release(MssqlConnection conn) async {
    if (_closed || !conn.isOpen) {
      _discard(conn);
      return;
    }

    if (config.resetOnRelease) {
      final ok = await conn.resetSession();
      if (!ok || !conn.isOpen) {
        _resetFailures++;
        _emit(MssqlPoolEventKind.resetFailed);
        _discard(conn);
        return;
      }
      // If pool config pins a database and reset left us elsewhere, USE.
      if (config.database.isNotEmpty &&
          conn.database.toLowerCase() != config.database.toLowerCase()) {
        final dbOk = await conn.resetDatabase(config.database);
        if (!dbOk || !conn.isOpen) {
          _resetFailures++;
          _emit(MssqlPoolEventKind.resetFailed);
          _discard(conn);
          return;
        }
      }
    }

    _released++;
    _emit(MssqlPoolEventKind.released);

    // Hand off to the next waiter first.
    while (_pending.isNotEmpty) {
      final completer = _pending.removeAt(0);
      if (!completer.isCompleted) {
        completer.complete(conn);
        _noteAcquired();
        return;
      }
    }

    // No waiters — keep idle.
    _idle.add(_IdleEntry(conn));
  }

  // ── Convenience query methods ──────────────────────────────────────────────

  /// Runs [sql] on an acquired connection, releases it when done.
  Future<MssqlResult> query(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.query(sql, parameters);
    } finally {
      await release(conn);
    }
  }

  /// Runs [sql] and returns all result sets.
  Future<MssqlMultiResult> queryMultiple(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.queryMultiple(sql, parameters);
    } finally {
      await release(conn);
    }
  }

  /// Runs [sql] and returns rows affected.
  Future<int> execute(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.execute(sql, parameters);
    } finally {
      await release(conn);
    }
  }

  /// Invokes a stored procedure via TDS RPC (see [MssqlConnection.call]).
  Future<MssqlProcedureResult> call(
    String procedure, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    final conn = await acquire();
    try {
      return await conn.call(procedure, parameters, timeout);
    } finally {
      await release(conn);
    }
  }

  /// Streams rows from [sql] on an acquired connection.
  Stream<MssqlRow> queryStream(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async* {
    final conn = await acquire();
    try {
      await for (final row in conn.queryStream(sql, parameters)) {
        yield row;
      }
    } finally {
      await release(conn);
    }
  }

  /// Runs [fn] inside a transaction on an acquired connection.
  ///
  /// Commits on success, rolls back on error, then releases the connection.
  Future<T> transaction<T>(
    Future<T> Function(MssqlConnection conn) fn, {
    MssqlIsolationLevel? isolation,
  }) async {
    final conn = await acquire();
    try {
      return await conn.transaction(fn, isolation: isolation);
    } finally {
      await release(conn);
    }
  }

  /// Closes all idle connections and waits for active connections to be released.
  Future<void> close() async {
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;

    // Reject any pending waiters.
    for (final c in _pending) {
      if (!c.isCompleted) {
        c.completeError(MssqlException('Pool closed'));
      }
    }
    _pending.clear();

    // Close all idle connections.
    final closing = <Future<void>>[];
    for (final e in _idle) {
      _accountDestroyed();
      closing.add(e.connection.close());
    }
    _idle.clear();
    await Future.wait(closing, eagerError: false);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  void _noteAcquired() {
    _acquired++;
    _emit(MssqlPoolEventKind.acquired);
  }

  void _accountDestroyed() {
    _total--;
    if (_total < 0) _total = 0;
    _destroyed++;
    _emit(MssqlPoolEventKind.destroyed);
  }

  void _emit(MssqlPoolEventKind kind) {
    final handler = onEvent;
    if (handler == null) return;
    handler(MssqlPoolEvent(kind: kind, at: DateTime.now(), stats: stats));
  }

  Future<MssqlConnection> _openConnection() async {
    final aad = config.azureAdAuth;
    late final MssqlConnection conn;
    if (aad != null) {
      conn = await MssqlConnection.connectAzureAd(
        host: config.host,
        port: config.port,
        instanceName: config.instanceName,
        azureAdAuth: aad,
        database: config.database,
        appName: config.appName,
        packetSize: config.packetSize,
        trustServerCertificate: config.trustServerCertificate,
        trustedCertificateFile: config.trustedCertificateFile,
        trustedCertificateDirectory: config.trustedCertificateDirectory,
        hostNameInCertificate: config.hostNameInCertificate,
        timeout: config.connectionTimeout,
        queryTimeout: config.queryTimeout,
        protocolLimits: config.protocolLimits,
        connectRetries: config.connectRetries,
        readOnlyIntent: config.readOnlyIntent,
        failoverPartner: config.failoverPartner,
        failoverPort: config.failoverPort,
        multiSubnetFailover: config.multiSubnetFailover,
        keepAlive: config.keepAlive,
        sessionInitSql: config.sessionInitSql,
      );
    } else {
      final domain = config.ntlmDomain;
      if (domain != null) {
        conn = await MssqlConnection.connectNtlm(
          host: config.host,
          port: config.port,
          instanceName: config.instanceName,
          domain: domain,
          user: config.user,
          password: config.password,
          workstation: config.ntlmWorkstation,
          database: config.database,
          appName: config.appName,
          packetSize: config.packetSize,
          encrypt: config.encrypt,
          trustServerCertificate: config.trustServerCertificate,
          trustedCertificateFile: config.trustedCertificateFile,
          trustedCertificateDirectory: config.trustedCertificateDirectory,
          hostNameInCertificate: config.hostNameInCertificate,
          timeout: config.connectionTimeout,
          queryTimeout: config.queryTimeout,
          protocolLimits: config.protocolLimits,
          connectRetries: config.connectRetries,
          readOnlyIntent: config.readOnlyIntent,
          failoverPartner: config.failoverPartner,
          failoverPort: config.failoverPort,
          multiSubnetFailover: config.multiSubnetFailover,
          keepAlive: config.keepAlive,
          sessionInitSql: config.sessionInitSql,
        );
      } else {
        conn = await MssqlConnection.connect(
          host: config.host,
          port: config.port,
          instanceName: config.instanceName,
          user: config.user,
          password: config.password,
          database: config.database,
          appName: config.appName,
          packetSize: config.packetSize,
          encrypt: config.encrypt,
          trustServerCertificate: config.trustServerCertificate,
          trustedCertificateFile: config.trustedCertificateFile,
          trustedCertificateDirectory: config.trustedCertificateDirectory,
          hostNameInCertificate: config.hostNameInCertificate,
          timeout: config.connectionTimeout,
          queryTimeout: config.queryTimeout,
          protocolLimits: config.protocolLimits,
          connectRetries: config.connectRetries,
          readOnlyIntent: config.readOnlyIntent,
          failoverPartner: config.failoverPartner,
          failoverPort: config.failoverPort,
          multiSubnetFailover: config.multiSubnetFailover,
          keepAlive: config.keepAlive,
          sessionInitSql: config.sessionInitSql,
        );
      }
    }
    conn.onInfoMessage = config.onInfoMessage;
    return conn;
  }

  Future<void> _createAndIdle() async {
    _total++;
    try {
      final conn = await _openConnection();
      _created++;
      _emit(MssqlPoolEventKind.created);
      _idle.add(_IdleEntry(conn));
    } catch (_) {
      _total--;
      rethrow;
    }
  }

  void _discard(MssqlConnection conn) {
    _accountDestroyed();
    if (conn.isOpen) unawaited(conn.close());
  }

  void _startIdleTimer() {
    _idleTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _reapIdle());
  }

  void _reapIdle() {
    final cutoff = DateTime.now().subtract(config.idleTimeout);
    final toKeep = <_IdleEntry>[];
    for (final entry in _idle) {
      final overMin = (_idle.length - toKeep.length) > config.min;
      if (overMin && entry.idleSince.isBefore(cutoff)) {
        _discard(entry.connection);
      } else {
        toKeep.add(entry);
      }
    }
    _idle
      ..clear()
      ..addAll(toKeep);
  }
}
