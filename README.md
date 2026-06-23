# mssql

A pure-Dart driver for Microsoft SQL Server, built on the **TDS 7.4** wire protocol.
No native extensions, no FFI — just Dart and TCP.

```
dart pub add mssql
```

## Quick start

```dart
import 'package:mssql/mssql.dart';

final conn = await MssqlConnection.connect(
  host: 'localhost',
  port: 1433,
  user: 'sa',
  password: 'P@ssw0rd',
  database: 'MyDb',
);

final result = await conn.query('SELECT id, name FROM users WHERE id = @id', {'id': 1});
print(result[0]['name']); // Alice

await conn.close();
```

---

## API reference

### MssqlConnection

#### Connecting

```dart
// SQL Server authentication (username + password)
final conn = await MssqlConnection.connect(
  host: 'localhost',      // required
  port: 1433,             // optional, default 1433
  user: 'sa',             // required
  password: 'P@ssw0rd',  // required
  database: 'MyDb',       // optional, default ''
  encrypt: true,          // optional, default true; set false for local dev containers
  trustServerCertificate: false, // optional, accept self-signed certs
  timeout: Duration(seconds: 30), // optional, connection timeout
);

// Azure AD authentication
final conn = await MssqlConnection.connectAzureAd(
  host: 'server.database.windows.net',
  azureAdAuth: AzureAdAuth.fromToken(token),   // pre-acquired bearer token
  database: 'MyDb',
  trustServerCertificate: false,
);
```

#### Querying

```dart
// Returns all rows buffered in a MssqlResult
final result = await conn.query('SELECT id, name FROM users');

// With named parameters (@name syntax)
final result = await conn.query(
  'SELECT * FROM orders WHERE customer = @cust AND active = @flag',
  {'cust': 'Acme', 'flag': true},
);

// Access by column name or zero-based index
final name   = result[0]['name'];       // by name
final first  = result[0].valueAt(0);    // by index
final cols   = result[0].columnNames;   // ['id', 'name']
final values = result[0].values;        // [1, 'Alice']

// Rows and counts
result.rows;         // List<MssqlRow>
result.rowsAffected; // int
result.length;       // row count
result.isEmpty;      // bool
```

#### Executing (DML / DDL)

```dart
// Returns rows affected
final n = await conn.execute(
  'INSERT INTO logs (msg) VALUES (@msg)',
  {'msg': 'hello'},
);
print(n); // 1
```

#### Multiple result sets

```dart
final multi = await conn.queryMultiple('SELECT 1 AS a; SELECT 2 AS b');
final first  = multi.first;   // MssqlResult for first SELECT
final second = multi.second;  // MssqlResult for second SELECT
final all    = multi.all;     // List<MssqlResult>
```

#### Streaming large result sets

```dart
await for (final row in conn.queryStream('SELECT * FROM bigTable')) {
  process(row);
}

// With parameters
await for (final row in conn.queryStream(
  'SELECT * FROM events WHERE date > @since',
  {'since': DateTime.now().subtract(Duration(days: 7))},
)) {
  print(row['event_type']);
}
```

#### Transactions

```dart
// Callback form — commits on success, rolls back on any exception
await conn.transaction((c) async {
  await c.execute('INSERT INTO accounts (id, balance) VALUES (1, 100)');
  await c.execute('INSERT INTO accounts (id, balance) VALUES (2, 200)');
});

// Manual form
await conn.beginTransaction();
try {
  await conn.execute('UPDATE accounts SET balance = balance - 50 WHERE id = 1');
  await conn.execute('UPDATE accounts SET balance = balance + 50 WHERE id = 2');
  await conn.commitTransaction();
} catch (_) {
  await conn.rollbackTransaction();
  rethrow;
}
```

#### Connection state

```dart
conn.isOpen;    // bool — false after close() or a fatal error
conn.database;  // String — current database name

await conn.close();
```

---

### MssqlPool

A connection pool with configurable min/max, idle reaping, and acquire timeouts.
Mirrors the node-mssql / tarn pool model.

#### Creating a pool

```dart
final pool = MssqlPool(MssqlPoolConfig(
  host: 'localhost',
  port: 1433,
  user: 'sa',
  password: 'P@ssw0rd',
  database: 'MyDb',
  encrypt: true,
  trustServerCertificate: false,

  min: 2,                              // minimum idle connections (default 0)
  max: 10,                             // maximum total connections (default 10)
  idleTimeout: Duration(seconds: 30),  // close idle connections after (default 30s)
  acquireTimeout: Duration(seconds: 15), // throw if no connection within (default 15s)
  connectionTimeout: Duration(seconds: 30), // TCP connect timeout (default 30s)
));

// Pre-warm min connections (optional)
await pool.open();
```

