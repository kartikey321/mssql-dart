# TLS bridge diagnostic build

This branch (`tls-debug`) adds temporary instrumentation to
`lib/src/connection.dart`'s TLS bridge, on top of whatever mitigations were
already in the working tree (mark-connection-dead-on-error, destroy-based
`close()`, etc.). It is diagnostic-only — do not merge to `main`.

## What it adds

- `MSSQL_TLS_DEBUG=true` — turns on debug logging in the TLS bridge.
- `MSSQL_TLS_DEBUG_LOG=/path/to/file` — required alongside it. Every debug
  line is written with a synchronous flushed file append
  (`writeAsStringSync(..., flush: true)`), so nothing is lost even if the
  process is killed (Dart buffers stdout/stderr when not a TTY, which can
  otherwise make output vanish silently on `kill -9`).
- Logs: keylog line (first line's label tells you the negotiated TLS
  version — `CLIENT_RANDOM` = TLS 1.2, `SERVER_HANDSHAKE_TRAFFIC_SECRET` /
  `EXPORTER_SECRET` = TLS 1.3), every raw TLS record's direction/contentType/
  length in both directions, and the bridge read loop's exit reason
  (clean EOF / truncated record / exception) when it terminates.
- A real bug fix: `writeRaw`'s future chain now self-heals and marks the
  connection dead on a write error, instead of silently dropping all
  subsequent writes after the first failure (previously
  `unawaited(rawWrite.catchError(...))` operated on a detached copy of the
  future, so the "real" `rawWrite` chain stayed permanently rejected after
  any one write failed).
- `tmp_repros/dart_transaction_repro.dart` — same repro as before, plus:
  writes an `=== iter N: begin ===` marker into `MSSQL_TLS_DEBUG_LOG` at the
  top of each loop iteration (so you can correlate which iteration the
  connection died on with the byte-level trace), and calls `exit(0)` in its
  `finally` block after `close()` (works around a separate, already-known
  hang in `close()`/shutdown so the process actually terminates and flushes).

## Running it — two options

Either works; option B removes Docker entirely (no container networking
layer at all, not just no CPU emulation), so prefer it if you want the
cleanest possible signal. Both give a genuine, unemulated SQL Server — the
thing the Mac session couldn't get.

### Option A: Docker on native amd64 (Linux/Windows, no `--platform` needed)

```bash
git clone https://github.com/kartikey321/mssql-dart.git
cd mssql-dart
git checkout tls-debug
dart pub get

# Real SQL Server, no --platform flag needed on native amd64:
docker run -d --name mssql_tls_repro \
  -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=Knex_Test1!' -e 'MSSQL_PID=Developer' \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# wait for health, then create the test DB:
docker exec mssql_tls_repro /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'Knex_Test1!' -C -No \
  -Q "IF DB_ID('knex_test') IS NULL CREATE DATABASE knex_test"
```

### Option B: Native install, no Docker at all

**Ubuntu/Debian Linux:**
```bash
# https://learn.microsoft.com/en-us/sql/linux/quickstart-install-connect-ubuntu
curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
curl -o /etc/apt/sources.list.d/mssql-server-2022.list https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list
sudo apt-get update
sudo apt-get install -y mssql-server
sudo MSSQL_SA_PASSWORD='Knex_Test1!' MSSQL_PID=Developer /opt/mssql/bin/mssql-conf -n setup accept-eula
systemctl status mssql-server   # confirm it's running

# sqlcmd tools + create the test DB:
sudo apt-get install -y mssql-tools18 unixodbc-dev
sudo /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'Knex_Test1!' -C -No \
  -Q "IF DB_ID('knex_test') IS NULL CREATE DATABASE knex_test"
```

**Windows:** download SQL Server 2022 Developer Edition (free) from
Microsoft, run the installer, choose "Basic" or "Custom" install, enable
Mixed Mode auth during setup with `sa` password `Knex_Test1!`. No container
runtime needed — it just runs as a native Windows service on port 1433.
Then, from a terminal with `dart` on PATH:

```bash
git clone https://github.com/kartikey321/mssql-dart.git
cd mssql-dart
git checkout tls-debug
dart pub get
```

Either way, once SQL Server is up (Docker or native) and `knex_test` exists,
run the repro the same way:

```bash
MSSQL_TLS_DEBUG=true \
MSSQL_TLS_DEBUG_LOG=/tmp/tlsdbg.log \
MSSQL_MODE=explicit MSSQL_ITERS=20 \
dart run tmp_repros/dart_transaction_repro.dart

cat /tmp/tlsdbg.log
```

(On Windows, use a real path for `MSSQL_TLS_DEBUG_LOG`, e.g.
`C:\Temp\tlsdbg.log`, and set env vars per your shell — `$env:VAR='value'`
in PowerShell, or `set VAR=value` in cmd.)

Also worth running the other modes to match the original repro matrix:
`MSSQL_MODE=insert` (autocommit INSERT/SELECT, died ~iter 23) and
`MSSQL_MODE=param` (parameterized RPC INSERT/SELECT, died ~iter 12).
And a `MSSQL_ENCRYPT=false` control run — it's expected to pass all
iterations cleanly (that's what distinguishes this from a generic
transaction/session bug).

## What to look for in the log at the failure point

1. First `keylog:` line's label — confirms negotiated TLS version. Given
   Azure SQL Edge logs `Allowed TLS protocol versions are ['1.0 1.1 1.2']`,
   expect `CLIENT_RANDOM` (TLS 1.2) here too — real SQL Server 2022 also
   does not offer TLS 1.3 on this handshake path. If this instead reads
   `SERVER_HANDSHAKE_TRAFFIC_SECRET`/`EXPORTER_SECRET` (TLS 1.3), that's a
   surprise and worth flagging.
2. The last few `R contentType=0x.. ver=.. len=..` lines before the crash —
   `contentType=0x15` is a TLS alert (server rejected something at the TLS
   layer); anything else ending in a clean `bridge loop exit: clean EOF...`
   is a server-side session/socket close, not a TLS-layer rejection.
3. The `bridge loop exit: ...` line's reason.
4. Any `[tlsdbg] write error: ...` lines — would confirm/rule out the
   write-chain bug described above as the actual root cause.
