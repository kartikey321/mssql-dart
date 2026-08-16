We're debugging a connection-death bug in a pure-Dart TDS 7.4 SQL Server
driver (`mssql-dart`, repo: https://github.com/kartikey321/mssql-dart,
branch `tls-debug`). This file is the brief for whoever (human or agent)
picks up the investigation on this machine. Read it fully before running
anything — the repro commands are at the bottom, but the reasoning for why
we're running them here (not on the Mac we started on) matters for
interpreting the results correctly.

## The bug

A TLS-enabled connection to SQL Server (`encrypt=true,
trustServerCertificate=true`) dies mid-session with:

```
Bad state: Connection closed mid-header
```

thrown from `TdsBuffer._readNextPacket` (`lib/src/tds/buf.dart`) when a
packet-header read returns fewer than 8 bytes.

Repro pattern (script: `tmp_repros/dart_transaction_repro.dart`):
- Repeated `BEGIN`/`INSERT`/`COMMIT`/`SELECT` on one connection dies around
  iteration 13 (`MSSQL_MODE=explicit`).
- Repeated autocommit `INSERT`/`SELECT` dies around iteration 23
  (`MSSQL_MODE=insert`).
- Repeated parameterized RPC `INSERT`/`SELECT` dies around iteration 12
  (`MSSQL_MODE=param`).
- The same driver with `encrypt=false` passes 30/30 cleanly
  (`MSSQL_ENCRYPT=false`).
- node-mssql/tedious passes the same SQL/transaction loop with
  `encrypt=true` against the same server.

So: TLS-specific, not transaction-SQL-specific (autocommit DML also dies),
and not a token-parsing bug (plaintext is fine). This points at the driver's
TLS transport, which is a hand-rolled bridge — see next section.

## Why the driver's TLS path looks the way it does

SQL Server's TDS protocol wraps the *TLS handshake* inside TDS PRELOGIN
packets, then switches to raw TLS records post-handshake (ms-tds §2.1.1).
Dart's `SecureSocket` has no public API to hand it a custom transport for
just the handshake bytes, so `MssqlConnection._upgradeTls()`
(`lib/src/connection.dart`) builds one out of a loopback TCP socket pair:

```
_buf writes → SecureSocket → encrypt → secSide(loopback) → bridgeSide
  bridgeSide → rawSocket (TDS-wrapped during handshake, raw TLS records after)

rawSocket → bridge read loop → bridgeSide → secSide(loopback) → SecureSocket
  → decrypt → _buf reads
```

This mirrors what tedious (Node) and go-mssqldb (Go) do internally, so the
approach itself isn't unusual. The question is whether *this* Dart
implementation of it has a bug, or whether it's hitting a genuine Dart
`dart:io` TLS/socket limitation.

## What's already been ruled out or found, on the Mac side

1. **Not a TLS-1.3-negotiation issue.** Azure SQL Edge's own log states
   `Allowed TLS protocol versions are ['1.0 1.1 1.2']` — it never offers
   1.3, so Dart's missing `maximumTlsProtocolVersion` API (confirmed: Dart's
   `SecurityContext` only exposes `minimumTlsProtocolVersion`, no maximum,
   no `setMaxSendFragment`, no `SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS`
   equivalent, no dynamic-record-sizing toggle — checked directly against
   `dart-sdk/sdk/lib/io/{secure_socket,security_context}.dart`) can't be
   forcing TLS 1.3 as the cause. This needs re-confirming against real SQL
   Server 2022's log (search its startup log for "Allowed TLS protocol
   versions"), but Linux SQL Server is very unlikely to differ from Edge
   here — same TLS backend behavior historically.

2. **A real, independent bug found and fixed on this branch.** In
   `_upgradeTls()`'s `writeRaw` closure, the original code was:
   ```dart
   rawWrite = rawWrite.then((_) async { ... });
   unawaited(rawWrite.catchError((_) {}));
   ```
   `catchError` was called on a *copy* of the future, not chained back into
   `rawWrite`. If one write ever throws, the real `rawWrite` chain stays
   permanently rejected, and every `.then()` after that silently
   short-circuits — meaning all subsequent writes to the server are silently
   dropped, with no error surfaced anywhere. That would look exactly like
   "the server went quiet, then the connection died N iterations later."
   This branch fixes it to self-heal and call `_markDead()` on a write
   error instead. **This is a leading candidate for the actual root cause**
   — if the repro no longer fails with this fix alone, that's very likely
   it, and the TLS-transport-architecture questions become moot.