#### Pool query methods

```dart
// Same signatures as MssqlConnection
final result = await pool.query('SELECT * FROM users WHERE id = @id', {'id': 1});
final n      = await pool.execute('DELETE FROM tmp WHERE expired = 1');
final multi  = await pool.queryMultiple('SELECT 1; SELECT 2');

await for (final row in pool.queryStream('SELECT * FROM bigTable')) {
  process(row);
}
```

#### Pool transactions

```dart
await pool.transaction((conn) async {
  await conn.execute('INSERT INTO orders ...');
  await conn.execute('UPDATE inventory ...');
  // commits on return, rolls back on throw
});
```

#### Manual acquire / release

```dart
final conn = await pool.acquire();
try {
  await conn.execute('...');
} finally {
  pool.release(conn);
}
```

#### Closing the pool

```dart
await pool.close(); // closes idle connections, rejects any pending acquires
```

---

### MssqlException

All driver and server errors throw `MssqlException`:

```dart
try {
  await conn.query('SELECT * FROM nonexistent');
} on MssqlException catch (e) {
  print(e.message);           // SQL Server error message
  print(e.errorCode);         // SQL Server error number (e.g. 208 = invalid object name)
  print(e.severity);          // TDS severity level (nullable int)
  print(e.precedingErrors);   // List<MssqlException> — earlier errors from the same batch
}
```

---

### Parameters

Named parameters use `@name` placeholders. Supported Dart → SQL type mappings:

| Dart type    | SQL Server type             |
|--------------|-----------------------------|
| `int`        | BIGINT                      |
| `double`     | FLOAT                       |
| `bool`       | BIT                         |
| `String`     | NVARCHAR(MAX) or NVARCHAR   |
| `List<int>`  | VARBINARY(MAX)              |
| `DateTime`   | DATETIME2(7)                |
| `null`       | NULL (any type)             |

---

### Supported SQL Server types (read)

| Category     | Types                                                                        |
|--------------|------------------------------------------------------------------------------|
| Integer      | TINYINT, SMALLINT, INT, BIGINT, BIT                                          |
| Float        | REAL (→ `double`), FLOAT (→ `double`)                                        |
| Decimal      | DECIMAL, NUMERIC (→ `double`)                                                |
| Money        | MONEY, SMALLMONEY (→ `double`)                                               |
| String       | VARCHAR, NVARCHAR, CHAR, NCHAR, TEXT, NTEXT, VARCHAR(MAX), NVARCHAR(MAX)     |
| Binary       | VARBINARY, BINARY, IMAGE, VARBINARY(MAX) (→ `List<int>`)                    |
| Date/Time    | DATE, DATETIME, DATETIME2, SMALLDATETIME, TIME, DATETIMEOFFSET (→ `DateTime`) |
| GUID         | UNIQUEIDENTIFIER (→ `String` in `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` form) |
| XML          | XML (→ `String`)                                                             |
| Misc         | SQL_VARIANT (→ decoded inner value), UDT (→ raw `List<int>`)                |
| Null         | NULL for any type (→ `null`)                                                 |

---

## TLS / Encryption

```dart
// Production (Azure SQL, SQL Server with TLS)
final conn = await MssqlConnection.connect(
  host: 'server.database.windows.net',
  encrypt: true,                  // default true
  trustServerCertificate: false,  // validate cert (default false)
  ...
);

// Local dev container (no TLS)
final conn = await MssqlConnection.connect(
  host: 'localhost',
  encrypt: false,
  ...
);

// Local dev container with self-signed cert
final conn = await MssqlConnection.connect(
  host: 'localhost',
  encrypt: true,
  trustServerCertificate: true,
  ...
);
```

---

## Requirements

- Dart SDK ≥ 3.0
- SQL Server 2008 R2 or later (TDS 7.4 / protocol 0x04000074)
- Azure SQL Database / Azure SQL Edge
- Port 1433 (or custom) reachable from the Dart process

---

## Limitations

- Azure AD authentication requires a bearer token supplied by the caller (e.g. obtained via `azure_identity`); the driver does not fetch tokens itself.
- Bulk copy (`BULK INSERT` / TDS bulk-load protocol) is not supported.
- Prepared statement handles (`sp_prepare` / `sp_execute`) are not supported. All parameterized queries use `sp_executesql`, which SQL Server plan-caches by query hash, so repeated-query performance is similar in practice.
