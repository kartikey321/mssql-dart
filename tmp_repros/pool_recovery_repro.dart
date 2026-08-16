import 'package:mssql/mssql.dart';

Future<void> main() async {
  final pool = MssqlPool(
    const MssqlPoolConfig(
      host: '127.0.0.1',
      port: 1433,
      user: 'sa',
      password: 'Knex_Test1!',
      database: 'knex_test',
      encrypt: true,
      trustServerCertificate: true,
      min: 0,
      max: 1,
    ),
  );
  await pool.open();

  try {
    await pool.execute(
      "IF OBJECT_ID('probe_pool_recovery') IS NOT NULL DROP TABLE probe_pool_recovery",
    );
    await pool.execute(
      'CREATE TABLE probe_pool_recovery (id INT PRIMARY KEY, name NVARCHAR(50))',
    );

    try {
      for (var i = 1; i <= 40; i++) {
        print('pool iter $i');
        await pool.execute(
          "INSERT INTO probe_pool_recovery VALUES ($i, N'a')",
        );
        await pool.query('SELECT 1 AS x');
      }
      print('unexpected: loop did not fail');
    } catch (e) {
      print('caught expected transport failure: $e');
    }

    final r = await pool.query('SELECT 1 AS x');
    print('post-failure pool query: ${r.rows.first["x"]}');
  } finally {
    await pool.close();
  }
}
