import 'dart:io';

import 'package:mssql/mssql.dart';

/// Environment-backed settings for normal live suites (`mssql-dart-live` :14334).
///
/// Force-TLS stress uses its own host/port constants (14335) and does not
/// depend on [LiveTestConfig.encrypt].
class LiveTestConfig {
  final String host;
  final int port;
  final String user;
  final String password;
  final bool encrypt;
  final bool trustServerCertificate;

  const LiveTestConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.encrypt,
    required this.trustServerCertificate,
  });

  factory LiveTestConfig.fromEnvironment() {
    final environment = Platform.environment;
    final port = int.tryParse(environment['MSSQL_PORT'] ?? '14334');
    if (port == null || port < 1 || port > 65535) {
      throw StateError('MSSQL_PORT must be an integer from 1 through 65535.');
    }
    final password = environment['MSSQL_PASSWORD'] ?? '';
    if (password.isEmpty) {
      throw StateError('MSSQL_PASSWORD must be set when MSSQL_LIVE_TESTS=1.');
    }
    return LiveTestConfig(
      host: environment['MSSQL_HOST'] ?? '127.0.0.1',
      port: port,
      user: environment['MSSQL_USER'] ?? 'sa',
      password: password,
      // Default cleartext / optional-TLS for normal live suites.
      encrypt: environment['MSSQL_ENCRYPT'] == '1',
      trustServerCertificate:
          environment['MSSQL_TRUST_SERVER_CERTIFICATE'] != '0',
    );
  }

  Future<MssqlConnection> open({
    String database = 'master',
    String appName = 'mssql-dart-live-tests',
    Duration timeout = const Duration(seconds: 10),
    bool? encrypt,
  }) {
    return MssqlConnection.connect(
      host: host,
      port: port,
      user: user,
      password: password,
      database: database,
      appName: appName,
      encrypt: encrypt ?? this.encrypt,
      trustServerCertificate: trustServerCertificate,
      timeout: timeout,
    );
  }
}

LiveTestConfig? _liveTestConfig;

LiveTestConfig get liveTestConfig =>
    _liveTestConfig ??= LiveTestConfig.fromEnvironment();
