import 'dart:typed_data';

/// SQL `uniqueidentifier` parameter / value helper.
///
/// Wire format uses SQL Server mixed-endian GUID bytes (go-mssqldb
/// `UniqueIdentifier.Value`). Decode already returns the canonical
/// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` string.
class MssqlGuid {
  /// Canonical GUID string (with or without braces / dashes).
  final String value;

  const MssqlGuid(this.value);

  /// Parses [value] into 16 wire bytes (mixed endian).
  Uint8List toWireBytes() {
    final hex = value.replaceAll(RegExp(r'[{}\-]'), '');
    if (hex.length != 32) {
      throw ArgumentError.value(
        value,
        'value',
        'GUID must be 32 hex digits (dashes optional)',
      );
    }
    final d = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      d[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    void rev(int a, int b) {
      for (var i = a, j = b; i < j; i++, j--) {
        final t = d[i];
        d[i] = d[j];
        d[j] = t;
      }
    }

    rev(0, 3);
    rev(4, 5);
    rev(6, 7);
    return d;
  }

  @override
  String toString() => value;
}

/// SQL `money` value / parameter (8-byte, 4 decimal places).
///
/// Prefer this over bare [double] when the column / SP param is `money`.
/// Reads decode to [MssqlMoney] with an exact [scaled] integer (not `double`).
class MssqlMoney {
  /// Integer cents×100 (`value * 10000`).
  final int scaled;

  MssqlMoney(num value) : scaled = (value.toDouble() * 10000).round();

  /// Builds from the TDS scaled integer (no floating rounding).
  const MssqlMoney.fromScaled(this.scaled);

  /// Approximate decimal value (`scaled / 10000`). Prefer [scaled] for exact math.
  double get value => scaled / 10000.0;

  double toDouble() => value;

  @override
  bool operator ==(Object other) =>
      other is MssqlMoney && other.scaled == scaled;

  @override
  int get hashCode => scaled.hashCode;

  @override
  String toString() => value.toString();
}

/// SQL `smallmoney` value / parameter (4-byte, 4 decimal places).
class MssqlSmallMoney {
  /// Integer cents×100 (`value * 10000`).
  final int scaled;

  MssqlSmallMoney(num value) : scaled = (value.toDouble() * 10000).round();

  const MssqlSmallMoney.fromScaled(this.scaled);

  double get value => scaled / 10000.0;

  double toDouble() => value;

  @override
  bool operator ==(Object other) =>
      other is MssqlSmallMoney && other.scaled == scaled;

  @override
  int get hashCode => scaled.hashCode;

  @override
  String toString() => value.toString();
}

/// SQL `datetimeoffset` parameter — preserves timezone offset on write.
///
/// On read, the driver returns a UTC [DateTime] (offset is stripped after
/// decode). Use this wrapper when writing so the offset is sent.
///
/// [offset] overrides [DateTime.timeZoneOffset] when the host timezone cannot
/// express the desired zone (common in tests). The instant is always taken
/// from [value.toUtc](); [offset] is only the wire offset field.
class MssqlDateTimeOffset {
  final DateTime value;

  /// Scale 0–7 (default 7).
  final int scale;

  /// Optional wire offset; defaults to [value.timeZoneOffset].
  final Duration? offset;

  const MssqlDateTimeOffset(this.value, {this.scale = 7, this.offset});

  Duration get wireOffset => offset ?? value.timeZoneOffset;

  @override
  String toString() => value.toIso8601String();
}

/// SQL `decimal(p,s)` / `numeric(p,s)` value / parameter binder.
///
/// Prefer this over [double] when the column requires exact scale (prices,
/// quantities). Column reads decode to [MssqlDecimal] (not [double]); use
/// [toDouble] only when an approximate IEEE value is acceptable.
///
/// ```dart
/// await conn.query('SELECT @d', {
///   'd': MssqlDecimal(1234.5, precision: 10, scale: 2),
/// });
/// // or: MssqlDecimal.parse('1234.50', precision: 10, scale: 2)
/// ```
class MssqlDecimal {
  /// Signed unscaled integer (`value * 10^scale`).
  final BigInt unscaled;

  /// Total significant digits (1–38).
  final int precision;

  /// Digits after the decimal point (0–[precision]).
  final int scale;

  /// When true, declare/encode as `numeric` (`typeNumericN`); else `decimal`.
  final bool asNumeric;

