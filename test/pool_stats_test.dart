import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Offline pool observability surface (stats snapshot + event wiring).
///
/// Pattern source: node-mssql / tarn `pool.size` / `available` / `pending` /
/// `borrowed` plus lifetime counters for LAN ops dashboards.

void main() {
  group('MssqlPoolStats', () {
    test('empty pool reports zeros', () {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: '127.0.0.1',
        user: 'sa',
        password: 'x',
        max: 4,
      ));
      final s = pool.stats;
      expect(s.total, equals(0));
      expect(s.idle, equals(0));
      expect(s.inUse, equals(0));
      expect(s.pending, equals(0));
      expect(s.max, equals(4));
      expect(s.created, equals(0));
      expect(s.destroyed, equals(0));
      expect(s.acquired, equals(0));
      expect(s.released, equals(0));
      expect(s.acquireTimeouts, equals(0));
      expect(s.validationFailures, equals(0));
      expect(s.resetFailures, equals(0));
      expect(pool.size, equals(0));
      expect(pool.available, equals(0));
      expect(pool.borrowed, equals(0));
      expect(pool.pending, equals(0));
    });

    test('onPoolEvent seeds pool.onEvent', () {
      MssqlPoolEvent? seen;
      final pool = MssqlPool(MssqlPoolConfig(
        host: '127.0.0.1',
        user: 'sa',
        password: 'x',
        onPoolEvent: (e) => seen = e,
      ));
      expect(pool.onEvent, isNotNull);
      // Synthesize via public assignable hook path: call the seeded handler.
      pool.onEvent!(MssqlPoolEvent(
        kind: MssqlPoolEventKind.created,
        at: DateTime.utc(2024, 1, 1),
        stats: pool.stats,
      ));
      expect(seen?.kind, equals(MssqlPoolEventKind.created));
    });

    test('toString includes key counters', () {
      const s = MssqlPoolStats(
        total: 2,
        idle: 1,
        inUse: 1,
        pending: 0,
        max: 10,
        created: 3,
        destroyed: 1,
        acquired: 5,
        released: 4,
        acquireTimeouts: 0,
        validationFailures: 0,
        resetFailures: 0,
      );
      expect(s.toString(), contains('total=2'));
      expect(s.toString(), contains('created=3'));
    });
  });
}
