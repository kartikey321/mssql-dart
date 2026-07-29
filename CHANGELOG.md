# Changelog

## Unreleased

## 0.5.0

* **Breaking:** TLS now uses the native OpenSSL transport on Windows, Linux,
  and Android;
  the `MSSQL_NATIVE_TLS` switch and Dart `SecureSocket` TLS bridge are removed.
* TLS: add Android native TLS support for `arm64-v8a`, `armeabi-v7a`, and
  `x86_64`; encrypted apps load the ABI-specific `libmssql_tls.so` packaged by
  the consumer, while cleartext remains Dart and TCP only.
* Build: cross-build, checksum, and release statically-linked Android helper
  archives from GitHub Actions; the local script verifies its pinned OpenSSL
  source before compiling.
* **Breaking:** replace `securityContext` with `trustedCertificateFile` and
  `trustedCertificateDirectory` PEM trust-root options.
* TLS: accept `TrustedCertificateFile` / `TrustedCertificateDirectory` (and
  `CAFile` / `CAPath`) in ADO.NET-style and `sqlserver://` connection strings.
* TLS: serialize native TLS input, output, and pending writes so Attention can
  be injected safely while a response is active. Multi-packet requests, Bulk
  Load, and TLS cancellation are supported by the same transport.
* TLS: retain encrypted bytes not yet accepted by the native memory BIO instead
  of treating partial BIO consumption as a transport failure.
* TLS: release partially initialized OpenSSL resources when native session
  creation fails and reject failed SNI or fragment-limit configuration.
* TLS: negotiate a 16,383-byte TDS packet size in encrypted LOGIN7 sessions,
  keeping SQL Server and the native TLS fragment boundary in agreement.
* TLS/NTLM: derive `tls-server-end-point` channel bindings from the native TLS
  peer certificate before sending NTLM authentication.
* TLS: remove the retired Dart `SecureSocket` ring-alignment and synthetic NOP
  implementation now that encrypted I/O exclusively uses the native transport.
* Tests: add `MSSQL_LIVE_IMAGE` for switching the Docker live-test pair among
  SQL Server 2019, 2022 (default), 2025, or another compatible Linux image.
* Tests: add `tool/full_tests.ps1` and a six-container Docker matrix to run
  native CTest, offline Dart tests, and the full live suite against SQL Server
  2017, 2019, 2022, and 2025 with optional and forced TLS.
* Tests: keep the matrix runner's offline phase out of `test/live`, so its
  output does not include expected live-test skips before containers start.
* Tests: make the SQL Server matrix image compatible with 2017 through 2025 by
  using the shared numeric SQL Server UID; rebuild only stale matrix images.
* CI: build, CTest, smoke-test, checksum, and publish Windows x64 and Linux
  x64 native TLS helper artifacts on GitHub Actions.
* Tests: replace the retired Dart TLS bridge/alignment unit suites with a
  native CTest that performs a complete in-memory client/server handshake,
  certificate DER retrieval, encrypted request write, and encrypted response
  read through the exported OpenSSL ABI.
* TLS: add an optional OpenSSL memory-BIO helper with a stable C ABI, CMake
  build, native CTest coverage, and Dart FFI smoke coverage.
* TLS: add native handshake and post-handshake transport components that keep
  SQL Server's PRELOGIN TLS wrapping in Dart while moving TLS records and
  packet encryption into the native helper. The connection path still uses the
  existing Dart transport until the `TdsBuffer` transport refactor lands.
* TLS: introduce the `TdsTransport` boundary with cleartext-socket and native
  TLS adapters, preparing TDS framing to stop writing directly to `Socket`.
* TLS: migrate `TdsBuffer` packet writes onto `TdsTransport`, including a
  transport replacement hook for the native TLS handoff.
* TLS: treat an empty OpenSSL memory-BIO output drain as a normal retry state
  rather than a TLS error.
* TLS: add an experimental native TLS handshake and transport, enabled with
  `MSSQL_NATIVE_TLS=1`. The stable default remains Dart's TLS bridge while
  native transport retry handling for Attention is completed.
* TLS: validate multi-packet SQL batch and Bulk Load on the experimental
  native transport. Bulk Load fixtures now match the encoder's nullable BCP
  column metadata.
* Tests: validate the native TLS path with forced-encryption connection, type,
  pooling, error-recovery, large-response, and multi-packet request coverage.
* Build: add a Windows MSVC/Ninja script for building and testing the native
  helper. Generated native binaries remain ignored by Git.

## 0.4.1

Throw UnsupportedError for multi-packet queries and bulk inserts over TLS. 
(due to DartVM limitation...)

* TLS: reject encrypted outbound SQL batches and RPC requests that require more
  than one TDS packet. The current Dart `SecureSocket` bridge cannot safely
  preserve those packet boundaries.
* TLS: reject `bulkInsert` on encrypted connections for the same reason.
  Use an unencrypted connection only on a trusted private network, or use a
  driver with production-ready TLS Bulk Load support.