  MssqlDecimal._({
    required this.unscaled,
    required this.precision,
    required this.scale,
    this.asNumeric = false,
  }) {
    if (precision < 1 || precision > 38) {
      throw ArgumentError.value(precision, 'precision', 'must be 1–38');
    }
    if (scale < 0 || scale > precision) {
      throw ArgumentError.value(scale, 'scale', 'must be 0–precision');
    }
    final digits = unscaled.abs().toString().length;
    // BigInt.zero → "0" has length 1; allow zero always.
    if (unscaled != BigInt.zero && digits > precision) {
      throw ArgumentError(
        'Value $unscaled exceeds decimal($precision,$scale) precision',
      );
    }
  }

  /// Decodes TDS DECIMALN/NUMERICN value bytes (sign + LE limbs).
  factory MssqlDecimal.fromWire(
    List<int> data, {
    required int scale,
    int? precision,
    bool asNumeric = false,
  }) {
    if (data.isEmpty) {
      throw ArgumentError('decimal wire bytes empty');
    }
    final positive = data[0] != 0;
    BigInt bigVal = BigInt.zero;
    for (var part = 0; part * 4 + 1 < data.length; part++) {
      final base = part * 4 + 1;
      final chunk = data[base] |
          (data[base + 1] << 8) |
          (data[base + 2] << 16) |
          (data[base + 3] << 24);
      bigVal += BigInt.from(chunk & 0xFFFFFFFF) << (part * 32);
    }
    if (!positive && bigVal != BigInt.zero) bigVal = -bigVal;
    final digits = bigVal == BigInt.zero ? 1 : bigVal.abs().toString().length;
    final p = (precision != null && precision >= scale && precision >= digits)
        ? precision
        : (digits > scale ? digits : scale).clamp(1, 38);
    return MssqlDecimal._(
      unscaled: bigVal,
      precision: p,
      scale: scale,
      asNumeric: asNumeric,
    );
  }

  /// Builds from a [num], fixing [scale] with half-up rounding via string form.
  factory MssqlDecimal(
    num value, {
    int precision = 18,
    int scale = 4,
    bool asNumeric = false,
  }) {
    if (value is int) {
      return MssqlDecimal.parse(
        value.toString(),
        precision: precision,
        scale: scale,
        asNumeric: asNumeric,
      );
    }
    return MssqlDecimal.parse(
      value.toStringAsFixed(scale),
      precision: precision,
      scale: scale,
      asNumeric: asNumeric,
    );
  }

  /// Parses a decimal literal (`-1234.56`). [scale] pads/truncates the fraction.
  factory MssqlDecimal.parse(
    String text, {
    int precision = 18,
    int scale = 4,
    bool asNumeric = false,
  }) {
    var t = text.trim().replaceAll(',', '');
    if (t.isEmpty) {
      throw ArgumentError.value(text, 'text', 'empty decimal');
    }
    var negative = false;
    if (t.startsWith('-')) {
      negative = true;
      t = t.substring(1);
    } else if (t.startsWith('+')) {
      t = t.substring(1);
    }
    final parts = t.split('.');
    if (parts.length > 2) {
      throw ArgumentError.value(text, 'text', 'invalid decimal');
    }
    final intPart = parts[0].isEmpty ? '0' : parts[0];
    var frac = parts.length > 1 ? parts[1] : '';
    if (frac.length > scale) {
      // Truncate toward zero for determinism (matches many drivers' default).
      frac = frac.substring(0, scale);
    }
    while (frac.length < scale) {
      frac = '${frac}0';
    }
    final digitsRaw = '$intPart$frac';
    var digits = digitsRaw.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) digits = '0';
    var coeff = BigInt.parse(digits);
    if (negative && coeff != BigInt.zero) coeff = -coeff;
    return MssqlDecimal._(
      unscaled: coeff,
      precision: precision,
      scale: scale,
      asNumeric: asNumeric,
    );
  }

  /// MaxLen byte for DECIMALN/NUMERICN TYPE_INFO (ms-tds / go-mssqldb).
  static int maxLenForPrecision(int precision) {
    if (precision <= 9) return 5;
    if (precision <= 19) return 9;
    if (precision <= 28) return 13;
    return 17;
  }

