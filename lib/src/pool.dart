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
  final bool trustServerCertificate;
  final Duration connectionTimeout;

  /// Minimum number of idle connections to keep open (default 0).
  final int min;

  /// Maximum number of total connections (default 10).
  final int max;

  /// Close idle connections that have been unused for this duration (default 30s).
  final Duration idleTimeout;

  /// Throw [MssqlException] if a connection cannot be acquired within this duration (default 15s).
  final Duration acquireTimeout;

  const MssqlPoolConfig({
    required this.host,
    this.port = 1433,
    required this.user,
    required this.password,
    this.database = '',
    this.encrypt = true,
    this.trustServerCertificate = false,
    this.connectionTimeout = const Duration(seconds: 30),
    this.min = 0,
    this.max = 10,
    this.idleTimeout = const Duration(seconds: 30),
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
      try {
        return await _openConnection();
      } catch (e) {
        _total--;
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
  Future<MssqlResult> query(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.query(sql, parameters);
    } finally {
      release(conn);
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
      release(conn);
    }
  }

  /// Streams rows from [sql]. The connection is held for the duration of the stream.
  Stream<MssqlRow> queryStream(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async* {
    final conn = await acquire();
    try {
      yield* conn.queryStream(sql, parameters);
    } finally {
      release(conn);
    }
  }

  /// Executes [sql] and returns rows affected.
  Future<int> execute(
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final conn = await acquire();
    try {
      return await conn.execute(sql, parameters);
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
    _idleTimer = Timer.periodic(const Duration(seconds: 10), (_) => _reapIdle());
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
