# Changelog

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
