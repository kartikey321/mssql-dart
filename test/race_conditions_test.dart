import 'dart:async';
import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Race condition and concurrency tests.
//
// Verifies that the driver is safe under concurrent use:
//   - Connection busy-guard prevents interleaved queries on a single connection
//   - Pool correctly bounds concurrency to pool.max
//   - Pool queues overflow acquires and serves them in arrival order
//   - pool.close() during in-flight work drains gracefully
//   - Double-release, release-after-close, and other misuse are handled

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection> openConn() => MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
    );

MssqlPool makePool({int min = 0, int max = 5}) => MssqlPool(MssqlPoolConfig(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: false,
      trustServerCertificate: true,
      min: min,
      max: max,
    ));

void main() {
  // ── Single-connection busy guard ──────────────────────────────────────────

  group('connection busy guard', () {
    test('concurrent query on same connection throws StateError', () async {
      final conn = await openConn();
      try {
        // Start a slow query (WAITFOR DELAY) but don't await it yet.
        unawaited(conn.query("WAITFOR DELAY '00:00:01'; SELECT 1 AS v"));

        // Immediately issue a second query — must throw because _busy = true.
        expect(
          () => conn.query('SELECT 2 AS v'),
          throwsA(isA<StateError>()),
        );

        // Let the first query finish (cancel it by closing).
      } finally {
        await conn.close();
      }
    });

    test('concurrent execute on same connection throws StateError', () async {
      final conn = await openConn();
      try {
        unawaited(conn.execute("WAITFOR DELAY '00:00:01'"));
        expect(() => conn.execute('SELECT 1'), throwsA(isA<StateError>()));
        await conn.close();
      } catch (_) {
        await conn.close();
      }
    });

    test('queryStream then query on same connection throws StateError',
        () async {
      final conn = await openConn();
      try {
        // Start streaming but don't await it.
        final stream = conn.queryStream(
            "SELECT number FROM master.dbo.spt_values WHERE type = 'P' AND number < 100");

        // The stream is lazy — the first await activates it.
        final iter = StreamIterator(stream);
        await iter.moveNext(); // now _busy = true

        // A concurrent query must be rejected.
        expect(() => conn.query('SELECT 1 AS v'), throwsA(isA<StateError>()));

        // Clean up.
        await iter.cancel();
      } finally {
        await conn.close();
      }
    });

    test('execute after query completes succeeds', () async {
      final conn = await openConn();
      try {
        await conn.query('SELECT 1 AS v');
        // _busy should be false now — a second query must succeed.
        final r = await conn.query('SELECT 2 AS v');
        expect(r[0]['v'], equals(2));
      } finally {
        await conn.close();
      }
    });
  });

  // ── Pool concurrency bounding ─────────────────────────────────────────────

  group('pool concurrency bounding', () {
    test('pool never opens more than max connections', () async {
      const maxConn = 3;
      final pool = makePool(max: maxConn);
      int peakActive = 0;
      int currentActive = 0;

      // Fire 10 concurrent queries through the pool.
      final futures = List.generate(10, (_) async {
        final conn = await pool.acquire();
        currentActive++;
        if (currentActive > peakActive) peakActive = currentActive;
        try {
          await conn.query("WAITFOR DELAY '00:00:00.1'; SELECT 1 AS v");
        } finally {
          currentActive--;
          pool.release(conn);
        }
      });

      await Future.wait(futures);
      await pool.close();

      expect(peakActive, lessThanOrEqualTo(maxConn));
    });

    test('pool.query with many concurrent callers all succeed', () async {
      final pool = makePool(max: 4);
      try {
        // 12 concurrent queries through a pool of 4 — all must complete.
        final results = await Future.wait(
          List.generate(12, (i) => pool.query('SELECT $i AS v')),
        );
        final values = results.map((r) => r[0]['v'] as int).toList()..sort();
        expect(values, equals(List.generate(12, (i) => i)));
      } finally {
        await pool.close();
      }
    });

    test('pool.execute with many concurrent callers all succeed', () async {
      final pool = makePool(max: 3);
      try {
        final ns = await Future.wait(
          List.generate(9, (_) => pool.execute('SELECT 1')),
        );
        // All should return 0 (SELECT has no affected rows beyond result set).
        for (final n in ns) {
          expect(n, isA<int>());
        }
      } finally {
        await pool.close();
      }
    });
  });

  // ── Pool pending queue ordering ───────────────────────────────────────────

  group('pool pending queue', () {
    test('pending acquires are served in FIFO order', () async {
      final pool = makePool(max: 1);
      final conn = await pool.acquire(); // fills the pool

      // Queue 5 pending acquires in order.
      final order = <int>[];
      final futures = List.generate(5, (i) async {
        final c = await pool.acquire();
        order.add(i);
        pool.release(c);
      });

      // Release the held connection — should unblock queue head first.
      await Future.microtask(() => pool.release(conn));
      await Future.wait(futures);
      await pool.close();

      // Should be strictly increasing (FIFO).
      expect(order, equals([0, 1, 2, 3, 4]));
    });

    test('multiple pending acquires all succeed when connections are released',
        () async {
      final pool = makePool(max: 2);
      final c1 = await pool.acquire();
      final c2 = await pool.acquire(); // pool full

      // Queue 4 pending acquires; each releases immediately so the next
      // waiter in the queue can also get a connection (chain relay).
      int served = 0;
      final pending = List.generate(4, (_) async {
        final c = await pool.acquire();
        served++;
        pool.release(c);
      });

      // Release both connections — triggers the relay chain.
      pool.release(c1);
      pool.release(c2);

      await Future.wait(pending);
      await pool.close();

      expect(served, equals(4));
    });
  });

  // ── Pool close during in-flight work ─────────────────────────────────────

  group('pool close during in-flight work', () {
    test('pool.close rejects all pending acquires', () async {
      final pool = makePool(max: 1);
      final conn = await pool.acquire(); // fills the pool

      // Queue 3 pending acquires.
      final futures = List.generate(
        3,
        (_) => expectLater(pool.acquire(), throwsA(isA<MssqlException>())),
      );

      // Close pool — pending acquires must all be rejected.
      await pool.close();
      await Future.wait(futures);

      // Clean up the held connection separately.
      await conn.close();
    });

    test('pool still usable by in-flight connections after close is called',
        () async {
      final pool = makePool(max: 2);
      final conn = await pool.acquire();

      // Issue a query (doesn't go through pool — uses connection directly).
      final queryFuture = conn.query('SELECT 1 AS v');

      // Close pool while query is in flight.
      final closeFuture = pool.close();

      final r = await queryFuture;
      expect(r[0]['v'], equals(1));

      pool.release(conn);
      await closeFuture;
    });
  });

  // ── Pool release safety ───────────────────────────────────────────────────

  group('pool release safety', () {
    test('releasing a connection to a closed pool discards it gracefully',
        () async {
      final pool = makePool(max: 2);
      final conn = await pool.acquire();
      await pool.close();
      // pool.release() after close should not throw — it just discards.
      expect(() => pool.release(conn), returnsNormally);
    });

    test('releasing a dead connection to pool discards it gracefully',
        () async {
      final pool = makePool(max: 2);
      final conn = await pool.acquire();
      await conn.close(); // kill the connection
      // release() with a dead connection should discard, not throw.
      expect(() => pool.release(conn), returnsNormally);
      await pool.close();
    });
  });

  // ── Concurrent transactions on pool ──────────────────────────────────────

  group('concurrent transactions on pool', () {
    // Global temp tables (##) are visible across all sessions — required here
    // because pool.transaction() routes each call to a different connection.

    test('N concurrent transactions on the pool all commit correctly',
        () async {
      final pool = makePool(max: 5);
      try {
        await pool.execute(
            'IF OBJECT_ID(\'tempdb..##race_tx\') IS NOT NULL DROP TABLE ##race_tx');
        await pool.execute('CREATE TABLE ##race_tx (id INT, v INT)');

        // 5 concurrent transactions, each inserting a unique id.
        await Future.wait(List.generate(5, (i) async {
          await pool.transaction((conn) async {
            await conn.execute('INSERT INTO ##race_tx VALUES ($i, ${i * 10})');
          });
        }));

        final r = await pool.query('SELECT COUNT(*) AS n FROM ##race_tx');
        expect(r[0]['n'], equals(5));
      } finally {
        await pool.execute(
            'IF OBJECT_ID(\'tempdb..##race_tx\') IS NOT NULL DROP TABLE ##race_tx');
        await pool.close();
      }
    });

    test('transaction rollback on error does not affect other transactions',
        () async {
      final pool = makePool(max: 4);
      try {
        await pool.execute(
            'IF OBJECT_ID(\'tempdb..##race_rollback\') IS NOT NULL DROP TABLE ##race_rollback');
        await pool.execute('CREATE TABLE ##race_rollback (v INT)');

        final futures = <Future>[];
        // Mix of succeeding and failing transactions.
        for (int i = 0; i < 4; i++) {
          if (i % 2 == 0) {
            futures.add(pool.transaction((conn) async {
              await conn.execute('INSERT INTO ##race_rollback VALUES ($i)');
            }));
          } else {
            futures.add(() async {
              try {
                await pool.transaction((conn) async {
                  await conn.execute('INSERT INTO ##race_rollback VALUES ($i)');
                  throw Exception('intentional rollback $i');
                });
              } catch (_) {}
            }());
          }
        }
        await Future.wait(futures);

        // Only the even-numbered rows should have committed.
        final r = await pool.query('SELECT COUNT(*) AS n FROM ##race_rollback');
        expect(r[0]['n'], equals(2)); // i=0 and i=2
      } finally {
        await pool.execute(
            'IF OBJECT_ID(\'tempdb..##race_rollback\') IS NOT NULL DROP TABLE ##race_rollback');
        await pool.close();
      }
    });
  });

  // ── queryStream concurrent safety ─────────────────────────────────────────

  group('queryStream concurrent safety', () {
    test('two connections can stream concurrently without interference',
        () async {
      final conn1 = await openConn();
      final conn2 = await openConn();
      try {
        // Both connections streaming at the same time.
        final stream1 = conn1.queryStream(
            "SELECT number AS v FROM master.dbo.spt_values WHERE type='P' AND number < 50");
        final stream2 = conn2.queryStream(
            "SELECT number AS v FROM master.dbo.spt_values WHERE type='P' AND number < 50");

        final results = await Future.wait([
          stream1.map((r) => r['v'] as int).toList(),
          stream2.map((r) => r['v'] as int).toList(),
        ]);

        // Both should return identical results.
        expect(results[0]..sort(), equals(results[1]..sort()));
        expect(results[0].length, equals(50));
      } finally {
        await conn1.close();
        await conn2.close();
      }
    });

    test('pool handles concurrent queryStream calls across connections',
        () async {
      final pool = makePool(max: 3);
      try {
        // 3 concurrent queryStreams, each on their own pool connection.
        final futures = List.generate(3, (i) async {
          final rows = <int>[];
          await for (final row in pool.queryStream(
              "SELECT number AS v FROM master.dbo.spt_values WHERE type='P' AND number < 10")) {
            rows.add(row['v'] as int);
          }
          return rows.length;
        });

        final counts = await Future.wait(futures);
        for (final count in counts) {
          expect(count, equals(10));
        }
      } finally {
        await pool.close();
      }
    });
  });

  // ── Stress test ───────────────────────────────────────────────────────────

  group('stress', () {
    test('50 concurrent pool.query calls complete without error', () async {
      final pool = makePool(max: 5);
      try {
        final results = await Future.wait(
          List.generate(50, (i) => pool.query('SELECT $i AS v')),
        );
        expect(results.length, equals(50));
        for (int i = 0; i < 50; i++) {
          expect(results[i][0]['v'], equals(i));
        }
      } finally {
        await pool.close();
      }
    });

    test('mixed query/execute/queryMultiple on pool under load', () async {
      final pool = makePool(max: 4);
      try {
        final futures = <Future>[];
        for (int i = 0; i < 20; i++) {
          switch (i % 3) {
            case 0:
              futures.add(pool.query('SELECT $i AS v'));
            case 1:
              futures.add(pool.execute('SELECT $i'));
            case 2:
              futures.add(
                  pool.queryMultiple('SELECT $i AS a; SELECT ${i + 1} AS b'));
          }
        }
        // All must complete without throwing.
        await Future.wait(futures);
      } finally {
        await pool.close();
      }
    });
  });
}
