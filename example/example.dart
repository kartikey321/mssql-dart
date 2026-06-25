import 'dart:io';

import 'package:mssql/mssql.dart';

// Read connection details from environment variables so no credentials are
// hardcoded in source. Set them before running:
//   export MSSQL_HOST=localhost
//   export MSSQL_USER=sa
//   export MSSQL_PASSWORD=your_password
//   export MSSQL_DATABASE=MyDb
String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;

void main() async {
  // ── Single connection ────────────────────────────────────────────────────

  final conn = await MssqlConnection.connect(
    host: _env('MSSQL_HOST', 'localhost'),
    port: int.parse(_env('MSSQL_PORT', '1433')),
    user: _env('MSSQL_USER', 'sa'),
    password: _env('MSSQL_PASSWORD', ''),
    database: _env('MSSQL_DATABASE', 'MyDb'),
    encrypt: true,
    trustServerCertificate: false,
  );

  try {
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
    final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
    print(multi.first[0]['a']); // 1
    print(multi.second[0]['b']); // 2

    // Stream a large result set row-by-row
    await for (final row
        in conn.queryStream('SELECT * FROM logs ORDER BY id')) {
      print(row['message']);
    }

    // Transaction — commits on success, rolls back on exception
    await conn.transaction((c) async {
      await c.execute('INSERT INTO accounts (id, balance) VALUES (1, 100)');
      await c.execute('INSERT INTO accounts (id, balance) VALUES (2, 200)');
    });
  } finally {
    await conn.close();
  }

  // ── Connection pool ──────────────────────────────────────────────────────

  final pool = MssqlPool(MssqlPoolConfig(
    host: _env('MSSQL_HOST', 'localhost'),
    port: int.parse(_env('MSSQL_PORT', '1433')),
    user: _env('MSSQL_USER', 'sa'),
    password: _env('MSSQL_PASSWORD', ''),
    database: _env('MSSQL_DATABASE', 'MyDb'),
    min: 2,
    max: 10,
    idleTimeout: const Duration(seconds: 30),
    acquireTimeout: const Duration(seconds: 15),
  ));

  try {
    // Pool exposes the same query API as a single connection
    final users = await pool.query(
      'SELECT * FROM users WHERE id = @id',
      {'id': 1},
    );
    print(users[0]['name']);

    await pool.transaction((c) async {
      await c.execute(
        'INSERT INTO orders (user_id, total) VALUES (@uid, @total)',
        {'uid': 1, 'total': 99.99},
      );
    });
  } finally {
    await pool.close();
  }
}
