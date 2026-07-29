import 'dart:async';

import 'package:mssql/mssql.dart';

import 'live_test_config.dart';

/// Waits for SQL Server readiness through the driver under test.
Future<void> waitForSqlServer({
  Duration timeout = const Duration(seconds: 90),
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final connection = await liveTestConfig.open();
      try {
        await connection.query('SELECT 1 AS value');
      } finally {
        await connection.close();
      }
      return;
    } catch (error) {
      lastError = error;
      await Future<void>.delayed(retryDelay);
    }
  }
  throw StateError('SQL Server did not become ready: $lastError');
}

Future<T> withConnection<T>(
  Future<T> Function(MssqlConnection connection) body, {
  String database = 'master',
}) async {
  final connection = await liveTestConfig.open(database: database);
  try {
    return await body(connection);
  } finally {
    await connection.close();
  }
}
