# mssql

A Dart-first driver for Microsoft SQL Server, built on the TDS 7.4 wire
protocol, with the long-term goal of becoming a fully pure-Dart implementation.
TDS encoding, decoding, connection pooling, authentication, and query handling
are implemented in Dart. Encrypted connections currently use a native OpenSSL
TLS helper.

The native helper is currently required for TLS (support Windows, Linux, and
Android). This is the compatibility trade-off for reliable encrypted multi-packet requests, Bulk
Load, and Attention cancellation. Version `0.4.1` used only Dart `SecureSocket`,
but had to reject those encrypted workflows because of its plaintext-ring
limitation. Unencrypted connections continue to use only Dart and TCP.

The native TLS helper can be removed once Dart exposes a supported
`SecureSocket` write API that guarantees caller-controlled TLS plaintext record
boundaries, or fixes the current implementation so fragmented TDS messages are
reliably preserved across its internal plaintext buffer. That is the Dart SDK
feature this package needs; until then, the C++ helper is the contained
workaround for encrypted connections.

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

## LAN / on-prem cookbook

Defaults favor local SQL Server / Docker Edge as well as production. Common LAN patterns:

### Connection strings

```dart
final conn = await MssqlConnection.connectFromString(
  'Server=10.0.0.5,1433;Database=app;User Id=sa;Password=…;'
  'Encrypt=false;TrustServerCertificate=true;App Name=my-pos;',
);
// Named instance (SQL Browser UDP 1434 when port omitted):
// Server=sql01\SQLEXPRESS;User Id=sa;Password=…;Encrypt=false;
// URL form: sqlserver://sa:…@10.0.0.5:1433?database=app&encrypt=false
```

`User Id=DOMAIN\user` opens NTLM. Pool: `MssqlPoolConfig.fromConnectionString(…, max: 10)`.

### Timeouts & identity

```dart
final conn = await MssqlConnection.connect(
  host: '10.0.0.5',
  user: 'sa',
  password: '…',
  database: 'app',
  encrypt: false, // or true + trustServerCertificate for LAN TLS
  appName: 'my-pos',          // sys.dm_exec_sessions.program_name
  timeout: Duration(seconds: 10),       // full login handshake
  queryTimeout: Duration(seconds: 30),  // Attention + drain on expiry
);
await conn.query('SELECT 1', const {}, Duration(seconds: 2)); // per-call
```

### Protocol limits

Protocol size limits are enabled by default to avoid allocating unexpectedly
large server-controlled values. Tune them for workloads that intentionally read
large LOB values, use `MssqlProtocolLimits.sqlServerMaximums` for documented SQL
Server ceilings, or `MssqlProtocolLimits.unlimited` for the old compatibility
behaviour.

```dart
final conn = await MssqlConnection.connect(
  host: '10.0.0.5',
  user: 'sa',
  password: '…',
  encrypt: false,
  // Limits below are equivalent to the default: const MssqlProtocolLimits().
  protocolLimits: const MssqlProtocolLimits(
    maximumTokenBytes: 16 * 1024 * 1024,
    maximumValueBytes: 64 * 1024 * 1024,
    maximumPlpChunkBytes: 4 * 1024 * 1024,
    maximumColumns: 4096,
    maximumResultSets: 256,
  ),
);
```

### Pool health & session reset

```dart
final pool = MssqlPool(MssqlPoolConfig(
  host: '10.0.0.5',
  user: 'sa',
  password: '…',
  database: 'app',
  encrypt: false,
  validateOnAcquire: true, // default — SELECT 1; discard dead sockets
  resetOnRelease: true,    // default — TDS RESETCONNECTION (clears #temp / USE)
));
final conn = await pool.acquire();
try {
  await conn.execute('…');
} finally {
  await pool.release(conn); // async — always await
}
```

`resetOnRelease` clears session temp tables and restores the login database. Disable only if you intentionally share `#temp` across borrowers.

### Named instances

```dart
await MssqlConnection.connect(
  host: r'sql01\SQLEXPRESS', // or host: 'sql01', instanceName: 'SQLEXPRESS'
  user: 'sa',
  password: '…',
  encrypt: false,
);
// Explicit port skips Browser: r'sql01\SQLEXPRESS,15001'
```

### Bulk insert & TVP

