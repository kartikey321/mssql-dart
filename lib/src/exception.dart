/// Thrown when the SQL Server returns an error or the TDS protocol fails.
class MssqlException implements Exception {
  final String message;
  final int errorCode;
  final int? severity;

  const MssqlException(this.message, {this.errorCode = 0, this.severity});

  @override
  String toString() => 'MssqlException($errorCode): $message';
}
