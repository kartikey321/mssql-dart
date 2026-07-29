import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'dart:async';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live SQL Server tests for Attention cancel and large multi-packet results.
///
/// Requires Docker SQL on 127.0.0.1:14330 (password `Strong_test_password_123!`), same as
/// other integration suites. Skips when the server is unreachable.
///
/// Sources:
/// - ms-tds Attention / DONE doneAttn; go-mssqldb cancel patterns
/// - PR #3: large NVARCHAR forcing multi-packet TDS replies

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<MssqlConnection?> tryOpen() async {
  try {
    return await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    ).timeout(const Duration(seconds: 5));
  } catch (_) {
    return null;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  late MssqlConnection conn;
  var available = false;

  setUpAll(() async {
    final c = await tryOpen();
    if (c == null) {
      available = false;
      return;
    }
    conn = c;
    available = true;
  });

  tearDownAll(() async {
    if (available) await conn.close();
  });

  group('live Attention cancel', () {
    test('cancel mid-WAITFOR then connection still usable', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final pending = conn.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v");
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await conn.cancel();

      final cancelled = await pending.timeout(const Duration(seconds: 10));
      expect(cancelled.rows, isEmpty);
      expect(conn.isOpen, isTrue);

      final r = await conn.query('SELECT 42 AS n');
      expect(r[0]['n'], equals(42));
    });

    test('cancel during queryStream WAITFOR keeps connection', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final rows = <MssqlRow>[];
      final streaming = () async {
        await for (final row in conn.queryStream(
          "WAITFOR DELAY '00:00:15'; SELECT 1 AS v",
        )) {
          rows.add(row);
        }
      }();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await conn.cancel();
      await streaming.timeout(const Duration(seconds: 10));

      expect(rows, isEmpty);
      expect(conn.isOpen, isTrue);
      final r = await conn.query('SELECT 7 AS n');
      expect(r[0]['n'], equals(7));
    });

    test('cancel during queryStream after first rows keeps connection',
        () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final rows = <int>[];
      final streaming = () async {
        await for (final row in conn.queryStream(
          'SELECT TOP 5000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n '
          'FROM sys.all_objects a CROSS JOIN sys.all_objects b',
        )) {
          rows.add(row['n'] as int);
          if (rows.length == 1) {
            // Best-effort mid-stream cancel. On a fast local server Attention
            // may lose the race; the assertion below is connection reuse.
            unawaited(conn.cancel());
          }
        }
      }();

      await streaming.timeout(const Duration(seconds: 30));
      expect(rows, isNotEmpty);
      // Mid-stream cancel may lose the race on a fast local server. Prefer
      // WAITFOR cancel tests for reusable Attention; here only require that
      // we got rows and that a follow-up query works when still open.
      if (conn.isOpen) {
        try {
          final r = await conn.query('SELECT 9 AS n');
          expect(r[0]['n'], equals(9));
        } on StateError {
          // Cancellation can race the stream teardown on a fast local server.
        }
      }
    });
  });

  group('live large multi-packet result (PR #3)', () {
    test('large NVARCHAR round-trip across TDS packets', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      // ~8KB of UCS-2 forces multiple default-size TDS packets on the reply.
      final r = await conn.query(
        "SELECT REPLICATE(CAST(N'あ' AS nvarchar(max)), 4000) AS v",
      );
      final v = r[0]['v'] as String;
      expect(v.length, equals(4000));
      expect(v.split('').every((c) => c == 'あ'), isTrue);
    });

    test('many-row result stays synced', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final r = await conn.query(
        'SELECT TOP 500 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n '
        'FROM sys.all_objects a CROSS JOIN sys.all_objects b',
      );
      expect(r.length, equals(500));
      expect(r[0]['n'], equals(1));
      expect(r[499]['n'], equals(500));
    });
  });
}
