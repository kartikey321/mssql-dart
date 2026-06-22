import 'package:mssql/mssql.dart';

void main() async {
  print('Connecting...');
  final conn = await MssqlConnection.connect(
    host: '127.0.0.1',
    port: 14330,
    user: 'sa',
    password: 'Knex_Test1!',
    database: 'master',
    trustServerCertificate: true,
  );
  print('Connected! database=${conn.database}');

  // Basic scalar query
  final r1 = await conn.query('SELECT @@VERSION AS ver');
  print('SQL Server version: ${r1[0]['ver']}');

  // Integer types
  final r2 = await conn.query('SELECT 1 AS a, 2 AS b, 3 AS c');
  print('Integers: a=${r2[0]['a']} b=${r2[0]['b']} c=${r2[0]['c']}');

  // String type
  final r3 = await conn.query("SELECT N'hello world' AS msg");
  print('String: ${r3[0]['msg']}');

  // Parameterised query
  final r4 = await conn.query(
    'SELECT @val * 2 AS doubled',
    {'val': 21},
  );
  print('Param result: ${r4[0]['doubled']}');

  // NULL handling
  final r5 = await conn.query('SELECT NULL AS n, 42 AS x');
  print('Null: n=${r5[0]['n']} x=${r5[0]['x']}');

  // Multiple rows
  final r6 = await conn.query(
    'SELECT name FROM sys.databases ORDER BY name',
  );
  print('Databases (${r6.length} rows):');
  for (final row in r6.rows) {
    print('  ${row['name']}');
  }

  await conn.close();
  print('Done.');
}
