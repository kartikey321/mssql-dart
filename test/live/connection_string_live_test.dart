import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

import 'live_test_config.dart';
import 'live_test_gate.dart';

void main() {
  if (!beginLiveSuite()) return;

  test('connectFromString connects with an ADO string', () async {
    final config = liveTestConfig;
    final conn = await MssqlConnection.connectFromString(
      'Server=${config.host},${config.port};'
      'Database=master;User Id=${config.user};'
      'Password=${config.password};Encrypt=false;'
      'TrustServerCertificate=${config.trustServerCertificate};'
      'App Name=cstr-test;',
    );
    addTearDown(conn.close);

    expect(conn.appName, 'cstr-test');
    final result = await conn.query('SELECT 1 AS ok');
    expect(result[0]['ok'], 1);
  });
}