* Tests: replace TLS alignment crash regressions with checks that unsupported
  encrypted operations fail locally and leave the connection usable(see tests 
  with throwsUnsupportedError).

## 0.4.0

Reimplement TLS + live tests

* TLS: preflight complete TDS messages before encrypted writes so synthetic
  alignment traffic can run only before an independent SQL batch or RPC, never
  between packets of an active request or during login, Bulk Load, Attention,
  SSPI, or transaction-manager traffic.
* Tests: add deterministic TLS alignment packet coverage and opt-in live
  regressions for row-count semantics, multi-packet batches, Attention, and
  Bulk Load against the self-signed SQL Server containers.
* TLS: replace fragile TLS-record reassembly with go-mssqldb-style PRELOGIN
  handshake wrap + opaque post-handshake byte passthrough (`TdsTlsBridge`).
* TLS: avoid Dart `SecureSocket` splitting one TDS packet across two TLS
  records (8 KiB plaintext ring wrap) by aligning writes — full-size non-EOM
  packets only, and wrap-fill no-op SQLBatches when needed.
* TLS: add optional `SecurityContext` and `hostNameInCertificate` on connect,
  pool, and connection strings (`HostNameInCertificate`).
* Tests: two live containers in `docker-compose.live.yml` — optional TLS on
  **14334** (`mssql-dart-live`) and `forceencryption=1` on **14335**
  (`mssql-dart-live-force-tls`). Force-TLS stress hard-wires 14335; one
  `dart test test/live` run covers both.
* Tests: move SQL Server integration coverage to opt-in `test/live`, add
  environment-backed configuration, driver-based readiness checks, disposable
  databases, Docker Compose setup, and CI live-test configuration.
* Tests: move the remaining Docker-dependent suites and diagnostic script out
  of the default test run; live connection-string coverage now uses the shared
  `MSSQL_*` configuration instead of the retired port `14330` and credentials.
* Tests: configure the live Docker SQL Server with a short-lived self-signed
  TLS certificate (`forceencryption=0` on 14334; sibling force-TLS on 14335).
* Security: deprecate Azure AD username/password (ROPC) token acquisition,
  reject blank bearer tokens, and expose bounded structured OAuth failures
  without including raw token endpoint response bodies in exception text.
* Tests: add deterministic malformed-input mutation coverage for truncated and
  length-corrupted TDS token streams and NTLM Type 2 messages.

## 0.3.0

* Security: harden `bulkInsert` identifier handling by bracket-quoting
  multipart table names, re-quoting existing bracketed identifiers, escaping
  closing brackets, and rejecting empty, control-character, or overlong
  identifier parts.
* Security: add `MssqlProtocolLimits` for server-controlled TDS sizes
  including token bytes, single value bytes, PLP chunk bytes, column counts, and
  result set counts. Protocol limit violations now throw
  `MssqlProtocolLimitException` and close the connection to avoid stream
  desynchronization and pool poisoning.
* Security: harden malformed TDS and NTLM response parsing by validating packet
  sizes, token body offsets, UTF-16LE byte lengths, `sql_variant` metadata
  lengths, and NTLM TargetInfo AV_PAIR bounds before decoding.
* Security: harden SQL Browser named-instance discovery by ignoring UDP
  responses whose source address or port does not match the queried browser
  endpoint; use the matching IPv4/IPv6 socket family, retry resolved addresses
  within one deadline, reject malformed responses, and reuse the answering IP
  for the ensuing TCP dial while retaining the hostname for TLS validation.
* Release: correct the Dart SDK lower bound to `>=3.4.0` to match direct
  dependency requirements.
* LAN typed binders: `MssqlNVarchar` / `MssqlNChar` / `MssqlBinary` /
  `MssqlRowVersion` for sized `nvarchar(n)` / `nchar(n)` / `binary(n)` and
  `rowversion`/`timestamp` compare params (bare `String` stays
  `nvarchar(4000|max)`).
* LAN exact numeric reads: `decimal` / `numeric` → `MssqlDecimal`; `money` →
  `MssqlMoney`; `smallmoney` → `MssqlSmallMoney` (exact `scaled` / `unscaled`,
  not IEEE `double`). Use `.toDouble()` when an approximate value is enough.
  **Breaking** for code that cast those columns to `double`.
* LAN pool observability: `MssqlPool.stats` / `size` / `available` /
  `borrowed` / `pending` (node-mssql / tarn style) plus lifetime counters
  (`created`, `destroyed`, `acquired`, `released`, `acquireTimeouts`,
  `validationFailures`, `resetFailures`); `onPoolEvent` / `MssqlPool.onEvent`
  lifecycle hooks.
* LAN typed binders: `MssqlXml` / `MssqlVarbinary` for `xml` and sized
  `varbinary(n)` / `varbinary(max)` params (bare `String` → nvarchar; bare
  `List<int>` stays `varbinary(max)`).
