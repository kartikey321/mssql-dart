import 'dart:io';

import 'package:mssql/mssql.dart';

/// Same packet-splitting behaviour, but over cleartext TCP: isolates whether
/// SQL Server rejects small non-final TDS packets or only the TLS framing.
Future<void> main() async {
  final conn = await MssqlConnection.connect(
    host: '127.0.0.1',
    port: 14334,
    user: 'sa',
    password: 'Strong_test_password_123!',
    database: 'master',
    encrypt: false,
    queryTimeout: const Duration(seconds: 3),
  );
  for (var i = 1; i <= 120; i++) {
    try {
      await conn.query('SELECT 1 AS n');
      if (i % 20 == 0) stdout.writeln('ok $i');
    } catch (e) {
      stdout.writeln('FAIL at $i: $e');
      exit(0);
    }
  }
  stdout.writeln('survived 120');
  exit(0);
}
