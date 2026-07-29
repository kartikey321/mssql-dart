/// Thrown when the SQL Server returns an error or the TDS protocol fails.
class MssqlException implements Exception {
  final String message;
  final int errorCode;
  final int? severity;

  /// ERROR token state (1–127), when parsed from the wire.
  final int? state;

  /// Server name from the ERROR token, when present.
  final String? serverName;

  /// Procedure name from the ERROR token, when present.
  final String? procName;

  /// Line number from the ERROR token, when present.
  final int? lineNo;

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
    this.state,
    this.serverName,
    this.procName,
    this.lineNo,
    this.precedingErrors = const [],
  });

  @override
  String toString() => 'MssqlException($errorCode): $message';
}

/// Thrown when a server-controlled TDS size exceeds [MssqlProtocolLimits].
class MssqlProtocolLimitException extends MssqlException {
  final String context;
  final int value;
  final int maximum;

  MssqlProtocolLimitException({
    required this.context,
    required this.value,
    required this.maximum,
  }) : super(
          '$context $value exceeds configured maximum $maximum',
        );
}