3. **Local Mac testing hit two unrelated environment problems**, which is
   why we moved to a native amd64 host instead of continuing on the Mac:
   - Docker Desktop's port-forwarding got wedged after a container
     restart (TCP connects, but zero TDS bytes ever arrive at the host,
     confirmed via a raw-socket PRELOGIN probe that got an instant reply
     when run *inside* the container but timed out from the host).
   - The obvious fallback — real `mcr.microsoft.com/mssql/server:2022-latest`
     via Docker Desktop's Rosetta emulation — turned out to have its own
     multi-year history of open, unresolved GitHub issues
     (microsoft/mssql-docker #929, #922, #882, #832, #943, #955), including
     at least one **lock-manager stack dump** specific to Rosetta emulation
     (#922) — uncomfortably close to what we're debugging, since it's a
     transaction/locking-adjacent internal crash. All of these issues are
     specific to amd64-under-ARM-emulation (Rosetta/QEMU on Apple Silicon);
     none report the same failures on native Linux/Windows amd64, because
     there's no instruction-translation layer there.

   That's the whole reason this investigation moved to your machine: real
   SQL Server on native amd64, zero emulation, zero ambiguity about whether
   a crash is Rosetta's fault or the driver's.

## What to actually do

Full instructions with exact commands are in
`tmp_repros/README_TLS_DEBUG.md` in this same branch — read that next, it
has the `docker run` invocation, the env vars (`MSSQL_TLS_DEBUG`,
`MSSQL_TLS_DEBUG_LOG`), and what each debug log line means. Don't guess the
docker/dart invocation from this file; use the exact one in the README.

In short:

1. Clone the repo, `git checkout tls-debug`, `dart pub get`.
2. Get a real SQL Server instance up — either Docker without `--platform`
   (native amd64, no emulation needed on Linux/Windows), or a fully native
   install with no Docker at all (`apt install mssql-server` on Ubuntu, or
   the Windows Developer Edition installer). The README has both; prefer
   the native install if it's not much extra friction, since it also
   removes Docker's container-networking layer, not just CPU emulation —
   Docker Desktop's port-forwarding was the *other* thing that broke on the
   Mac, unrelated to Rosetta.
3. Run `tmp_repros/dart_transaction_repro.dart` across all three modes
   (`explicit`, `insert`, `param`) with `MSSQL_TLS_DEBUG=true` and a
   `MSSQL_TLS_DEBUG_LOG` file set, both with `MSSQL_ENCRYPT=true` (expect
   failure, per the Mac results) and `MSSQL_ENCRYPT=false` (expect clean
   pass, as a control).

## What we need answered

**Q1 — Does the writeRaw fix alone resolve it?** This branch already has
the fix from point 2 above applied. If the encrypted repro now passes
30/30 (or all iterations in whatever count you use) where the Mac's
*unfixed* driver died at ~12-23, that's a strong signal the write-chain bug
was the root cause — SQL Server's own TLS behavior and Dart's transport
design were probably fine all along. Report iteration count reached, pass
or fail, for all three modes.

**Q2 — If it still fails, where exactly, and how?** Open the debug log at
the failure point and report:
- The first `keylog:` line's label (`CLIENT_RANDOM` = TLS 1.2 negotiated;
  `SERVER_HANDSHAKE_TRAFFIC_SECRET`/`EXPORTER_SECRET` = TLS 1.3 — the
  latter would be a genuine surprise worth flagging loudly, since it would
  revive the TLS-1.3 API-gap theory).
- The last handful of `R contentType=0x.. len=..` lines before failure —
  is there a `contentType=0x15` (TLS alert) right before the crash, or does
  it just go quiet (clean EOF, `tlsHdr.length < 5`)?
- The `bridge loop exit: ...` reason line.
- Any `[tlsdbg] write error: ...` lines (would mean a write genuinely
  failed, even with the chain fix — different bug than what we fixed).
- Which iteration number it died on (from the `=== iter N: begin ===`
  markers in the same log), and how that compares to the Mac's ~12/23/13
  figures — same order of magnitude, or wildly different?

**Q3 — Does real SQL Server's log show the same TLS version cap as Azure
SQL Edge?** `docker logs mssql_tls_repro | grep -i "TLS protocol version"`
(or equivalent) — confirms or refutes point 1 above on real SQL Server,
not just Edge.

Report back plainly: pass/fail per mode, iteration count if it failed, and
the three trace details from Q2 if applicable. Don't propose an
architecture rewrite yet — first find out whether the already-identified
bug fix was sufficient, since that changes everything else about how
urgent/invasive a fix needs to be.
