import 'dart:async';
import 'dart:io';

import 'exception.dart';

/// INFO (`0xAB`) or ERROR (`0xAA`) token payload (ms-tds §2.2.7.10 / §2.2.7.9).
///
/// Same wire layout for both; INFO is non-fatal (PRINT / low-severity RAISERROR).
class MssqlInfoMessage {
  /// SQL Server message number (`msg.error` / `sys.messages`).
  final int number;

  /// Message state (1–127).
  final int state;

  /// Severity class (`0`–`25`). INFO is typically `< 11`; ERROR is `≥ 11`.
  final int severity;

  final String message;
  final String serverName;
  final String procName;
  final int lineNo;

  const MssqlInfoMessage({
    required this.number,
    required this.state,
    required this.severity,
    required this.message,
    this.serverName = '',
    this.procName = '',
    this.lineNo = 0,
  });

  /// True when [severity] is in the SQL Server error range (`≥ 11`).
  bool get isError => severity >= 11;

  @override
  String toString() =>
      'MssqlInfoMessage($number, sev=$severity): $message';
}

/// Classifies transient SQL / network failures for LAN retry.
///
/// Codes mix classic on-prem disconnects (`233`, `10054`, …), deadlocks
/// (`1205`), and Azure transient codes that also appear on managed instances.
class MssqlTransient {
  MssqlTransient._();

  /// SQL error numbers commonly treated as retryable.
  static const Set<int> sqlErrorCodes = {
    // Deadlock / lock timeout
    1205,
    1222,
    // Connection broken / network
    233,
    64,
    10053,
    10054,
    10060,
    10061,
    4060, // cannot open database (often mid-failover)
    // Azure / MI transient (harmless on pure on-prem if unused)
    40197,
    40501,
    40613,
    49918,
    49919,
    49920,
    10928,
    10929,
  };

  /// Returns true when [error] is worth a bounded reconnect / retry.
  static bool isTransient(Object error) {
    if (error is MssqlException) {
      if (sqlErrorCodes.contains(error.errorCode)) return true;
      // Wrapped network / login deadline from [MssqlConnection._open].
      if (error.message.startsWith('TCP connect failed')) return true;
      if (error.message.startsWith('Login timed out')) return true;
      return false;
    }
    if (error is TimeoutException) return true;
    if (error is SocketException) return true;
    if (error is HandshakeException) return true;
    if (error is TlsException) return true;
    if (error is OSError) return true;
    return false;
  }

  /// Runs [fn], retrying up to [retries] extra times on [isTransient] failures.
  ///
  /// Delay between attempts is [delay] × attempt number (1-based).
  static Future<T> retry<T>(
    Future<T> Function() fn, {
    int retries = 2,
    Duration delay = const Duration(milliseconds: 200),
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await fn();
      } catch (e) {
        if (!isTransient(e) || attempt >= retries) rethrow;
        attempt++;
        await Future<void>.delayed(delay * attempt);
      }
    }
  }
}
