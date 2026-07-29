import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['MSSQL_LIVE_TESTS'] == '1';
  final skipReason = enabled ? false : 'Set MSSQL_LIVE_TESTS=1';

  group('TLS alignment live regressions', () {
    test(
      '@@ROWCOUNT is preserved within one user batch',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        await conn.execute('''
CREATE TABLE #tls_rowcount_test (
  id int NOT NULL PRIMARY KEY,
  value int NOT NULL
);
INSERT INTO #tls_rowcount_test(id, value) VALUES (1, 0);
''');

        for (var i = 0; i < 1200; i++) {
          final pad = _repeat('x', i % 251);
          final result = await conn.query('''
UPDATE #tls_rowcount_test
SET value = value + 1
WHERE id = 1;
SELECT @@ROWCOUNT AS affected;
-- $pad
''');
          expect(
            result.first['affected'],
            1,
            reason: '@@ROWCOUNT changed within the user batch at iteration $i.',
          );
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'multi-packet SQLBatch completes over TLS',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        final payload = _repeat('z', 6000);
        final result =
            await conn.query("SELECT LEN(N'$payload') AS payload_length");
        expect(result.first['payload_length'], payload.length);
        final health = await conn.query('SELECT 1 AS ok');
        expect(health.first['ok'], 1);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'timeout Attention never loses the active response or poisons connection',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        for (var i = 0; i < 80; i++) {
          final pad = _repeat('a', i % 113);
          await conn.query('SELECT 1 AS n; -- $pad');

          await expectLater(
            conn.query(
              "WAITFOR DELAY '00:00:02'; SELECT 42 AS late_value",
              const {},
              const Duration(milliseconds: 80),
            ),
            throwsA(isA<MssqlException>()),
          );

          final health = await conn.query('SELECT 1 AS ok');
          expect(
            health.first['ok'],
            1,
            reason: 'Connection was desynchronized after Attention at '
                'iteration $i.',
          );
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'Bulk Load completes over TLS',
      () async {
        final conn = await _connect();
        addTearDown(conn.close);

        await conn.execute('''
CREATE TABLE #tls_bulk_test (
  id bigint NULL,
  label nvarchar(4000) NULL
);
''');

        final inserted = await conn.bulkInsert(
          '#tls_bulk_test',
          const ['id', 'label'],
          const [
            [1, 'row'],
          ],
        );
        expect(inserted, 1);
        final health = await conn.query('SELECT 1 AS ok');
        expect(health.first['ok'], 1);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

Future<MssqlConnection> _connect() {
  final env = Platform.environment;
  return MssqlConnection.connect(
    host: env['MSSQL_HOST'] ?? '127.0.0.1',
    port: int.parse(env['MSSQL_PORT'] ?? '14334'),
    user: env['MSSQL_USER'] ?? 'sa',
    password: env['MSSQL_PASSWORD'] ?? 'Strong_test_password_123!',
    database: env['MSSQL_DATABASE'] ?? 'master',
    encrypt: true,
    trustServerCertificate: true,
    timeout: const Duration(seconds: 15),
  );
}

String _repeat(String value, int count) => List.filled(count, value).join();
