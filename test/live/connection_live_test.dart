import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'live_test_helpers.dart';
import 'package:test/test.dart';

void main() {
  if (!beginLiveSuite()) return;

  group('live connection', () {
    setUpAll(waitForSqlServer);

    test('uses the configured endpoint, database, and application name',
        () async {
      final connection = await liveTestConfig.open(appName: 'mssql-dart-live');
      addTearDown(connection.close);
      final result = await connection.query(
        'SELECT DB_NAME() AS database_name, APP_NAME() AS application_name, '
        '@@SPID AS session_id',
      );
      expect(result[0]['database_name'], 'master');
      expect(result[0]['application_name'], 'mssql-dart-live');
      expect(result[0]['session_id'], isA<int>());
    });

    test('close is idempotent and a new connection can be opened', () async {
      final first = await liveTestConfig.open();
      await first.close();
      await first.close();

      final second = await liveTestConfig.open();
      addTearDown(second.close);
      expect((await second.query('SELECT 1 AS value'))[0]['value'], 1);
    });
  });
}
