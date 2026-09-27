# Changelog

## Unreleased

### Added

* Resolve `host\INSTANCE` addresses to a TCP port via SQL Server Browser (UDP 1434), for `MssqlConnection.connect` and pool connections built from a connection string. Ported from and credited to the Alexqwesa fork; hardened to verify the reply comes from the address and port queried.
* Parse ADO.NET-style connection strings (`Server=...;User Id=...;...`) and `sqlserver://` URLs via `MssqlConnectionString.parse`, `MssqlConnection.connectWithString`, and `MssqlPoolConfig.fromConnectionString`.

## 0.2.0

### Fixed

* Encrypted connections (`encrypt: true`) no longer die with `Bad state: Connection closed mid-header` after roughly 13-23 statements, and large statements now work over TLS. `dart:io`'s `SecureSocket` could seal one TDS packet as two TLS records when a write crossed its internal 8 KiB buffer, and SQL Server closes the connection when a packet spans records. Every message on an encrypted connection is now aligned to the packet size (see README, "Encrypted-connection behavior").
* Values that straddle two TDS packets are read correctly. Previously a multi-byte value split across packets could be read as a different number without any error, or fail with `TDS stream ended unexpectedly`. Reported and fixed independently in the poble-pos and Alexqwesa forks.
* The legacy TLS bridge no longer silently drops all later writes after a single write failure.
* The package compiles under dart2js, so Flutter web builds that reach it no longer fail (it still cannot run on the web; it needs raw sockets). Found in the univelop fork.

### Added

* `MssqlEncryptMode.strict`: TDS 8.0 strict encryption (`Encrypt=Strict`) for SQL Server 2022+ and Azure SQL. TLS starts before any TDS bytes, the server certificate is always validated, and `trustServerCertificate: true` is rejected. Select it with `encryptMode:` on `MssqlConnection.connect`, `connectAzureAd` and `MssqlPoolConfig`. `encrypt: bool` keeps its old meaning.

### Changed

* Encrypted connections request 512-byte TDS packets and pad each message to keep packets aligned, at a cost of up to about 0.5 KB per statement on the wire. Results and plan caching are unaffected. `program_name` and `client_interface_name` in `sys.dm_exec_sessions` show trailing spaces. `encrypt: false` is unchanged.
* The minimum Dart SDK is now 3.4.0. The previously declared `>=3.0.0` could not be installed, because `http` requires 3.2 or newer.
* Development dependencies updated (`lints` 6, `test` 1.32).

### Tested against

SQL Server 2017, 2019, 2022 and 2025 on Linux; 2019, 2022 and 2025 on Windows; TDS 8.0 strict on Windows SQL Server 2022 and 2025; Azure SQL Edge; Dart 3.4.0, stable and beta. **Not yet verified:** Azure SQL Database, Azure AD logins, and strict mode against Azure SQL.

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