  /// TDS value bytes: sign + LE limbs (length = [maxLenForPrecision]).
  Uint8List toWireBytes() {
    final maxLen = maxLenForPrecision(precision);
    final out = Uint8List(maxLen);
    out[0] = unscaled >= BigInt.zero ? 1 : 0;
    var remaining = unscaled.abs();
    for (var i = 1; i < maxLen; i += 4) {
      final limb = (remaining & BigInt.from(0xFFFFFFFF)).toInt();
      remaining >>= 32;
      out[i] = limb & 0xFF;
      if (i + 1 < maxLen) out[i + 1] = (limb >> 8) & 0xFF;
      if (i + 2 < maxLen) out[i + 2] = (limb >> 16) & 0xFF;
      if (i + 3 < maxLen) out[i + 3] = (limb >> 24) & 0xFF;
    }
    return out;
  }

  String get sqlDecl =>
      '${asNumeric ? 'numeric' : 'decimal'}($precision,$scale)';

  /// Approximate IEEE value — may lose precision for large [precision].
  double toDouble() {
    final sign = unscaled < BigInt.zero ? -1.0 : 1.0;
    final abs = unscaled.abs();
    final divisor = BigInt.from(10).pow(scale);
    final intPart = abs ~/ divisor;
    final fracPart = abs.remainder(divisor);
    return sign *
        (intPart.toDouble() + fracPart.toDouble() / divisor.toDouble());
  }

  @override
  bool operator ==(Object other) =>
      other is MssqlDecimal &&
      other.unscaled == unscaled &&
      other.precision == precision &&
      other.scale == scale &&
      other.asNumeric == asNumeric;

  @override
  int get hashCode => Object.hash(unscaled, precision, scale, asNumeric);

  @override
  String toString() {
    final abs = unscaled.abs().toString().padLeft(scale + 1, '0');
    final neg = unscaled < BigInt.zero ? '-' : '';
    if (scale == 0) return '$neg$abs';
    final split = abs.length - scale;
    return '$neg${abs.substring(0, split)}.${abs.substring(split)}';
  }
}

/// SQL `varchar` parameter (8-bit / collation bytes) — not `nvarchar`.
///
/// Bare [String] params are sent as `nvarchar`. Use this when the column or
/// SP parameter is `varchar` / `char` so the server avoids implicit conversions
/// (go-mssqldb `mssql.VarChar`).
///
/// Values are encoded as Latin-1 (`0x00`–`0xFF` code units). Non-Latin-1
/// characters throw [ArgumentError].
class MssqlVarchar {
  final String value;

  /// Force `varchar(max)` / PLP (also used automatically when length > 8000).
  final bool max;

  const MssqlVarchar(this.value, {this.max = false});

  /// Latin-1 wire bytes (same decode path as [typeBigVarChar] reads).
  List<int> toWireBytes() {
    final out = <int>[];
    for (final c in value.codeUnits) {
      if (c > 0xFF) {
        throw ArgumentError.value(
          value,
          'value',
          'MssqlVarchar requires Latin-1 (code unit ≤ 0xFF); got U+${c.toRadixString(16)}',
        );
      }
      out.add(c);
    }
    return out;
  }

  String get sqlDecl {
    if (max || value.length > 8000) return 'varchar(max)';
    return 'varchar(8000)';
  }

  @override
  String toString() => value;
}

/// SQL `date` parameter (date-only, no time) — go-mssqldb / civil.Date.
///
/// Prefer this over bare [DateTime] when the column is `date` (bare [DateTime]
/// is sent as `datetime2`).
class MssqlDate {
  final int year;
  final int month;
  final int day;

  MssqlDate(this.year, this.month, this.day) {
    if (month < 1 || month > 12) {
      throw ArgumentError.value(month, 'month', 'must be 1–12');
    }
    if (day < 1 || day > 31) {
      throw ArgumentError.value(day, 'day', 'must be 1–31');
    }
    // Dart DateTime overflows invalid days (Feb 30 → Mar); reject those.
    final dt = DateTime.utc(year, month, day);
    if (dt.year != year || dt.month != month || dt.day != day) {
      throw ArgumentError('Invalid calendar date $year-$month-$day');
    }
  }

  factory MssqlDate.fromDateTime(DateTime dt) =>
      MssqlDate(dt.year, dt.month, dt.day);

  /// Days since 0001-01-01 (ms-tds DATE).
  int get daysSinceYear1 =>
      DateTime.utc(year, month, day).difference(DateTime.utc(1, 1, 1)).inDays;

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

/// SQL `time` parameter (time-of-day, no date) — go-mssqldb / civil.Time.
///
/// Prefer this over bare [DateTime] when the column is `time`.
class MssqlTime {
  final int hour;
  final int minute;
  final int second;

