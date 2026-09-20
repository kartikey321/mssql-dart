# Changelog

## Unreleased

* Fix multi-byte values that straddle two TDS packets being read as the wrong number or failing with `TDS stream ended unexpectedly` (reported and fixed independently in the poble-pos and Alexqwesa forks).
* Compile under dart2js: the PLP sentinel constants no longer use hex literals that JavaScript cannot represent, so Flutter web builds that reach this package compile (it still cannot run on the web; it needs raw sockets). Found in the univelop fork; CI now guards it.
* Raise the minimum Dart SDK to 3.4.0. The previously declared `>=3.0.0` was not installable, because `http` requires 3.2 or newer.
* Update dev dependencies (`lints` 6, `test` 1.32) and CI actions.
* Fix encrypted connections (`encrypt: true`) dying with `Bad state: Connection closed mid-header` after roughly 13-23 statements, and large statements never working over TLS. `dart:io`'s `SecureSocket` could seal one TDS packet as two TLS records, which SQL Server rejects. Encrypted connections now use 512-byte packets and align every message to the buffer boundary (see README, "Encrypted-connection behavior").
* Add `MssqlEncryptMode.strict` (TDS 8.0 strict encryption, `Encrypt=Strict`) for SQL Server 2022+ / Azure SQL. Not yet tested against a server with a trusted certificate.
* Fix the legacy TLS bridge silently dropping all later writes after one write failure.

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