```dart
await conn.bulkInsert('dbo.Items', ['Id', 'Name'], [
  [1, 'a'],
  [2, 'b'],
]);

// Requires: CREATE TYPE dbo.IdList AS TABLE (Id BIGINT);
await conn.query('SELECT Id FROM @ids', {
  'ids': MssqlTvp(
    typeName: 'dbo.IdList',
    columns: [BulkColumn('Id', BulkColumnType.bigInt)],
    rows: [[1], [2], [3]],
  ),
});
```

### NTLM (domain SQL)

```dart
await MssqlConnection.connectNtlm(
  host: 'sql01',
  domain: 'CONTOSO',
  user: 'bob',
  password: '…',
  encrypt: true,
  trustServerCertificate: true,
);
```

### Stored procedures (OUTPUT / RETURN)

```dart
final r = await conn.call('dbo.MyProc', {
  'inVal': 5,
  'outVal': MssqlOutput(0), // or MssqlOutput(null, 'nvarchar(100)')
});
print(r.returnStatus);   // RETURN integer, if any
print(r.output['outVal']);
print(r.resultSets);     // SELECT sets inside the proc
```

### Diagnostics & transient retry

```dart
conn.onInfoMessage = (info) {
  print('INFO ${info.number}: ${info.message}'); // PRINT / RAISERROR < 11
};

// Pool: connectRetries default 2; optional INFO fan-out
final pool = MssqlPool(MssqlPoolConfig(
  host: '10.0.0.5',
  user: 'sa',
  password: '…',
  encrypt: false,
  connectRetries: 2,
  onInfoMessage: (info) => print(info.message),
));

// App-level retry for deadlocks / brief disconnects
await MssqlTransient.retry(
  () => conn.query('UPDATE …'),
  retries: 2,
);
```

### Isolation & savepoints

```dart
await conn.transaction((c) async {
  await c.execute('INSERT …');
  await c.savepoint('sp1');
  await c.execute('UPDATE …');
  await c.rollbackTo('sp1'); // outer txn still open
}, isolation: MssqlIsolationLevel.repeatableRead);
```

### Parameters and SQL Server-specific types

Use ordinary Dart values first. The driver infers the usual SQL Server types:

```dart
await conn.query('SELECT @id, @price, @enabled, @name, @created, @data, @none', {
  'id': 42,                         // bigint
  'price': 19.99,                   // float
  'enabled': true,                  // bit
  'name': 'Ada',                    // nvarchar
  'created': DateTime.now().toUtc(), // datetime2
  'data': [0xDE, 0xAD],             // varbinary(max)
  'none': null,
});
```

Use an `Mssql*` helper when the SQL Server type cannot be represented by a
bare Dart value, or when its exact width, encoding, precision, or legacy type
matters:

```dart
await conn.query('SELECT @g, @m, @d, @dec, @v, @day, @tod, @dt, @sd, @x, @b, @n, @c, @bin, @rv', {
  'g': MssqlGuid('6F9619FF-8B86-D011-B42D-00C04FC964FF'),
  'm': MssqlMoney(1234.56),
  'd': MssqlDateTimeOffset(
    DateTime.utc(2024, 1, 1, 4, 30),
    offset: Duration(hours: 5, minutes: 30),
  ),
  'dec': MssqlDecimal(19.99, precision: 10, scale: 2),
  'v': MssqlVarchar('bob'),
  'day': MssqlDate(2024, 7, 24),
  'tod': MssqlTime(hour: 14, minute: 30, second: 0),
  'dt': MssqlDateTime(DateTime.utc(2024, 3, 15, 10, 30)),
  'sd': MssqlSmallDateTime(DateTime.utc(2024, 3, 15, 10, 30)),
  'x': MssqlXml('<root/>'),
  'b': MssqlVarbinary([0xDE, 0xAD], length: 16),
  'n': MssqlNVarchar('lan', length: 32),
  'c': MssqlNChar('ab', length: 4),
  'bin': MssqlBinary([1, 2], length: 4),
  'rv': MssqlRowVersion.parse('0x00000000000000FF'),
});
```

### Always On / HA

Connection establishment supports Always On read-only routing, parallel dialing
of multi-subnet listeners, and an initial database-mirroring failover partner.
This is not transparent failover for an already-running command: an in-flight
connection lost during a role change must be retried by the application.

