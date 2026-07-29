import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'dart:async';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live pool stats / events against Docker SQL Edge.
///
/// Requires `dart-mssql` on 127.0.0.1:14330. Skips when unreachable.

final _host = liveTestConfig.host;
final _port = liveTestConfig.port;
final _user = liveTestConfig.user;
final _password = liveTestConfig.password;

Future<bool> sqlUp() async {
  try {
    final c = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 5),
    );
    await c.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  if (!beginLiveSuite()) return;
  late bool available;

  setUpAll(() async {
    available = await sqlUp();
  });

  test('acquire/release updates size/idle/inUse and fires events', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final events = <MssqlPoolEventKind>[];
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
      validateOnAcquire: false,
      resetOnRelease: false,
      onPoolEvent: (e) => events.add(e.kind),
    ));
    await pool.open();
    addTearDown(pool.close);

    expect(pool.stats.total, equals(0));

    final a = await pool.acquire();
    expect(pool.size, equals(1));
    expect(pool.borrowed, equals(1));
    expect(pool.available, equals(0));
    expect(pool.stats.created, equals(1));
    expect(pool.stats.acquired, equals(1));
    expect(events, contains(MssqlPoolEventKind.created));
    expect(events, contains(MssqlPoolEventKind.acquired));

    await pool.release(a);
    expect(pool.available, equals(1));
    expect(pool.borrowed, equals(0));
    expect(pool.stats.released, equals(1));
    expect(events, contains(MssqlPoolEventKind.released));

    final b = await pool.acquire();
    expect(pool.stats.created, equals(1)); // reused idle
    expect(pool.stats.acquired, equals(2));
    await pool.release(b);
  });

  test('waiter handoff and acquireTimeout counter', () async {
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
      max: 1,
      acquireTimeout: Duration(milliseconds: 200),
      validateOnAcquire: false,
      resetOnRelease: false,
    ));
    await pool.open();
    addTearDown(pool.close);

    final held = await pool.acquire();
    expect(pool.pending, equals(0));

    final waiter = pool.acquire();
    // Let the waiter enqueue.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pool.pending, equals(1));

    await pool.release(held);
    final handed = await waiter;
    expect(pool.stats.acquired, greaterThanOrEqualTo(2));
    expect(pool.pending, equals(0));

    // Still holding [handed] at max=1 — force timeout.
    await expectLater(pool.acquire(), throwsA(isA<MssqlException>()));
    expect(pool.stats.acquireTimeouts, equals(1));
    await pool.release(handed);
  });
}
