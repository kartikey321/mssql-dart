import 'package:test/test.dart';
import 'package:mssql/mssql.dart';

// Regression tests for TLS record-wrap alignment (see lib/src/tds/constants.dart).
//
// dart:io's SecureSocket seals a write that crosses its SSL-filter plaintext
// ring wrap (every 8 KiB / 2 of sealed traffic) as two TLS records, and SQL
// Server rejects TDS packets that span TLS records. The driver keeps every
// message end aligned to a packetSize multiple so wraps always land on packet
// boundaries. These tests hammer the wrap repeatedly with varied statement
// sizes; a Dart SDK change to the ring (size or phase) or a regression in the
// alignment logic surfaces here as `Connection closed mid-header`.
//
// Runs against a SQL Server container on port 14330 (see CI workflow).

const _host = '127.0.0.1';
const _port = 14330;
const _user = 'sa';
const _password = 'Knex_Test1!';

Future<MssqlConnection> _connect() => MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      database: 'master',
      encrypt: true,
      trustServerCertificate: true,
    );

void main() {
  group('TLS wrap alignment', () {
    // Each small statement seals ~512 bytes (one aligned message), so the
    // 8 KiB ring wrap recurs every ~16 statements; 320 statements cross it
    // about 20 times, with varied payload sizes and both batch and
    // parameterized (sp_executesql, incl. parity-dummy) paths.
    test('statement soak crosses many record-wrap boundaries', () async {
      final conn = await _connect();
      try {
        for (var i = 1; i <= 320; i++) {
          final filler = 'x' * (i % 97); // varied natural payload sizes
          switch (i % 4) {
            case 0:
              final r = await conn.query('SELECT $i AS n, \'$filler\' AS s');
              expect(r[0]['n'], equals(i));
            case 1:
              final r = await conn.query(
                  'SELECT @v AS n', {'v': i}); // int param -> odd parity
              expect(r[0]['n'], equals(i));
            case 2:
              final n = await conn.execute('SELECT $i AS n, \'$filler\' AS s');
              expect(n, equals(1));
            default:
              final r = await conn
                  .query('SELECT @v AS n', {'v': 'v$filler'}); // string param
              expect(r[0]['n'], equals('v$filler'));
          }
        }
      } finally {
        await conn.close();
      }
    });

    test('chained multi-packet batch (pacing) survives TLS', () async {
      final conn = await _connect();
      final table = 'wrap_reg_batch';
      try {
        await conn.execute(
            "IF OBJECT_ID('$table') IS NOT NULL DROP TABLE $table");
        await conn.execute('CREATE TABLE $table (id INT PRIMARY KEY, pad NVARCHAR(4000))');
        final pad = 'p' * 500;
        final values =
            List.generate(20, (i) => '($i, N\'$pad\')').join(', ');
        final n = await conn.execute('INSERT INTO $table VALUES $values');
        expect(n, equals(20));
        final r = await conn.query('SELECT COUNT(*) AS c FROM $table');
        expect(r[0]['c'], equals(20));
      } finally {
        await conn.execute(
            "IF OBJECT_ID('$table') IS NOT NULL DROP TABLE $table");
        await conn.close();
      }
    });

    test('large parameterized RPC (padding + parity dummy) survives TLS',
        () async {
      final conn = await _connect();
      final table = 'wrap_reg_rpc';
      try {
        await conn.execute(
            "IF OBJECT_ID('$table') IS NOT NULL DROP TABLE $table");
        await conn.execute(
            'CREATE TABLE $table (id INT PRIMARY KEY, pad NVARCHAR(MAX))');
        final big = 'r' * 20000;
        await conn.execute(
            'INSERT INTO $table (id, pad) VALUES (@id, @pad)',
            {'id': 1, 'pad': big});
        await conn.execute('UPDATE $table SET pad = @pad WHERE id = @id',
            {'id': 1, 'pad': 's' * 5000});
        final r = await conn.query('SELECT id, DATALENGTH(pad) AS sz FROM $table');
        expect(r[0]['sz'], equals(10000));
      } finally {
        await conn.execute(
            "IF OBJECT_ID('$table') IS NOT NULL DROP TABLE $table");
        await conn.close();
      }
    });

    // Plan-cache regression: the alignment padding for parameterized queries
    // rides in the value of a dummy varbinary(max) parameter, so varying
    // value lengths must not multiply cached plans (sp_executesql keys cover
    // only the statement text and @params declaration).
    test('varying parameter lengths keep one cached plan', () async {
      final conn = await _connect();
      final marker =
          'vlp${DateTime.now().millisecondsSinceEpoch % 100000000}';
      try {
        final stmt = 'SELECT @v AS $marker, DATALENGTH(@v) AS sz';
        for (final len in [1, 2, 3, 5, 8, 13, 200, 7, 1000, 3, 21]) {
          final r = await conn.query(stmt, {'v': 'x' * len});
          expect(r[0]['sz'], equals(len * 2));
        }
        final plans = await conn.query(
            'SELECT COUNT(*) AS plans FROM sys.dm_exec_cached_plans '
            'CROSS APPLY sys.dm_exec_sql_text(plan_handle) '
            'WHERE text LIKE @pat AND objtype = @ot',
            {'pat': '%$marker%', 'ot': 'Prepared'});
        expect(plans[0]['plans'], equals(1));
      } finally {
        await conn.close();
      }
    });
  });
}
