import 'live_test_config.dart';
import 'live_test_gate.dart';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Live INFO / PRINT diagnostics against Docker SQL Edge.
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
  });

  tearDownAll(() async {
    if (available) await conn.close();
  });

  test('PRINT delivers onInfoMessage', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    final infos = <MssqlInfoMessage>[];
    conn.onInfoMessage = infos.add;
    await conn.execute("PRINT N'hello-from-print'");
    expect(infos, isNotEmpty);
    expect(infos.any((i) => i.message.contains('hello-from-print')), isTrue);
  });

  test('ERROR exception includes severity and lineNo', () async {
    if (!available) {
      markTestSkipped('SQL Server not available on :$_port');
      return;
    }

    try {
      await conn.execute('SELECT * FROM dbo.definitely_missing_table_xyz');
      fail('expected MssqlException');
    } on MssqlException catch (e) {
      expect(e.errorCode, equals(208));
      expect(e.severity, isNotNull);
      expect(e.severity!, greaterThanOrEqualTo(11));
      expect(e.lineNo, isNotNull);
    }
  });
}
