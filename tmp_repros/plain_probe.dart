import 'package:mssql/mssql.dart';
import 'dart:io';
Future<void> main() async {
  print('connecting...');
  final c = await MssqlConnection.connect(
    host: '127.0.0.1', port: 1433, user: 'sa', password: 'Knex_Test1!',
    database: 'knex_test', encrypt: false,
  );
  print('connected, db=${c.database}');
  final r = await c.query('SELECT 1 AS x');
  print('result: ${r.rows.first["x"]}');
  await c.close();
  exit(0);
}
