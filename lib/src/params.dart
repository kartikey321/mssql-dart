import 'result.dart';
import 'tds/token_stream.dart';

/// Marks a parameter as OUTPUT (or INPUT/OUTPUT) for [MssqlConnection.call].
///
/// ```dart
/// final r = await conn.call('dbo.MyProc', {
///   'inVal': 5,
///   'outVal': MssqlOutput(0), // INT INPUT/OUTPUT
/// });
/// print(r.output['outVal']); // server-assigned value
/// print(r.returnStatus);     // RETURN integer, if any
/// ```
///
/// When [value] is `null` and [sqlType] is omitted, the wire type defaults to
/// `int`. Prefer an explicit [sqlType] for non-int OUTPUT-only params
/// (e.g. `nvarchar(100)`, `bigint`, `bit`).
class MssqlOutput {
  /// Initial value sent to the server (`null` for OUTPUT-only).
  final Object? value;

  /// Optional SQL type override (`int`, `bigint`, `nvarchar(100)`, …).
  final String? sqlType;

  /// Creates an OUTPUT parameter. Optional [value] is the initial INPUT value;
  /// optional [sqlType] overrides type inference when [value] is null.
  const MssqlOutput([this.value, this.sqlType]);
}
/// Result of an RPC stored-procedure call ([MssqlConnection.call]).
///
/// Captures TDS [RETURNSTATUS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/)
/// (`0x79`) and [RETURNVALUE](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/7091f6f6-b83d-4ed2-afeb-ba5013dfb18f)
/// (`0xAC`) tokens in addition to any SELECT result sets.
class MssqlProcedureResult {
  /// Integer from `RETURN` in the procedure, or `null` if none was sent.
  final int? returnStatus;

  /// OUTPUT / INPUT-OUTPUT parameter values keyed by name (without `@`).
  final Map<String, Object?> output;

  /// Result sets from SELECT statements inside the procedure (may be empty).
  final List<MssqlResult> resultSets;

  const MssqlProcedureResult({
    required this.returnStatus,
    required this.output,
    required this.resultSets,
  });

  /// First result set, or an empty [MssqlResult] when the proc returned none.
  MssqlResult get first => resultSets.isEmpty
      ? MssqlResult.fromInternal(
          const QueryResult(columns: [], rows: [], rowsAffected: 0),
        )
      : resultSets.first;

  bool get isEmpty => resultSets.every((s) => s.isEmpty);

  @override
  String toString() =>
      'MssqlProcedureResult(returnStatus: $returnStatus, '
      'output: $output, sets: ${resultSets.length})';
}
