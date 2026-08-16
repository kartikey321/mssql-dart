# Bug: connection dies with "Connection closed mid-header" after repeated explicit transactions

## Summary

After roughly 6–13 explicit `BEGIN TRANSACTION` / `COMMIT`|`ROLLBACK TRANSACTION` cycles
on the *same* `MssqlConnection`, the next query on that connection throws:

```
Bad state: Connection closed mid-header
#0 TdsBuffer._readNextPacket (package:mssql/src/tds/buf.dart:137:7)
#1 TdsBuffer.beginRead (package:mssql/src/tds/buf.dart:154:5)
#2 TokenStream.processAllQueryResponses (package:mssql/src/tds/token_stream.dart:135:5)
#3 TokenStream.processQueryResponse (package:mssql/src/tds/token_stream.dart:109:18)
#4 MssqlConnection.query (package:mssql/src/connection.dart:145:24)
#5 MssqlConnection.execute (package:mssql/src/connection.dart:219:20)
```

`_readNextPacket` gets fewer than 8 bytes when trying to read the next TDS packet
header — i.e. the socket appears to have been closed (no more bytes available) at
exactly the point a fresh statement is sent, after a prior sequence of transaction
statements succeeded cleanly.

This was found while migrating `knex_dart`'s MSSQL driver from `mssql_connection`
(FFI) to this package, running its integration suite. It reproduces with **no
knex_dart code involved** — see minimal repro below, written directly against
`package:mssql`.

## Environment

- `mssql` — local working copy at the time of testing (post `appName`/`applicationName`
  passthrough patch; the bug is unrelated to that change and reproduces with or
  without it).
- Server: **Azure SQL Edge** (`mcr.microsoft.com/mssql/server:2022-latest` does **not**
  boot under Docker emulation on this machine — arm64 Mac, image is amd64-only —
  so only Edge could be tested locally).
- Connection: `encrypt: true`, `trustServerCertificate: true`.
- Dart: run via `dart run`, no isolate pooling, single connection, sequential
  awaits (no concurrent queries on the connection).

**Important caveat: this has only been reproduced against Azure SQL Edge.** I do
not yet know whether it also occurs against real SQL Server 2022 (what CI actually
targets) — that could not be tested locally because the amd64 SQL Server image
won't start under this machine's emulation. It's possible this is an Edge-specific
quirk (e.g. a session/worker limit particular to Edge) rather than a client-side
protocol bug — but the symptom (client-side packet framing exception, not a clean
server error) is at least consistent with a client-side desync too.

## Minimal repro (no transactions at all — control case, passes)

```dart
import 'package:mssql/mssql.dart';

void main() async {
  final c = await MssqlConnection.connect(
    host: 'localhost', port: 1433, user: 'sa', password: 'Knex_Test1!',
    database: 'knex_test', encrypt: true, trustServerCertificate: true,
  );
  for (var i = 1; i <= 40; i++) {
    final r = await c.query('SELECT $i AS x');
    print('iter $i: rows=${r.rows.length} val=${r.rows.first["x"]}');
  }
  await c.close();
}
```

**Result: all 40 iterations succeed.** No transaction statements involved — plain
query round-trips do not trigger the bug, regardless of count. (Note: `c.close()`
itself appeared to hang in this run — see "Secondary observation" below.)

## Minimal repro (plain BEGIN/COMMIT, no savepoints — dies at iteration 13)

```dart
import 'package:mssql/mssql.dart';

void main() async {
  final c = await MssqlConnection.connect(
    host: 'localhost', port: 1433, user: 'sa', password: 'Knex_Test1!',
    database: 'knex_test', encrypt: true, trustServerCertificate: true,
  );

  await c.execute("IF OBJECT_ID('probe_t2') IS NOT NULL DROP TABLE probe_t2");
  await c.execute("CREATE TABLE probe_t2 (id INT PRIMARY KEY, name NVARCHAR(50))");

  for (var i = 1; i <= 15; i++) {
    print('iter $i: begin');
    await c.execute('BEGIN TRANSACTION');
    await c.execute("INSERT INTO probe_t2 VALUES ($i, 'a')");
    await c.execute('COMMIT TRANSACTION');
    final r = await c.query('SELECT 1 AS x');
    print('iter $i: canary rows=${r.rows.length}');
  }

  await c.close();
}
```

**Result:** iterations 1–12 succeed cleanly (each producing a `BEGIN`/`COMMIT`
ENVCHANGE pair, verified via instrumentation — see below). Iteration 13's
`BEGIN TRANSACTION` succeeds (ENVCHANGE type 8 observed), but the *next*
statement (`INSERT`) throws `Connection closed mid-header` immediately —
i.e. the connection was already gone by the time that statement was sent/read.

## Minimal repro (BEGIN + SAVE TRANSACTION + two ROLLBACKs — dies earlier, at iteration 7)

```dart
import 'package:mssql/mssql.dart';

void main() async {
  final c = await MssqlConnection.connect(
    host: 'localhost', port: 1433, user: 'sa', password: 'Knex_Test1!',
    database: 'knex_test', encrypt: true, trustServerCertificate: true,
  );

  await c.execute("IF OBJECT_ID('probe_t') IS NOT NULL DROP TABLE probe_t");
  await c.execute("CREATE TABLE probe_t (id INT PRIMARY KEY, name NVARCHAR(50))");

  for (var i = 1; i <= 8; i++) {
    print('iter $i: begin');
    await c.execute('BEGIN TRANSACTION');
    await c.execute("INSERT INTO probe_t VALUES ($i, 'a')");
    await c.execute('SAVE TRANSACTION sp$i');
    await c.execute("INSERT INTO probe_t VALUES (${i}00, 'b')");
    await c.execute('ROLLBACK TRANSACTION sp$i');   // rollback to savepoint only
    await c.execute('ROLLBACK TRANSACTION');        // full rollback, ends the tran
    final r = await c.query('SELECT 1 AS x');
    print('iter $i: canary rows=${r.rows.length}');
  }

  await c.close();
}
```