```dart
// Read-only routing via AG listener (database required)
final ro = await MssqlConnection.connect(
  host: 'ag-listener',
  database: 'app',
  user: 'sa',
  password: '…',
  readOnlyIntent: true,       // ApplicationIntent=ReadOnly
  multiSubnetFailover: true,  // parallel-dial multi-subnet listener
);

// Mirroring partner if primary is down at connect time
final conn = await MssqlConnection.connectFromString(
  'Server=sql1;Failover Partner=sql2;Database=app;'
  'User Id=sa;Password=…;Encrypt=true;TrustServerCertificate=true;',
);
```

### KeepAlive + session init

```dart
final conn = await MssqlConnection.connect(
  host: '10.0.0.5',
  user: 'sa',
  password: '…',
  encrypt: false,
  keepAlive: Duration(seconds: 30), // TCP keepalive (0 = off)
  sessionInitSql: 'SET XACT_ABORT ON; SET LOCK_TIMEOUT 5000;',
);

// Same knobs on the pool; SessionInitSQL re-runs after resetOnRelease
final pool = MssqlPool(MssqlPoolConfig(
  host: '10.0.0.5',
  user: 'sa',
  password: '…',
  encrypt: false,
  keepAlive: Duration(seconds: 30),
  sessionInitSql: 'SET XACT_ABORT ON;',
));
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
  timeout: Duration(seconds: 15), // optional, full login handshake (default 15s)
  queryTimeout: Duration(seconds: 30), // optional, default query deadline
  appName: 'mssql-dart',  // optional, program_name in DMVs
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
}, isolation: MssqlIsolationLevel.serializable);

// Manual form + savepoints (SQL Server SAVE / ROLLBACK TRANSACTION)
await conn.beginTransaction(isolation: MssqlIsolationLevel.readCommitted);
try {
  await conn.execute('UPDATE accounts SET balance = balance - 50 WHERE id = 1');
  await conn.savepoint('after_debit');
  await conn.execute('UPDATE accounts SET balance = balance + 50 WHERE id = 2');
  // undo only the credit:
  await conn.rollbackTo('after_debit');
  await conn.commitTransaction();
} catch (_) {
  await conn.rollbackTransaction();
  rethrow;
}
```

#### Connection state

```dart
conn.isOpen;           // bool — false after close() or a fatal error
conn.database;         // String — current database (tracks USE / ENVCHANGE)
conn.initialDatabase;  // String — database from login
conn.appName;          // String — login program_name

await conn.resetSession();   // TDS RESETCONNECTION + SELECT 1
await conn.resetDatabase();  // USE back to initialDatabase
await conn.cancel();         // Attention cancel in-flight query
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
  connectionTimeout: Duration(seconds: 15), // full login handshake (default 15s)
  validateOnAcquire: true,               // probe idle sockets (default true)
  resetOnRelease: true,                  // TDS RESETCONNECTION (default true)
));

// Pre-warm min connections (optional)
await pool.open();
```

#### Pool observability

