import 'dart:math';

import 'package:mssql/mssql.dart';

import 'live_test_config.dart';

/// Disposable database and schema for one live test suite.
class LiveTestDatabase {
  final String name;

  const LiveTestDatabase._(this.name);

  static Future<LiveTestDatabase> create() async {
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final database = LiveTestDatabase._('mssql_dart_test_$suffix');
    final admin = await liveTestConfig.open();
    try {
      await admin.execute('CREATE DATABASE ${_quoteIdentifier(database.name)}');
    } finally {
      await admin.close();
    }

    final connection = await database.open();
    try {
      await connection.execute('CREATE SCHEMA live_test');
    } finally {
      await connection.close();
    }
    return database;
  }

  Future<MssqlConnection> open() => liveTestConfig.open(database: name);

  Future<void> dispose() async {
    final admin = await liveTestConfig.open();
    try {
      final quoted = _quoteIdentifier(name);
      await admin.execute(
        'ALTER DATABASE $quoted SET SINGLE_USER WITH ROLLBACK IMMEDIATE; '
        'DROP DATABASE $quoted;',
      );
    } finally {
      await admin.close();
    }
  }

  static String _quoteIdentifier(String value) =>
      '[${value.replaceAll(']', ']]')}]';
}
