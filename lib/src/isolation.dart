/// SQL Server transaction isolation levels.
///
/// Used with [MssqlConnection.beginTransaction] / [MssqlConnection.transaction].
/// Maps to `SET TRANSACTION ISOLATION LEVEL …` (ms-tds / T-SQL).
enum MssqlIsolationLevel {
  readUncommitted,
  readCommitted,
  repeatableRead,

  /// Requires `ALLOW_SNAPSHOT_ISOLATION ON` (or RCSI) for the database.
  snapshot,
  serializable;

  /// T-SQL fragment after `SET TRANSACTION ISOLATION LEVEL`.
  String get sqlName => switch (this) {
        MssqlIsolationLevel.readUncommitted => 'READ UNCOMMITTED',
        MssqlIsolationLevel.readCommitted => 'READ COMMITTED',
        MssqlIsolationLevel.repeatableRead => 'REPEATABLE READ',
        MssqlIsolationLevel.snapshot => 'SNAPSHOT',
        MssqlIsolationLevel.serializable => 'SERIALIZABLE',
      };
}

/// Validates a SQL Server `SAVE TRANSACTION` name (identifier, ≤32 chars).
///
/// Throws [ArgumentError] when [name] is unsafe to interpolate into T-SQL.
void assertSavepointName(String name) {
  if (name.isEmpty || name.length > 32) {
    throw ArgumentError.value(
      name,
      'name',
      'Savepoint name must be 1–32 characters',
    );
  }
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'name',
      'Savepoint name must be a simple SQL identifier '
          r'(^[A-Za-z_][A-Za-z0-9_]*$)',
    );
  }
}
