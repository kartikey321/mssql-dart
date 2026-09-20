import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// Live TDS 8.0 strict-mode tests. They need a SQL Server 2022+ that accepts
// strict connections and presents a certificate the machine trusts, so they
// only run when MSSQL_STRICT_HOST is set (the CI "strict" job sets it up;
// see .github/workflows/publish.yml). Otherwise every test here is skipped.
//
//   MSSQL_STRICT_HOST    hostname matching the certificate, e.g. localhost
//   MSSQL_STRICT_PORT    default 14330
//   MSSQL_STRICT_USER / MSSQL_STRICT_PASSWORD   default sa / Knex_Test1!
//   MSSQL_STRICT_FORCED  "true" if the server rejects non-strict clients

final Map<String, String> _envMap = Platform.environment;
final String? _host = _envMap['MSSQL_STRICT_HOST'];

Future<MssqlConnection> _connect({String? database}) => MssqlConnection.connect(
      host: _host!,
      port: int.parse(_envMap['MSSQL_STRICT_PORT'] ?? '14330'),
      user: _envMap['MSSQL_STRICT_USER'] ?? 'sa',
      password: _envMap['MSSQL_STRICT_PASSWORD'] ?? 'Knex_Test1!',
      database: database ?? 'master',
      encryptMode: MssqlEncryptMode.strict,
    );

void main() {
  final skip = _host == null
      ? 'set MSSQL_STRICT_HOST to run against a strict-capable server'
      : null;

  group('TDS 8.0 strict mode (live)', () {
    test('connects and runs queries over strict TLS', () async {
      final conn = await _connect();
      try {
        final r = await conn.query('SELECT 1 AS one, @@VERSION AS v');
        expect(r[0]['one'], equals(1));
        expect(r[0]['v'], contains('Microsoft SQL Server'));
      } finally {
        await conn.close();
      }
    }, skip: skip);

    test('the session is encrypted', () async {
      final conn = await _connect();
      try {
        final r = await conn.query('SELECT encrypt_option AS e '
            'FROM sys.dm_exec_connections WHERE session_id = @@SPID');
        expect(r[0]['e'].toString().toUpperCase(), equals('TRUE'));
      } finally {
        await conn.close();
      }
    }, skip: skip);

    // Same wrap-boundary soak as tls_wrap_alignment_test, on the strict path
    // (which uses the same SecureSocket and the same message alignment).
    test('statement soak crosses many record-wrap boundaries', () async {
      final conn = await _connect();
      try {
        for (var i = 1; i <= 320; i++) {
          final filler = 'x' * (i % 97);
          switch (i % 4) {
            case 0:
              final r = await conn.query('SELECT $i AS n, \'$filler\' AS s');
              expect(r[0]['n'], equals(i));
            case 1:
              final r = await conn.query('SELECT @v AS n', {'v': i});
              expect(r[0]['n'], equals(i));
            case 2:
              final n = await conn.execute('SELECT $i AS n, \'$filler\' AS s');
              expect(n, equals(1));
            default:
              final r = await conn.query('SELECT @v AS n', {'v': 'v$filler'});
              expect(r[0]['n'], equals('v$filler'));
          }
        }
      } finally {
        await conn.close();
      }
    }, skip: skip);

    test('large chained batch and parameterized RPC survive strict TLS',
        () async {
      final conn = await _connect();
      const table = 'strict_live_big';
      try {
        await conn
            .execute("IF OBJECT_ID('$table') IS NOT NULL DROP TABLE $table");
        await conn.execute(
            'CREATE TABLE $table (id INT PRIMARY KEY, pad NVARCHAR(MAX))');
        final pad = 'p' * 500;
        final values = List.generate(20, (i) => "($i, N'$pad')").join(', ');
        expect(await conn.execute('INSERT INTO $table VALUES $values'),
            equals(20));
        await conn.execute('INSERT INTO $table (id, pad) VALUES (@id, @pad)',
            {'id': 100, 'pad': 'r' * 20000});
        final r = await conn
            .query('SELECT DATALENGTH(pad) AS sz FROM $table WHERE id = 100');
        expect(r[0]['sz'], equals(40000));
      } finally {
        await conn
            .execute("IF OBJECT_ID('$table') IS NOT NULL DROP TABLE $table");
        await conn.close();
      }
    }, skip: skip);

    test('transactions and errors leave the connection usable', () async {
      final conn = await _connect();
      try {
        await conn.execute('BEGIN TRANSACTION');
        await conn.execute('ROLLBACK TRANSACTION');
        await expectLater(conn.query('SELECT * FROM no_such_table_strict'),
            throwsA(isA<MssqlException>()));
        final r = await conn.query('SELECT 2 AS n');
        expect(r[0]['n'], equals(2));
      } finally {
        await conn.close();
      }
    }, skip: skip);

    test('a server that forces strict rejects a legacy TDS 7.x client',
        () async {
      await expectLater(
        MssqlConnection.connect(
          host: _host!,
          port: int.parse(_envMap['MSSQL_STRICT_PORT'] ?? '14330'),
          user: 'sa',
          password: _envMap['MSSQL_STRICT_PASSWORD'] ?? 'Knex_Test1!',
          encrypt: true,
          trustServerCertificate: true,
          timeout: const Duration(seconds: 10),
        ),
        throwsA(anything),
      );
    },
        skip: skip ??
            (_envMap['MSSQL_STRICT_FORCED'] == 'true'
                ? null
                : 'server is not configured to force strict'));
  });
}