**Result:** dies at iteration 7 (fails one statement earlier per-iteration than
the no-savepoint case, but with ~2x the transaction-boundary statements per
iteration — so on a *total transaction-boundary-statement* basis the failure
point is roughly the same order of magnitude in both repros, ~18–24 BEGIN/
COMMIT/ROLLBACK statements before death).

**Conclusion: the failure is not specific to savepoints.** Plain `BEGIN`/`COMMIT`
with zero savepoints reproduces it just as well (just at a slightly higher
iteration count). The common factor across both failing repros — and the
distinguishing factor vs. the passing no-transaction repro — is **explicit
transaction statements** (`BEGIN TRANSACTION` / `COMMIT TRANSACTION` /
`ROLLBACK TRANSACTION`, sent as literal SQL text via `execute()`), not
statement volume in general.

## Diagnostic: ENVCHANGE contents look structurally correct

I temporarily instrumented `TokenStream._readEnvChange` to print the raw
ENVCHANGE bytes. Example from the no-savepoint repro:

```
DEBUG ENVCHANGE type=8  len=11 raw=[8, 8, 3, 0, 0, 0, 51, 0, 0, 0, 0]   # BEGIN, iter 1
DEBUG ENVCHANGE type=10 len=11 raw=[10, 0, 8, 3, 0, 0, 0, 51, 0, 0, 0]  # ROLLBACK/COMMIT, iter 1
DEBUG ENVCHANGE type=8  len=11 raw=[8, 8, 4, 0, 0, 0, 51, 0, 0, 0, 0]   # BEGIN, iter 2
...
DEBUG ENVCHANGE type=8  len=11 raw=[8, 8, 9, 0, 0, 0, 51, 0, 0, 0, 0]   # BEGIN, iter 7 (probe1) — last thing seen before death
```

The transaction descriptor's low 32 bits increment by 1 each `BEGIN`
(3, 4, 5, 6, 7, 8, 9, …) and the high 32 bits stay constant (51 — presumably a
session/connection identifier component). This looks like well-formed,
sane data — nothing here screams "obviously corrupted," which is why I didn't
chase a specific off-by-one in `_readEnvChange`/`_writeAllHeaders` further
without more evidence. (`_writeAllHeaders` in `rpc.dart` echoes
`buf.transactionDescriptor` back via `ALL_HEADERS` on every request, which
matches spec.)

I did **not** get a raw packet capture (no passwordless `sudo` for `tcpdump` in
this environment), so I can't confirm whether the client stops receiving bytes
because the server actually closed the socket (e.g. a real server-side
resource limit) or because the client desynced mid-stream and misread a
packet boundary earlier, only manifesting as a hard failure later.

## Secondary observation (separate, unconfirmed anomaly)

In the no-transaction control repro (40 plain `SELECT`s), all 40 iterations
printed successfully, but the script then hung past a 60s timeout instead of
reaching `c.close()`'s print — suggesting `close()` (or something after the
last query, before returning) can hang under some conditions. Not investigated
further; noted in case it's related (e.g. a stuck read waiting for bytes that
never come, similar root cause to the mid-header failure but manifesting as a
hang instead of an exception because there's no pending header read to fail).

## What would help narrow this down further

1. **Test against real SQL Server 2022** (what CI/production actually target) —
   I could not do this locally (emulation failure on arm64). If the bug doesn't
   reproduce there, this is an Azure SQL Edge–specific constraint, not a
   `mssql` package bug per se (though arguably still worth handling gracefully
   rather than throwing a raw `StateError` with a confusing message).
2. **A raw packet capture** (`tcpdump`/Wireshark on loopback, or SQL Server's own
   extended events) around the death point, to see definitively whether the
   FIN/RST comes from the server or whether the client already stopped reading
   the stream correctly beforehand.
3. Check whether Azure SQL Edge has a lower `max worker threads` /
   `user connections` /  memory grant limit than full SQL Server that could be
   getting exhausted by repeated transaction begin/end cycles within one
   session (would explain why plain SELECTs don't trigger it but transaction
   statements do, and why the failure point is a roughly-consistent
   "N transaction-boundary statements" rather than "N statements" in general).
4. Re-run the two failing repros above with `queryMultiple`/raw packet logging
   temporarily added at the `TdsBuffer` level (packet type + size + first few
   header bytes per read) to see exactly what's on the wire in the packets
   immediately preceding the failed header read — in particular, whether the
   *previous* statement's response was fully drained (ended on a `DONE` token
   with `doneFlagMore == 0`) before the next request was sent.

## Why this matters for `knex_dart`

`knex_dart`'s MSSQL driver wraps every `trx()` call in
`BEGIN TRANSACTION` / `COMMIT TRANSACTION` / `ROLLBACK TRANSACTION`, and nested
transactions use `SAVE TRANSACTION` savepoints — exactly the pattern that
triggers this. A long-lived connection used for many transactions (the normal
case for a query builder / ORM) will eventually hit this and become unusable,
requiring the caller to detect the dead connection and reconnect. This is a
blocker for adopting `mssql` as `knex_dart`'s MSSQL driver until resolved (or
at least until it's confirmed to be Edge-specific and not a real-SQL-Server
issue).