  /// Fractional seconds as microseconds (0–999999); truncated to [scale].
  final int microsecond;

  /// Scale 0–7 (default 7).
  final int scale;

  MssqlTime({
    required this.hour,
    required this.minute,
    this.second = 0,
    this.microsecond = 0,
    this.scale = 7,
  }) {
    if (hour < 0 || hour > 23) {
      throw ArgumentError.value(hour, 'hour', 'must be 0–23');
    }
    if (minute < 0 || minute > 59) {
      throw ArgumentError.value(minute, 'minute', 'must be 0–59');
    }
    if (second < 0 || second > 59) {
      throw ArgumentError.value(second, 'second', 'must be 0–59');
    }
    if (microsecond < 0 || microsecond > 999999) {
      throw ArgumentError.value(microsecond, 'microsecond', 'must be 0–999999');
    }
    if (scale < 0 || scale > 7) {
      throw ArgumentError.value(scale, 'scale', 'must be 0–7');
    }
  }

  factory MssqlTime.fromDateTime(DateTime dt, {int scale = 7}) => MssqlTime(
        hour: dt.hour,
        minute: dt.minute,
        second: dt.second,
        microsecond: dt.millisecond * 1000 + dt.microsecond,
        scale: scale,
      );

  factory MssqlTime.fromDuration(Duration d, {int scale = 7}) {
    final us = d.inMicroseconds;
    if (us < 0 || us >= Duration.microsecondsPerDay) {
      throw ArgumentError.value(d, 'd', 'must be within 00:00:00–23:59:59.999999');
    }
    final h = us ~/ Duration.microsecondsPerHour;
    final rem = us % Duration.microsecondsPerHour;
    final m = rem ~/ Duration.microsecondsPerMinute;
    final rem2 = rem % Duration.microsecondsPerMinute;
    final s = rem2 ~/ Duration.microsecondsPerSecond;
    final micros = rem2 % Duration.microsecondsPerSecond;
    return MssqlTime(
      hour: h,
      minute: m,
      second: s,
      microsecond: micros,
      scale: scale,
    );
  }

  String get sqlDecl => 'time($scale)';

  @override
  String toString() {
    final frac = microsecond.toString().padLeft(6, '0');
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}:'
        '${second.toString().padLeft(2, '0')}.$frac';
  }
}

/// SQL legacy `datetime` parameter (go-mssqldb `DateTime1`).
///
/// Bare [DateTime] is sent as `datetime2`. Use this for columns typed
/// `datetime` (precision ~3.33ms, range 1753–9999).
class MssqlDateTime {
  final DateTime value;

  MssqlDateTime(this.value) {
    final d = DateTime.utc(value.year, value.month, value.day);
    final min = DateTime.utc(1753, 1, 1);
    final max = DateTime.utc(9999, 12, 31);
    if (d.isBefore(min) || d.isAfter(max)) {
      throw ArgumentError.value(
        value,
        'value',
        'datetime range is 1753-01-01 … 9999-12-31',
      );
    }
  }

  /// 8 wire bytes: days since 1900-01-01 (LE int32) + 300ths-of-second (LE uint32).
  Uint8List toWireBytes() {
    final days = DateTime.utc(value.year, value.month, value.day)
        .difference(DateTime.utc(1900, 1, 1))
        .inDays;
    final nsWithinSec =
        value.millisecond * 1000000 + value.microsecond * 1000;
    var tm = 300 *
            (value.second + value.minute * 60 + value.hour * 3600) +
        _nanosToThreeHundredths(nsWithinSec);
    var dayAdj = days;
    // One day = 86400 * 300 three-hundredths.
    const dayTicks = 300 * 86400;
    if (tm >= dayTicks) {
      dayAdj++;
      tm -= dayTicks;
    }
    final out = Uint8List(8);
    final dayBits = dayAdj & 0xFFFFFFFF;
    out[0] = dayBits & 0xFF;
    out[1] = (dayBits >> 8) & 0xFF;
    out[2] = (dayBits >> 16) & 0xFF;
    out[3] = (dayBits >> 24) & 0xFF;
    out[4] = tm & 0xFF;
    out[5] = (tm >> 8) & 0xFF;
    out[6] = (tm >> 16) & 0xFF;
    out[7] = (tm >> 24) & 0xFF;
    return out;
  }

