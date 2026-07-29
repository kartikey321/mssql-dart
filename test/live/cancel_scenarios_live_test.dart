import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'dart:async';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Extra live Attention cancel scenarios against Docker SQL Edge.
///
/// Complements [attention_live_test.dart] / [attention_tls_live_test.dart]:
/// multi-result cancel, parameterized RPC cancel, and pool acquire/cancel.
///
/// Requires `dart-mssql` on 127.0.0.1:14330 (password `Strong_test_password_123!`).
/// Skips when unreachable.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<MssqlConnection?> tryOpen({bool encrypt = false}) async {
  try {
    return await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: encrypt,
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

  group('live cancel queryMultiple / RPC', () {
    test('cancel mid-queryMultiple WAITFOR keeps connection', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final pending = conn.queryMultiple(
        "WAITFOR DELAY '00:00:15'; SELECT 1 AS a; SELECT 2 AS b",
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await conn.cancel();

      final multi = await pending.timeout(const Duration(seconds: 10));
      expect(multi.length, equals(0));
      expect(conn.isOpen, isTrue);

      final r = await conn.query('SELECT 21 AS n');
      expect(r[0]['n'], equals(21));
    });

    test('cancel mid-parameterized WAITFOR (sp_executesql) keeps connection',
        () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final pending = conn.query(
        "WAITFOR DELAY '00:00:15'; SELECT @n AS n",
        {'n': 99},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await conn.cancel();

      final cancelled = await pending.timeout(const Duration(seconds: 10));
      expect(cancelled.rows, isEmpty);
      expect(conn.isOpen, isTrue);

      final r = await conn.query('SELECT @n AS n', {'n': 23});
      expect(r[0]['n'], equals(23));
    });

    test('cancel while idle is a no-op', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      await conn.cancel();
      final r = await conn.query('SELECT 25 AS n');
      expect(r[0]['n'], equals(25));
    });
  });

  group('live cancel via pool acquire', () {
    test('acquire, cancel WAITFOR, release, pool still usable', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final pool = MssqlPool(MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: false,
        trustServerCertificate: true,
        min: 0,
        max: 2,
      ));
      await pool.open();
      try {
        final c = await pool.acquire();
        final pending = c.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v");
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await c.cancel();
        await pending.timeout(const Duration(seconds: 10));
        await pool.release(c);

        final r = await pool.query('SELECT 27 AS n');
        expect(r[0]['n'], equals(27));
      } finally {
        await pool.close();
      }
    });

    test('pool TLS: acquire cancel then query', () async {
      if (!available) {
        markTestSkipped('SQL Server not available on :$_port');
        return;
      }

      final pool = MssqlPool(MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
        min: 0,
        max: 2,
      ));
      await pool.open();
      try {
        final c = await pool.acquire();
        final pending = c.query("WAITFOR DELAY '00:00:15'; SELECT 1 AS v");
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await c.cancel();
        await pending.timeout(const Duration(seconds: 10));
        await pool.release(c);

        final r = await pool.query('SELECT 29 AS n');
        expect(r[0]['n'], equals(29));
      } finally {
        await pool.close();
      }
    });
  });
}
