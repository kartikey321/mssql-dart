import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'dart:async';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live Attention cancel **over TLS** against Docker SQL Edge.
///
/// Complements [attention_live_test.dart] (encrypt:false) and [tls_test.dart]
/// (no cancel). Exercises Attention + doneAttn drain on the TDS-wrapped TLS
/// path used in production.
///
/// Requires `dart-mssql` on 127.0.0.1:14330 (password `Strong_test_password_123!`).
/// Skips when unreachable.
///
/// Sources: ms-tds Attention; go-mssqldb cancel; SQL Edge self-signed cert.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<MssqlConnection?> tryOpenTls() async {
  try {
    return await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: true,
      trustServerCertificate: true,
    ).timeout(const Duration(seconds: 8));
  } catch (_) {
    return null;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  late MssqlConnection conn;
  var available = false;

  setUpAll(() async {
    final c = await tryOpenTls();
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

  group('live Attention cancel over TLS', () {
    test('cancel mid-WAITFOR then connection still usable', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final pending = conn.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v");
      await Future<void>.delayed(const Duration(milliseconds: 250));
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

      await Future<void>.delayed(const Duration(milliseconds: 250));
      await conn.cancel();
      await streaming.timeout(const Duration(seconds: 10));

      expect(rows, isEmpty);
      expect(conn.isOpen, isTrue);
      final r = await conn.query('SELECT 7 AS n');
      expect(r[0]['n'], equals(7));
    });

    test('cancel mid-row stream then large NVARCHAR still works', () async {
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
      expect(conn.isOpen, isTrue);

      // Multi-packet TLS reply after Attention drain (PR #3 + encrypt path).
      final r = await conn.query(
        "SELECT REPLICATE(CAST(N'あ' AS nvarchar(max)), 3000) AS v",
      );
      expect((r[0]['v'] as String).length, equals(3000));
    });

    test('cancel inside open transaction leaves connection usable', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      await conn.beginTransaction();
      final pending = conn.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v");
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await conn.cancel();
      await pending.timeout(const Duration(seconds: 10));

      // Roll back any still-open txn; then prove a fresh batch works.
      try {
        await conn.rollbackTransaction();
      } catch (_) {
        // Cancel may have aborted the batch such that no txn remains.
      }

      final r = await conn.query('SELECT 11 AS n');
      expect(r[0]['n'], equals(11));
      expect(conn.isOpen, isTrue);
    });

    test('back-to-back cancels then query', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      for (var i = 0; i < 2; i++) {
        final pending = conn.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v");
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await conn.cancel();
        await pending.timeout(const Duration(seconds: 10));
      }

      final r = await conn.query('SELECT 13 AS n');
      expect(r[0]['n'], equals(13));
    });
  });
}
