import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// TLS integration tests.
// Runs against the dart-mssql Docker container on port 14330.
// Azure SQL Edge ships with a self-signed certificate; we use
// trustServerCertificate: true to accept it.

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

void main() {
  group('TLS', () {
    test('connect with encrypt:true and trustServerCertificate:true', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      expect(conn.isOpen, isTrue);
      await conn.close();
    });

    test('basic query over TLS returns correct value', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      final r = await conn.query('SELECT 42 AS n');
      expect(r[0]['n'], equals(42));
      await conn.close();
    });

    test('query with parameters over TLS', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      final r = await conn.query('SELECT @v AS val', {'v': 'hello TLS'});
      expect(r[0]['val'], equals('hello TLS'));
      await conn.close();
    });

    test('multiple queries on same TLS connection', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      for (int i = 1; i <= 5; i++) {
        final r = await conn.query('SELECT @n AS n', {'n': i});
        expect(r[0]['n'], equals(i));
      }
      await conn.close();
    });

    test('TLS connection handles SQL error and continues', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      try {
        await conn.query('SELECT 1/0');
      } on MssqlException catch (_) {}
      // Connection must still be usable.
      final r = await conn.query('SELECT 99 AS ok');
      expect(r[0]['ok'], equals(99));
      await conn.close();
    });

    test('TLS connection handles large data (multi-packet)', () async {
      final conn = await MssqlConnection.connect(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
      );
      final r = await conn
          .query("SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 8000) AS big");
      expect((r[0]['big'] as String).length, equals(8000));
      await conn.close();
    });

    test('pool over TLS runs concurrent queries', () async {
      final pool = MssqlPool(const MssqlPoolConfig(
        host: _host,
        port: _port,
        user: _user,
        password: _password,
        database: 'master',
        encrypt: true,
        trustServerCertificate: true,
        min: 1,
        max: 3,
      ));
      await pool.open();
      try {
        final results = await Future.wait([
          pool.query('SELECT 1 AS n'),
          pool.query('SELECT 2 AS n'),
          pool.query('SELECT 3 AS n'),
        ]);
        final values = results.map((r) => r[0]['n']).toSet();
        expect(values, containsAll([1, 2, 3]));
      } finally {
        await pool.close();
      }
    });
  });
}
