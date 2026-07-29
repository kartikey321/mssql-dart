import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live TVP against Docker SQL Edge.
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

  test('query with MssqlTvp selects rows from table type', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final conn = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(conn.close);

    // Drop dependents then type (ignore errors if missing).
    try {
      await conn.query('DROP TYPE IF EXISTS dbo.dart_tvp_demo');
    } catch (_) {}
    await conn.query(
      'CREATE TYPE dbo.dart_tvp_demo AS TABLE ('
      'Id BIGINT NULL, Label NVARCHAR(50) NULL)',
    );
    addTearDown(() async {
      try {
        await conn.query('DROP TYPE IF EXISTS dbo.dart_tvp_demo');
      } catch (_) {}
    });

    final result = await conn.query(
      'SELECT Id, Label FROM @t ORDER BY Id',
      {
        't': MssqlTvp(
          typeName: 'dbo.dart_tvp_demo',
          columns: [
            const BulkColumn('Id', BulkColumnType.bigInt),
            const BulkColumn('Label', BulkColumnType.nVarChar),
          ],
          rows: [
            [10, 'ten'],
            [20, 'twenty'],
          ],
        ),
      },
    );

    expect(result.length, 2);
    expect(result[0]['Id'], 10);
    expect(result[0]['Label'], 'ten');
    expect(result[1]['Id'], 20);
  });

  test('empty TVP yields no rows', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final conn = await MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'tempdb',
      encrypt: false,
      trustServerCertificate: true,
    );
    addTearDown(conn.close);

    try {
      await conn.query('DROP TYPE IF EXISTS dbo.dart_tvp_empty');
    } catch (_) {}
    await conn.query(
      'CREATE TYPE dbo.dart_tvp_empty AS TABLE (Id BIGINT NULL)',
    );
    addTearDown(() async {
      try {
        await conn.query('DROP TYPE IF EXISTS dbo.dart_tvp_empty');
      } catch (_) {}
    });

    final result = await conn.query(
      'SELECT Id FROM @t',
      {
        't': const MssqlTvp(
          typeName: 'dbo.dart_tvp_empty',
          columns: [BulkColumn('Id', BulkColumnType.bigInt)],
        ),
      },
    );
    expect(result.isEmpty, isTrue);
  });
}
