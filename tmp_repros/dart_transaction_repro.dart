import 'package:mssql/mssql.dart';
import 'dart:io';

const host = '127.0.0.1';
const port = 1433;
const user = 'sa';
const password = 'Knex_Test1!';
const database = 'knex_test';

Future<void> main() async {
  final encrypt = (Platform.environment['MSSQL_ENCRYPT'] ?? 'true') == 'true';
  final iterations = int.parse(Platform.environment['MSSQL_ITERS'] ?? '30');
  final mode = Platform.environment['MSSQL_MODE'] ?? 'explicit';
  final tediousInit = Platform.environment['MSSQL_TEDIOUS_INIT'] == 'true';
  final c = await MssqlConnection.connect(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    encrypt: encrypt,
    trustServerCertificate: true,
  );

  try {
    if (tediousInit) {
      await c.execute('''
set ansi_nulls on
set ansi_null_dflt_on on
set ansi_padding on
set ansi_warnings on
set arithabort on
set concat_null_yields_null on
set implicit_transactions off
set language us_english
set numeric_roundabort off
set quoted_identifier on
set textsize 2147483647
set transaction isolation level read committed
''');
    }
    await c.execute("IF OBJECT_ID('probe_t2') IS NOT NULL DROP TABLE probe_t2");
    await c.execute(
        "CREATE TABLE probe_t2 (id INT PRIMARY KEY, name NVARCHAR(50))");

    print('dart $mode config: encrypt=$encrypt iterations=$iterations');
    for (var i = 1; i <= iterations; i++) {
      if (mode == 'insert' || mode == 'param') {
        print('dart $mode iter $i');
        if (mode == 'param') {
          await c.execute(
            'INSERT INTO probe_t2 VALUES (@id, @name)',
            {'id': i, 'name': 'a'},
          );
        } else {
          await c.execute("INSERT INTO probe_t2 VALUES ($i, N'a')");
        }
        final r = await c.query('SELECT 1 AS x');
        print('dart $mode iter $i: canary=${r.rows.first["x"]}');
        continue;
      }

      print('dart $mode iter $i: begin');
      if (mode == 'native') {
        await c.beginTransaction();
      } else {
        await c.execute('BEGIN TRANSACTION');
      }
      await c.execute("INSERT INTO probe_t2 VALUES ($i, N'a')");
      if (mode == 'native') {
        await c.commitTransaction();
      } else {
        await c.execute('COMMIT TRANSACTION');
      }
      final r = await c.query('SELECT 1 AS x');
      print('dart $mode iter $i: canary=${r.rows.first["x"]}');
    }

    print('dart $mode loop completed');
  } finally {
    await c.close();
  }
}
