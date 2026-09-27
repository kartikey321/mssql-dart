import 'dart:async';

import 'connection.dart';
import 'exception.dart';
import 'result.dart';

/// Configuration for [MssqlPool].
class MssqlPoolConfig {
  final String host;
  final int port;
  final String user;
  final String password;
  final String database;
  final bool encrypt;
  final MssqlEncryptMode? encryptMode;
  final bool trustServerCertificate;
  final Duration connectionTimeout;

  /// Minimum number of idle connections to keep open (default 0).
  final int min;

  /// Maximum number of total connections (default 10).
  final int max;

  /// Close idle connections that have been unused for this duration (default 30s).
  final Duration idleTimeout;

  /// How often to check for idle connections past [idleTimeout] (default 10s).
  ///
  /// Exposed mainly so tests can use a short [idleTimeout] without waiting
  /// out the default cadence too; real callers rarely need to change it.
  final Duration idleCheckInterval;

  /// Throw [MssqlException] if a connection cannot be acquired within this duration (default 15s).
  final Duration acquireTimeout;

  const MssqlPoolConfig({
    required this.host,
    this.port = 1433,
    required this.user,
    required this.password,
    this.database = '',
    this.encrypt = true,
    this.encryptMode,
    this.trustServerCertificate = false,
    this.connectionTimeout = const Duration(seconds: 30),
    this.min = 0,
    this.max = 10,
    this.idleTimeout = const Duration(seconds: 30),
    this.idleCheckInterval = const Duration(seconds: 10),
    this.acquireTimeout = const Duration(seconds: 15),
  });
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
///
/// ```dart
/// final pool = MssqlPool(MssqlPoolConfig(
///   host: 'localhost', user: 'sa', password: 'P@ssw0rd',
/// ));
/// await pool.open();
///
/// final result = await pool.query('SELECT * FROM users WHERE id = @id', {'id': 1});
///
/// await pool.close();
/// ```
class MssqlPool {
  final MssqlPoolConfig config;

  final _idle = <_IdleEntry>[];
  final _pending = <Completer<MssqlConnection>>[];
  int _total = 0;
  bool _closed = false;
  Timer? _idleTimer;

  MssqlPool(this.config);

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
  Future<MssqlConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');

    // Return an idle connection if available.
    while (_idle.isNotEmpty) {
      final entry = _idle.removeLast();
      if (entry.connection.isOpen) return entry.connection;
      _total--; // connection died silently — don't reuse
    }

    // Create a new connection if under the cap.
    if (_total < config.max) {
      _total++;
      MssqlConnection conn;
      try {
        conn = await _openConnection();
      } catch (_) {
        _total--;
        rethrow;
      }
      if (_closed) {
        // Pool was closed while we were connecting — discard the new
        // connection. This check is deliberately outside the try/catch
        // above: putting it inside, sharing that catch's `_total--`, would
        // decrement twice for this one connection (once here, once when
        // the throw below is caught by the same catch).
        _total--;
        unawaited(conn.close());
        throw MssqlException('Pool closed');
      }
      return conn;
    }

    // Pool is at max — queue.
    final completer = Completer<MssqlConnection>();
    _pending.add(completer);
    return completer.future.timeout(
      config.acquireTimeout,
      onTimeout: () {
        _pending.remove(completer);
        throw MssqlException(
          'Pool acquire timeout: no connection available within '
          '${config.acquireTimeout.inSeconds}s (pool size: ${config.max})',
        );
      },
    );
  }

  /// Releases a connection back to the pool.
  ///
  /// If there are pending callers, the connection is handed directly to the
  /// next waiter. Otherwise it goes to the idle list, or is closed if the pool
  /// is at [config.min] and the connection is surplus.
  void release(MssqlConnection conn) {
    if (_closed || !conn.isOpen) {
      _discard(conn);
      return;
    }

    // Hand off to the next waiter first.
    while (_pending.isNotEmpty) {
      final completer = _pending.removeAt(0);
      if (!completer.isCompleted) {
        completer.complete(conn);
        return;
      }
    }

    // No waiters — keep idle if above min, else discard surplus.
    _idle.add(_IdleEntry(conn));
  }