```dart
print(pool.stats);
// MssqlPoolStats(total=2 idle=1 inUse=1 pending=0 max=10 created=… …)

print('${pool.size} ${pool.available} ${pool.borrowed} ${pool.pending}');

pool.onEvent = (e) {
  // created / destroyed / acquired / released / acquireTimeout /
  // validationFailed / resetFailed
  log.info('${e.kind} ${e.stats}');
};
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
  await pool.release(conn);
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
| `MssqlGuid`  | uniqueidentifier            |
| `MssqlMoney` / `MssqlSmallMoney` | money / smallmoney |
| `MssqlDateTimeOffset` | datetimeoffset       |
| `MssqlDecimal` | decimal(p,s) / numeric(p,s) |
| `MssqlVarchar` | varchar (Latin-1; bare `String` → nvarchar) |
| `MssqlDate`    | date |
| `MssqlTime`    | time(s) |
| `MssqlDateTime` / `MssqlSmallDateTime` | datetime / smalldatetime |
| `MssqlXml`     | xml (bare `String` → nvarchar) |
| `MssqlVarbinary` | varbinary(n) / varbinary(max) (bare `List<int>` → max) |
| `MssqlNVarchar` / `MssqlNChar` | nvarchar(n\|max) / nchar(n) |
| `MssqlBinary` / `MssqlRowVersion` | binary(n) / rowversion compare (`binary(8)`) |
| `MssqlTvp`   | user-defined table type (`… READONLY`) |
| `MssqlOutput`| OUTPUT / INPUT-OUTPUT (with [call]) |
| `null`       | NULL (any type)             |

---

### Supported SQL Server types (read)

| Category     | Types                                                                        |
|--------------|------------------------------------------------------------------------------|
| Integer      | TINYINT, SMALLINT, INT, BIGINT, BIT                                          |
| Float        | REAL (→ `double`), FLOAT (→ `double`)                                        |
| Decimal      | DECIMAL, NUMERIC (→ `MssqlDecimal`)                                          |
| Money        | MONEY (→ `MssqlMoney`), SMALLMONEY (→ `MssqlSmallMoney`)                     |
| String       | VARCHAR, NVARCHAR, CHAR, NCHAR, TEXT, NTEXT, VARCHAR(MAX), NVARCHAR(MAX)     |
| Binary       | VARBINARY, BINARY, IMAGE, VARBINARY(MAX) (→ `List<int>`)                    |
| Date/Time    | DATE, DATETIME, DATETIME2, SMALLDATETIME, TIME, DATETIMEOFFSET (→ `DateTime`) |
| GUID         | UNIQUEIDENTIFIER (→ `String` in `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` form) |
| XML          | XML (→ `String`)                                                             |
| Misc         | SQL_VARIANT (→ decoded inner value), UDT (→ raw `List<int>`)                |
| Null         | NULL for any type (→ `null`)                                                 |

---

## TLS / Encryption

TDS 7.x wraps the TLS handshake in PRELOGIN packets, then switches to raw TLS
for the rest of the session. On Windows, Linux, and Android, encrypted connections use
the bundled native OpenSSL transport. It serializes TLS reads and writes so
multi-packet requests, Bulk Load, and Attention cancellation remain reliable.
Cleartext connections continue to use Dart and TCP only.

```dart
// Production (Azure SQL, SQL Server with TLS)
final conn = await MssqlConnection.connect(
  host: 'server.database.windows.net',
  encrypt: true,                  // default true
  trustServerCertificate: false,  // validate cert (default false)
  // Optional: custom PEM trust roots
  // trustedCertificateFile: 'ca.pem',
  // trustedCertificateDirectory: 'certs',
  // After Always On redirect to an IP, keep validating against the AG name:
  // hostNameInCertificate: 'ag-listener.contoso.local',
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

If the server requires encryption (`forceencryption=1`) but the client passes
`encrypt: false`, connect fails immediately with a clear
`MssqlException` (`Server requires encryption…`) — it does not advertise
“not supported” and then upgrade (that path caused SQL Error 17828).

Connection-string keys: `Encrypt`, `TrustServerCertificate`,
`TrustedCertificateFile` (`CAFile`), `TrustedCertificateDirectory` (`CAPath`),
and `HostNameInCertificate` (also on `sqlserver://` URLs). The same options
exist on `MssqlPoolConfig` / `MssqlPoolConfig.fromConnectionString`.

---

## Requirements

- Dart SDK >= 3.10
- SQL Server 2008 R2 or later (TDS 7.4 / protocol 0x04000074)
- Azure SQL Database / Azure SQL Edge
- Port 1433 (or custom) reachable from the Dart process

---

## Testing

See [README_TESTS.md](README_TESTS.md) for offline, native TLS, Docker matrix,
and opt-in live SQL Server testing instructions.

## Limitations

- Tested with SQL Server 2017, 2019, 2022, and 2025. Earlier versions from SQL
  Server 2012 onward should be protocol-compatible through TDS 7.4 but are not
  currently tested.
- TLS on Windows, Linux, and Android requires the native OpenSSL helper. A pure-Dart TLS
  fallback is not provided in 0.5.0; use 0.4.1 only when its encrypted
  multi-packet and Bulk Load limitations are acceptable.
- Azure AD authentication requires a bearer token supplied by the caller (e.g. obtained via `azure_identity`); the driver does not fetch tokens itself.
- Prepared statement handles (`sp_prepare` / `sp_execute`) are not supported. All parameterized queries use `sp_executesql`, which SQL Server plan-caches by query hash, so repeated-query performance is similar in practice.
