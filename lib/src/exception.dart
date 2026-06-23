/// Thrown when the SQL Server returns an error or the TDS protocol fails.
class MssqlException implements Exception {
  final String message;
  final int errorCode;
  final int? severity;

  /// All errors from the server response, in the order they were received.
  ///
  /// A single statement may generate multiple errors (e.g. a CREATE TABLE
  /// that violates two constraints). The last error becomes [message] /
  /// [errorCode]; the full list (including that last error) is here.
  /// Empty when only one error was received.
  final List<MssqlException> precedingErrors;

  const MssqlException(
    this.message, {
    this.errorCode = 0,
    this.severity,
    this.precedingErrors = const [],
  });

  @override
  String toString() => 'MssqlException($errorCode): $message';
}