* LAN typed binders: `MssqlDateTime` / `MssqlSmallDateTime` for legacy
  `datetime` / `smalldatetime` params (go-mssqldb `DateTime1`; bare
  `DateTime` stays `datetime2`).
* LAN session resilience: TCP `keepAlive` (go-mssqldb default 30s;
  `KeepAlive=` in connection strings; `Duration.zero` disables) +
  `TCP_NODELAY`; `sessionInitSql` after login and after `resetSession`
  (go-mssqldb `SessionInitSQL`).
* LAN typed binders: `MssqlVarchar`, `MssqlDate`, `MssqlTime` for varchar /
  date / time params (bare `String`/`DateTime` stay nvarchar/datetime2).
* LAN Always On / HA: `ApplicationIntent=ReadOnly` (`readOnlyIntent` → LOGIN7
  `fReadOnlyIntent`); ENVCHANGE type 20 routing reconnect (one hop);
  `FailoverPartner` / `FailoverPort` on primary connect failure;
  `MultiSubnetFailover` parallel DNS dial; connection-string + pool knobs.
* LAN typed binders: `MssqlGuid`, `MssqlMoney`, `MssqlSmallMoney`,
  `MssqlDateTimeOffset`, `MssqlDecimal` for uniqueidentifier / money /
  datetimeoffset / decimal|numeric params.
* LAN transactions: `MssqlIsolationLevel`, `beginTransaction(isolation:)`,
  `savepoint` / `rollbackTo`, `transaction(isolation:)` on connection + pool.
* LAN diagnostics + resilience: parse full INFO/ERROR metadata (`state`,
  `severity`, `serverName`, `procName`, `lineNo`); `onInfoMessage` on
  connection/pool; `MssqlTransient.isTransient` / `retry`; pool/connect
  `connectRetries` (pool default 2).
* LAN RPC / stored procedures: `MssqlConnection.call` / `MssqlPool.call` with
  `MssqlOutput` parameters; capture `RETURNSTATUS` + `RETURNVALUE` into
  `MssqlProcedureResult` (go-mssqldb / ms-tds RETURNVALUE).

## 0.2.0

LAN / on-prem hardening wave: cancel, NTLM, timeouts, pool health, named
instances, session reset, connection strings, bulk insert, and TVP.

* Fix TDS buffer data corruption when multi-byte reads straddle packet boundaries
  (carry unread remainder into the next packet — upstream PR #3).
* Protocol offline unit coverage (buffer, PreLogin, Login7, tokens, types, RPC,
  Attention, FedAuth mock) inspired by microsoft/go-mssqldb / Tedious / ms-tds.
* `TdsBuffer.sendAttention` / `MssqlConnection.cancel` with `drainUntilAttentionAck`;
  live cancel suites (plain + TLS + pool / multi / RPC).
* NTLM Type 1–3 (NTLMv2, MIC, KEY_EXCH, TLS channel bindings); `connectNtlm`;
  pool `ntlm` / `ntlmDomain`.
* Pool Azure AD: `azureAd` / `azureAdAuth` (FedAuth; takes precedence over NTLM/SQL).
* LAN timeouts: login covers full handshake; `queryTimeout` / per-call Attention;
  expose `appName` + `packetSize`.
* Pool health: dead-socket detection; `validateOnAcquire` (default true).
* Named instances: `HOST\INSTANCE` parse, SQL Browser UDP 1434, PRELOGIN INSTOPT.
* Session DB tracking (`database` / `initialDatabase` / `resetDatabase`);
  TDS RESETCONNECTION via `resetSession`; pool `resetOnRelease` (default true).
* Connection strings: ADO.NET + `sqlserver://` (`connectFromString`,
  `MssqlPoolConfig.fromConnectionString`).
* Bulk insert (`bulkInsert` BCP) and TVP (`MssqlTvp` type 0xF3).
* README LAN / on-prem cookbook; CI unit job before Docker integration.

## 0.1.1

* Remove hardcoded credentials from example and benchmark tool — all connection details now read from environment variables.
* Wrap connection and pool usage in `try/finally` to guarantee `close()` on error.

## 0.1.0

* Initial release.
* Pure-Dart TDS 7.4 driver — no native extensions, no FFI.
* `MssqlConnection` with SQL Server and Azure AD authentication (bearer token, ROPC, client credentials).
* `MssqlPool` with configurable min/max, idle reaping, and acquire timeouts.
* Full read support for all common SQL Server types including `sql_variant`.
* Named-parameter queries using `sp_executesql` (`@name` syntax).
* Streaming large result sets with `queryStream`.
* Multiple result sets via `queryMultiple`.
* Transaction support — callback form (auto commit/rollback) and manual `begin`/`commit`/`rollback`.
* TLS encryption with optional self-signed certificate trust.
* `MssqlException` with `errorCode`, `severity`, and `precedingErrors` for multi-error batches.
