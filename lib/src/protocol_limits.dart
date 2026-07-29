import 'exception.dart';

/// Configurable safety limits for server-controlled TDS response sizes.
///
/// The default constructor uses conservative in-process allocation limits. Use
/// [unlimited] to preserve old behaviour or [sqlServerMaximums] to allow SQL
/// Server documented maximum values while still rejecting impossible sizes.
class MssqlProtocolLimits {
  static const int mebibyte = 1024 * 1024;

  /// SQL Server documented max bytes for varchar(max), varbinary(max), xml,
  /// text, and image values.
  static const int sqlServerMaximumLongValueBytes = 0x7FFFFFFF;

  /// SQL Server documented max columns in a SELECT statement.
  static const int sqlServerMaximumSelectColumns = 4096;

  static const int defaultMaximumTokenBytes = 16 * mebibyte;
  static const int defaultMaximumValueBytes = 64 * mebibyte;
  static const int defaultMaximumPlpChunkBytes = 4 * mebibyte;
  static const int defaultMaximumColumns = sqlServerMaximumSelectColumns;
  static const int defaultMaximumResultSets = 256;

  /// Maximum byte length for one token body or token-owned payload.
  final int? maximumTokenBytes;

  /// Maximum byte length for one decoded column / output value.
  final int? maximumValueBytes;

  /// Maximum byte length for a single PLP chunk.
  final int? maximumPlpChunkBytes;

  /// Maximum number of columns in one result set.
  final int? maximumColumns;

  /// Maximum number of result sets buffered by `queryMultiple` / drained by
  /// response parsers.
  final int? maximumResultSets;

  const MssqlProtocolLimits({
    this.maximumTokenBytes = defaultMaximumTokenBytes,
    this.maximumValueBytes = defaultMaximumValueBytes,
    this.maximumPlpChunkBytes = defaultMaximumPlpChunkBytes,
    this.maximumColumns = defaultMaximumColumns,
    this.maximumResultSets = defaultMaximumResultSets,
  })  : assert(maximumTokenBytes == null || maximumTokenBytes >= 0),
        assert(maximumValueBytes == null || maximumValueBytes >= 0),
        assert(maximumPlpChunkBytes == null || maximumPlpChunkBytes >= 0),
        assert(maximumColumns == null || maximumColumns >= 0),
        assert(maximumResultSets == null || maximumResultSets >= 0);

  const MssqlProtocolLimits._unlimited()
      : maximumTokenBytes = null,
        maximumValueBytes = null,
        maximumPlpChunkBytes = null,
        maximumColumns = null,
        maximumResultSets = null;

  /// Compatibility profile: no configured protocol size limits.
  static const unlimited = MssqlProtocolLimits._unlimited();

  /// SQL Server documented maximum value/column sizes.
  ///
  /// This profile is a specification ceiling, not a memory-safe application
  /// default: a single allowed value can still be up to about 2 GiB.
  static const sqlServerMaximums = MssqlProtocolLimits(
    maximumTokenBytes: sqlServerMaximumLongValueBytes,
    maximumValueBytes: sqlServerMaximumLongValueBytes,
    maximumPlpChunkBytes: sqlServerMaximumLongValueBytes,
    maximumColumns: sqlServerMaximumSelectColumns,
    maximumResultSets: null,
  );

  void checkTokenBytes(int length, String context) {
    _checkNonNegative(length, context);
    _checkMaximum(length, maximumTokenBytes, context);
  }

  void checkValueBytes(int length, String context) {
    _checkNonNegative(length, context);
    _checkMaximum(length, maximumValueBytes, context);
  }

  void checkPlpChunkBytes(int length, String context) {
    _checkNonNegative(length, context);
    _checkMaximum(length, maximumPlpChunkBytes, context);
    _checkMaximum(length, maximumValueBytes, context);
  }

  void checkColumns(int count, String context) {
    _checkNonNegative(count, context);
    _checkMaximum(count, maximumColumns, context);
  }

  void checkResultSets(int count, String context) {
    _checkNonNegative(count, context);
    _checkMaximum(count, maximumResultSets, context);
  }

  static void _checkNonNegative(int value, String context) {
    if (value < 0) {
      throw FormatException('$context length is negative: $value');
    }
  }

  static void _checkMaximum(int value, int? maximum, String context) {
    if (maximum != null && value > maximum) {
      throw MssqlProtocolLimitException(
        context: context,
        value: value,
        maximum: maximum,
      );
    }
  }
}
