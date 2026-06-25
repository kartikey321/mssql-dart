import 'package:mssql/mssql.dart';

void main() async {
  // ── Single connection ────────────────────────────────────────────────────

  final conn = await MssqlConnection.connect(
    host: 'localhost',
    port: 1433,
    user: 'sa',
    password: 'P@ssw0rd',
    database: 'MyDb',
    encrypt: true,
    trustServerCertificate: false,
  );

  // Query with named parameters
  final result = await conn.query(
    'SELECT id, name FROM users WHERE active = @active',
    {'active': true},
  );

  for (final row in result.rows) {
    print('${row['id']}: ${row['name']}');
  }

  // Execute DML — returns rows affected
  final n = await conn.execute(
    'UPDATE users SET last_seen = @ts WHERE id = @id',
    {'ts': DateTime.now(), 'id': 1},
  );
  print('Updated $n row(s)');

  // Multiple result sets
  final multi = await conn.queryMultiple(
    'SELECT 1 AS a; SELECT 2 AS b',
  );
  print(multi.first[0]['a']); // 1
  print(multi.second[0]['b']); // 2

  // Stream a large result set row-by-row
  await for (final row in conn.queryStream('SELECT * FROM logs ORDER BY id')) {
    print(row['message']);
  }

  // Transaction — commits on success, rolls back on exception
  await conn.transaction((c) async {
    await c.execute('INSERT INTO accounts (id, balance) VALUES (1, 100)');
    await c.execute('INSERT INTO accounts (id, balance) VALUES (2, 200)');
  });

  await conn.close();

  // ── Connection pool ──────────────────────────────────────────────────────

  final pool = MssqlPool(MssqlPoolConfig(
    host: 'localhost',
    port: 1433,
    user: 'sa',
    password: 'P@ssw0rd',
    database: 'MyDb',
    min: 2,
    max: 10,
    idleTimeout: const Duration(seconds: 30),
    acquireTimeout: const Duration(seconds: 15),
  ));

  // Pool exposes the same query API as a single connection
  final users = await pool.query('SELECT * FROM users WHERE id = @id', {'id': 1});
  print(users[0]['name']);

  await pool.transaction((c) async {
    await c.execute('INSERT INTO orders (user_id, total) VALUES (@uid, @total)',
        {'uid': 1, 'total': 99.99});
  });

  await pool.close();
}
