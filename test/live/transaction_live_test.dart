import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live savepoint + isolation tests against Docker SQL Edge.
///
/// Skips when 127.0.0.1:14330 is unreachable.

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
      timeout: const Duration(seconds: 5),
    );
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
    if (c == null) return;
    conn = c;
    available = true;
    await conn.execute(
      'IF OBJECT_ID(N\'tempdb..##dart_tx_sp\') IS NOT NULL '
      'DROP TABLE ##dart_tx_sp',
    );
    await conn.execute(
      'CREATE TABLE ##dart_tx_sp (id INT NOT NULL PRIMARY KEY, v NVARCHAR(32))',
    );
  });

  tearDownAll(() async {
    if (!available) return;
    try {
      await conn.execute(
        'IF OBJECT_ID(N\'tempdb..##dart_tx_sp\') IS NOT NULL '
        'DROP TABLE ##dart_tx_sp',
      );
    } catch (_) {}
    await conn.close();
  });

  setUp(() async {
    if (!available) return;
    await conn.execute('DELETE FROM ##dart_tx_sp');
  });

  test('savepoint rollback keeps prior inserts in open txn', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    await conn.beginTransaction();
    try {
      await conn.execute(
        "INSERT INTO ##dart_tx_sp (id, v) VALUES (1, N'keep')",
      );
      await conn.savepoint('after_keep');
      await conn.execute(
        "INSERT INTO ##dart_tx_sp (id, v) VALUES (2, N'drop')",
      );
      await conn.rollbackTo('after_keep');
      final mid = await conn.query(
        'SELECT id FROM ##dart_tx_sp ORDER BY id',
      );
      expect(mid.rows.map((r) => r['id']).toList(), equals([1]));
      await conn.commitTransaction();
    } catch (e) {
      try {
        await conn.rollbackTransaction();
      } catch (_) {}
      rethrow;
    }

    final after = await conn.query(
      'SELECT id FROM ##dart_tx_sp ORDER BY id',
    );
    expect(after.rows.map((r) => r['id']).toList(), equals([1]));
  });

  test('transaction(isolation: serializable) commits', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    await conn.transaction(
      (c) async {
        await c.execute(
          "INSERT INTO ##dart_tx_sp (id, v) VALUES (10, N'ser')",
        );
      },
      isolation: MssqlIsolationLevel.serializable,
    );

    final r = await conn.query(
      'SELECT v FROM ##dart_tx_sp WHERE id = 10',
    );
    expect(r[0]['v'], equals('ser'));
  });

  test('beginTransaction(isolation: readCommitted) works', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    await conn.beginTransaction(
      isolation: MssqlIsolationLevel.readCommitted,
    );
    try {
      await conn.execute(
        "INSERT INTO ##dart_tx_sp (id, v) VALUES (20, N'rc')",
      );
      await conn.commitTransaction();
    } catch (_) {
      await conn.rollbackTransaction();
      rethrow;
    }
    final r = await conn.query(
      'SELECT v FROM ##dart_tx_sp WHERE id = 20',
    );
    expect(r[0]['v'], equals('rc'));
  });
}