  /// SQL Server datetime rounds fractional seconds to 1/300 s.
  static int _nanosToThreeHundredths(int ns) =>
      (ns * 3 / 1e7).round();

  @override
  String toString() => value.toIso8601String();
}

/// SQL legacy `smalldatetime` parameter (minute precision).
///
/// Range 1900-01-01 … 2079-06-06. Seconds are rounded to the nearest minute.
class MssqlSmallDateTime {
  final DateTime value;

  MssqlSmallDateTime(this.value) {
    final d = DateTime.utc(value.year, value.month, value.day);
    final min = DateTime.utc(1900, 1, 1);
    final max = DateTime.utc(2079, 6, 6);
    if (d.isBefore(min) || d.isAfter(max)) {
      throw ArgumentError.value(
        value,
        'value',
        'smalldatetime range is 1900-01-01 … 2079-06-06',
      );
    }
  }

  /// 4 wire bytes: days since 1900-01-01 (LE uint16) + minutes (LE uint16).
  Uint8List toWireBytes() {
    var days = DateTime.utc(value.year, value.month, value.day)
        .difference(DateTime.utc(1900, 1, 1))
        .inDays;
    var mins = value.hour * 60 + value.minute;
    // Round seconds ≥ 30 up to the next minute.
    if (value.second >= 30) {
      mins++;
      if (mins >= 24 * 60) {
        mins = 0;
        days++;
      }
    }
    if (days < 0) {
      days = 0;
      mins = 0;
    }
    final out = Uint8List(4);
    out[0] = days & 0xFF;
    out[1] = (days >> 8) & 0xFF;
    out[2] = mins & 0xFF;
    out[3] = (mins >> 8) & 0xFF;
    return out;
  }

  @override
  String toString() => value.toIso8601String();
}

/// SQL `xml` parameter (UCS-2 PLP, typeXml) — not `nvarchar`.
///
/// Bare [String] params are sent as `nvarchar`. Use this when the column or
/// SP parameter is `xml` so the server avoids implicit conversion (ms-tds
/// XMLTYPE; go-mssqldb `typeXml` with `SchemaPresent=0`).
class MssqlXml {
  final String value;

  const MssqlXml(this.value);

  String get sqlDecl => 'xml';

  @override
  String toString() => value;
}

/// SQL `varbinary(n)` / `varbinary(max)` parameter binder.
///
/// Bare [List<int>] is always sent as `varbinary(max)` (PLP). Use this when
/// the column is `varbinary(n)` / `binary(n)` so MaxLength matches the schema
/// (go-mssqldb sizes `[]byte` to `len(val)`; LAN plan quality).
///
/// ```dart
/// await conn.query('SELECT @b', {
///   'b': MssqlVarbinary([0xDE, 0xAD], length: 16),
/// });
/// // or: MssqlVarbinary(bytes, max: true) for varbinary(max)
/// ```
class MssqlVarbinary {
  final List<int> value;

  /// Force `varbinary(max)` / PLP (also used automatically when length > 8000).
  final bool max;

  /// Declared / TYPE_INFO MaxLength when not [max] (1–8000).
  ///
  /// Defaults to `max(value.length, 1)` so empty payloads still declare
  /// `varbinary(1)` with a zero-length value (USHORTLEN).
  final int? length;

  const MssqlVarbinary(this.value, {this.max = false, this.length});

  /// Whether the wire form is PLP (`varbinary(max)`).
  bool get useMax {
    if (max) return true;
    if (length != null && length! > 8000) return true;
    return value.length > 8000;
  }

  /// USHORT MaxLength for non-max payloads (1–8000).
  int get wireMaxLength {
    if (useMax) {
      throw StateError('wireMaxLength is only valid for non-max varbinary');
    }
    final n = length ?? (value.isEmpty ? 1 : value.length);
    if (n < 1 || n > 8000) {
      throw ArgumentError.value(n, 'length', 'must be 1–8000 (or use max: true)');
    }
    if (value.length > n) {
      throw ArgumentError(
        'Value length ${value.length} exceeds varbinary($n)',
      );
    }
    return n;
  }

  String get sqlDecl {
    if (useMax) return 'varbinary(max)';
    return 'varbinary($wireMaxLength)';
  }

  @override
  String toString() => 'MssqlVarbinary(${value.length} bytes)';
}