  // ── Convenience query methods ──────────────────────────────────────────────

  /// Runs [sql] on an acquired connection, releases it when done.
  ///
  /// See [MssqlConnection.query] for [timeout]'s meaning.
  Future<MssqlResult> query(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    final conn = await acquire();
    try {
      return await conn.query(sql, parameters, timeout);
    } finally {
      release(conn);
    }
  }

  /// Runs [sql] and returns all result sets.
  ///
  /// See [MssqlConnection.query] for [timeout]'s meaning.
  Future<MssqlMultiResult> queryMultiple(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    final conn = await acquire();
    try {
      return await conn.queryMultiple(sql, parameters, timeout);
    } finally {
      release(conn);
    }
  }

  /// Streams rows from [sql]. The connection is held for the duration of the stream.
  ///
  /// See [MssqlConnection.queryStream] for [timeout]'s meaning.
  Stream<MssqlRow> queryStream(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async* {
    final conn = await acquire();
    try {
      yield* conn.queryStream(sql, parameters, timeout);
    } finally {
      release(conn);
    }
  }

  /// Executes [sql] and returns rows affected.
  ///
  /// See [MssqlConnection.query] for [timeout]'s meaning.
  Future<int> execute(
    String sql, [
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  ]) async {
    final conn = await acquire();
    try {
      return await conn.execute(sql, parameters, timeout);
    } finally {
      release(conn);
    }
  }

  /// Runs [fn] inside a transaction on an acquired connection.
  ///
  /// Commits on success, rolls back on error, then releases the connection.
  Future<T> transaction<T>(
    Future<T> Function(MssqlConnection conn) fn,
  ) async {
    final conn = await acquire();
    try {
      return await conn.transaction(fn);
    } finally {
      release(conn);
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
    final closing = _idle.map((e) => e.connection.close()).toList();
    _idle.clear();
    await Future.wait(closing, eagerError: false);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<MssqlConnection> _openConnection() => MssqlConnection.connect(
        host: config.host,
        port: config.port,
        user: config.user,
        password: config.password,
        database: config.database,
        encrypt: config.encrypt,
        encryptMode: config.encryptMode,
        trustServerCertificate: config.trustServerCertificate,
        timeout: config.connectionTimeout,
      );

  Future<void> _createAndIdle() async {
    _total++;
    try {
      final conn = await _openConnection();
      _idle.add(_IdleEntry(conn));
    } catch (_) {
      _total--;
      rethrow;
    }
  }

  void _discard(MssqlConnection conn) {
    _total--;
    if (conn.isOpen) conn.close();
  }

  void _startIdleTimer() {
    _idleTimer =
        Timer.periodic(config.idleCheckInterval, (_) => _reapIdle());
  }

  void _reapIdle() {
    final cutoff = DateTime.now().subtract(config.idleTimeout);
    final toKeep = <_IdleEntry>[];
    // Tracks how many have actually been discarded so far. The previous
    // version compared against `_idle.length - toKeep.length`, but
    // `toKeep.length` only grows on the *keep* branch — a discard never
    // adds to it — so every entry saw the same "still above min" check
    // computed against the ORIGINAL total, and a burst of idle connections
    // all past idleTimeout at once could all get discarded, dropping below
    // config.min instead of stopping there.
    var discarded = 0;
    for (final entry in _idle) {
      final canDiscard = (_idle.length - discarded) > config.min;
      if (canDiscard && entry.idleSince.isBefore(cutoff)) {
        _discard(entry.connection);
        discarded++;
      } else {
        toKeep.add(entry);
      }
    }
    _idle
      ..clear()
      ..addAll(toKeep);
  }
}
