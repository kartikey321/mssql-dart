import 'dart:async';
import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Regression tests for three fixes to MssqlPool / MssqlConnection:
//   - _reapIdle() could drop below config.min when several idle connections
//     went stale at the same tick, instead of stopping at min.
//   - MssqlPool.acquire() leaked _total by one on the close-during-connect
//     race (no independently observable effect today given the pool's
//     one-way close lifecycle, so it has no dedicated test here — see the
//     commit message).
//   - query() / execute() / queryStream() had no way to bound how long they
//     wait for the server's response.
//
// Needs a real SQL Server, matching race_conditions_test.dart's convention.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

MssqlPool makePool({
  int min = 0,
  int max = 5,
  Duration idleTimeout = const Duration(seconds: 30),
  Duration idleCheckInterval = const Duration(seconds: 10),
}) =>
    MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: min,
      max: max,
      idleTimeout: idleTimeout,
      idleCheckInterval: idleCheckInterval,
    ));

Future<MssqlConnection> openConn() => MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );

void main() {
  group('_reapIdle does not drop below config.min', () {
    test(
        'a burst of idle connections going stale at the same tick leaves '
        'exactly min behind, not zero', () async {
      // Fast idleTimeout/idleCheckInterval so the test doesn't wait out the
      // real 30s/10s defaults.
      final pool = makePool(
        min: 2,
        max: 5,
        idleTimeout: const Duration(milliseconds: 150),
        idleCheckInterval: const Duration(milliseconds: 200),
      );
      addTearDown(() => pool.close());

      // open() is what starts the periodic reap timer (_startIdleTimer is
      // only called from there) — skipping it, as an earlier version of
      // this test did, means _reapIdle() never runs at all, no matter how
      // long the test then waits. With min: 2 this also pre-creates 2 idle
      // connections; the acquire loop below folds those into the same
      // 5-at-once batch rather than creating 5 more on top.
      await pool.open();

      // Acquire 5 (up to max) and release all 5 at once, so all 5 go idle
      // together — the exact repro from the issue: several idle connections
      // all past idleTimeout at the same reap tick.
      final original = <MssqlConnection>[];
      for (var i = 0; i < 5; i++) {
        original.add(await pool.acquire());
      }
      for (final c in original) {
        pool.release(c);
      }

      // Outlive idleTimeout and at least one reap tick, with margin for a
      // slower CI runner.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // If the bug is present, _reapIdle discarded all 5 (not just the
      // 3 over min), so these next `min` acquires get brand new
      // connections rather than any of the ones just idled.
      final afterReap = <MssqlConnection>[];
      for (var i = 0; i < 2; i++) {
        afterReap.add(await pool.acquire());
      }
      final reused =
          afterReap.where((c) => original.any((o) => identical(o, c)));
      expect(reused.length, 2,
          reason: 'expected both of the min=2 kept-idle connections to be '
              'handed back, not newly opened ones');

      // The 3 beyond min must still have been correctly discarded (not a
      // "keep everything" regression in the other direction): a further
      // acquire must NOT be one of the 5 originals still unaccounted for.
      final stillUnseen = original
          .where((o) => !afterReap.any((c) => identical(o, c)))
          .toList();
      final extra = await pool.acquire();
      expect(stillUnseen.any((o) => identical(o, extra)), isFalse,
          reason: 'a connection beyond min should have been closed by the '
              'reap, not kept idle indefinitely');
    });
  });

  group('per-query timeout', () {
    test('query() throws and marks the connection dead when the server '
        'takes too long', () async {
      final conn = await openConn();
      addTearDown(() => conn.close());

      await expectLater(
        conn.query(
            "WAITFOR DELAY '00:00:03'", const {}, const Duration(milliseconds: 400)),
        throwsA(isA<MssqlException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
      expect(conn.isOpen, isFalse,
          reason: 'a timed-out query leaves the TDS buffer mid-response; '
              'the connection must not be left usable in that state');
    });

    test('query() does not time out when the server responds well within '
        'the given duration', () async {
      final conn = await openConn();
      addTearDown(() => conn.close());

      final result =
          await conn.query('SELECT 1 AS n', const {}, const Duration(seconds: 5));
      expect(result[0]['n'], 1);
      expect(conn.isOpen, isTrue);
    });

    test(
        'queryStream() times out as a stall guard — no row within the '
        'duration — and marks the connection dead', () async {
      final conn = await openConn();
      addTearDown(() => conn.close());

      final rows = <Object?>[];
      await expectLater(
        conn
            .queryStream("WAITFOR DELAY '00:00:03'; SELECT 1", const {},
                const Duration(milliseconds: 400))
            .forEach(rows.add),
        throwsA(isA<MssqlException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
      expect(rows, isEmpty);
      expect(conn.isOpen, isFalse);
    });

    test('MssqlPool.query() forwards timeout to the acquired connection',
        () async {
      final pool = makePool(min: 0, max: 2);
      addTearDown(() => pool.close());

      await expectLater(
        pool.query("WAITFOR DELAY '00:00:03'", const {},
            const Duration(milliseconds: 400)),
        throwsA(isA<MssqlException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
    });
  });
}