/// SQL `nvarchar(n)` / `nvarchar(max)` parameter binder.
///
/// Bare [String] is sent as `nvarchar(4000)` or `nvarchar(max)`. Use this when
/// the column is `nvarchar(n)` so MaxLength matches the schema (LAN plan
/// quality / avoid implicit conversions).
class MssqlNVarchar {
  final String value;

  /// Force `nvarchar(max)` / PLP (also used when length > 4000 chars).
  final bool max;

  /// Declared character length when not [max] (1–4000).
  /// Defaults to `max(value.length, 1)`.
  final int? length;

  const MssqlNVarchar(this.value, {this.max = false, this.length});

  bool get useMax {
    if (max) return true;
    if (length != null && length! > 4000) return true;
    return value.length > 4000;
  }

  /// Character MaxLength for non-max payloads (1–4000).
  int get wireCharLength {
    if (useMax) {
      throw StateError('wireCharLength is only valid for non-max nvarchar');
    }
    final n = length ?? (value.isEmpty ? 1 : value.length);
    if (n < 1 || n > 4000) {
      throw ArgumentError.value(n, 'length', 'must be 1–4000 (or use max: true)');
    }
    if (value.length > n) {
      throw ArgumentError(
        'Value length ${value.length} exceeds nvarchar($n)',
      );
    }
    return n;
  }

  String get sqlDecl {
    if (useMax) return 'nvarchar(max)';
    return 'nvarchar($wireCharLength)';
  }

  @override
  String toString() => value;
}

/// SQL `nchar(n)` parameter — fixed-width UCS-2, space-padded on write.
class MssqlNChar {
  final String value;

  /// Declared / pad length in characters (1–4000).
  final int length;

  MssqlNChar(this.value, {required this.length}) {
    if (length < 1 || length > 4000) {
      throw ArgumentError.value(length, 'length', 'must be 1–4000');
    }
    if (value.length > length) {
      throw ArgumentError(
        'Value length ${value.length} exceeds nchar($length)',
      );
    }
  }

  /// Space-padded to [length] characters.
  String get padded {
    if (value.length >= length) return value;
    return value.padRight(length, ' ');
  }

  String get sqlDecl => 'nchar($length)';

  @override
  String toString() => padded;
}

/// SQL `binary(n)` parameter — fixed-width, zero-padded on write.
///
/// Prefer [MssqlVarbinary] for `varbinary(n)`. Use this for `binary(n)` columns
/// (typeBigBinary).
class MssqlBinary {
  final List<int> value;

  /// Declared / pad length in bytes (1–8000).
  final int length;

  MssqlBinary(this.value, {required this.length}) {
    if (length < 1 || length > 8000) {
      throw ArgumentError.value(length, 'length', 'must be 1–8000');
    }
    if (value.length > length) {
      throw ArgumentError(
        'Value length ${value.length} exceeds binary($length)',
      );
    }
  }

  /// Zero-padded to [length] bytes.
  Uint8List get padded {
    final out = Uint8List(length);
    final n = value.length < length ? value.length : length;
    out.setRange(0, n, value);
    return out;
  }

  String get sqlDecl => 'binary($length)';

  @override
  String toString() => 'MssqlBinary($length bytes)';
}

/// SQL `rowversion` / `timestamp` value helper (always 8 bytes).
///
/// Columns of this type are server-generated; use the binder for `WHERE`
/// / OUTPUT comparisons (`binary(8)` on the wire).
class MssqlRowVersion {
  /// Exactly 8 bytes (SQL Server rowversion).
  final Uint8List bytes;

  MssqlRowVersion(List<int> value) : bytes = Uint8List.fromList(value) {
    if (bytes.length != 8) {
      throw ArgumentError.value(
        value.length,
        'value.length',
        'rowversion must be exactly 8 bytes',
      );
    }
  }

  /// Parses a 16-digit hex string (optional `0x` prefix).
  factory MssqlRowVersion.parse(String hex) {
    var h = hex.trim();
    if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
    h = h.replaceAll(RegExp(r'[\s\-]'), '');
    if (h.length != 16) {
      throw ArgumentError.value(hex, 'hex', 'need 16 hex digits');
    }
    final out = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return MssqlRowVersion(out);
  }

  String get sqlDecl => 'binary(8)';

  String toHex() {
    final b = StringBuffer('0x');
    for (final x in bytes) {
      b.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is MssqlRowVersion && _bytesEq(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => toHex();

  static bool _bytesEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
