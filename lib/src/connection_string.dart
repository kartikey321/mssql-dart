import 'connection.dart';
import 'tds/constants.dart';

/// Parsed settings from an ADO.NET connection string or `sqlserver://` URL.
class MssqlConnectionString {
  final String host, user, password, database, applicationName;
  final int port;
  final String? instanceName;
  final MssqlEncryptMode encryptMode;
  final bool trustServerCertificate;
  final Duration connectTimeout;
  const MssqlConnectionString(
      {required this.host,
      required this.user,
      required this.password,
      this.port = defaultPort,
      this.instanceName,
      this.database = '',
      this.applicationName = 'mssql-dart',
      this.encryptMode = MssqlEncryptMode.mandatory,
      this.trustServerCertificate = false,
      this.connectTimeout = const Duration(seconds: 30)});

  /// The value to pass as [MssqlConnection.connect]'s `host` parameter.
  ///
  /// Carries the `\instanceName` suffix, so it resolves through SQL Server
  /// Browser, only when no explicit port was given. An explicit port always
  /// bypasses Browser resolution, matching ADO.NET's own behavior — passing
  /// both was silently broken before (the literal, unresolved
  /// "host\instance" string reached the socket layer and failed to resolve
  /// as a hostname).
  String get connectHost => instanceName != null && port == defaultPort
      ? '$host\\$instanceName'
      : host;

  factory MssqlConnectionString.parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) throw FormatException('Connection string is empty');
    if (RegExp(r'^sqlserver://', caseSensitive: false).hasMatch(trimmed)) {
      return _url(trimmed);
    }
    final v = _pairs(input);
    final e = _endpoint(v['server'] ?? '');
    return MssqlConnectionString(
        host: e.host,
        port: e.port,
        instanceName: e.instance,
        user: v['user'] ?? '',
        password: v['password'] ?? '',
        database: v['database'] ?? '',
        applicationName: v['applicationName'] ?? 'mssql-dart',
        encryptMode: _encrypt(v['encrypt'] ?? 'true'),
        trustServerCertificate: _bool(v['trust'] ?? 'false'),
        connectTimeout: _timeout(v['timeout'] ?? '30'));
  }
  static MssqlConnectionString _url(String input) {
    Uri u;
    try {
      u = Uri.parse(input);
    } on FormatException {
      // Uri.parse's FormatException echoes the offending input, which can
      // contain the password; never let that reach a caller.
      throw const FormatException('Invalid sqlserver URL');
    }
    if (u.host.isEmpty) throw FormatException('sqlserver URL requires a host');
    final q = <String, String>{};
    u.queryParameters.forEach((k, v) {
      final n = _key(k);
      if (n != null) q[n] = v;
    });
    final colon = u.userInfo.indexOf(':');
    final user = u.userInfo.isEmpty
        ? ''
        : Uri.decodeComponent(
            colon < 0 ? u.userInfo : u.userInfo.substring(0, colon));
    final pass =
        colon < 0 ? '' : Uri.decodeComponent(u.userInfo.substring(colon + 1));
    final segments = u.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segments.length > 1) {
      throw FormatException('sqlserver URL has too many path segments');
    }
    final e =
        _endpoint(u.host + (segments.isEmpty ? '' : r'\' + segments.single),
            port: u.hasPort ? u.port : null,
            // The URL grammar has its own unambiguous port (the ":port" above);
            // unlike ADO.NET's "host,port" syntax, a comma here can only belong
            // to the path segment (the instance name), so it must never be
            // reinterpreted as a port separator.
            allowCommaPort: false);
    return MssqlConnectionString(
        host: e.host,
        port: e.port,
        instanceName: e.instance,
        user: q['user'] ?? user,
        password: q['password'] ?? pass,
        database: q['database'] ?? '',
        applicationName: q['applicationName'] ?? 'mssql-dart',
        encryptMode: _encrypt(q['encrypt'] ?? 'true'),
        trustServerCertificate: _bool(q['trust'] ?? 'false'),
        connectTimeout: _timeout(q['timeout'] ?? '30'));
  }

  static Map<String, String> _pairs(String input) {
    final out = <String, String>{};
    var i = 0;
    while (i < input.length) {
      while (i < input.length && (input[i] == ';' || input[i].trim().isEmpty)) {
        i++;
      }
      if (i == input.length) break;
      final eq = input.indexOf('=', i);
      if (eq < 0) throw FormatException('Expected key=value');
      final key = _key(input.substring(i, eq));
      if (key == null) {
        throw FormatException('Unsupported connection-string key');
      }
      i = eq + 1;
      while (i < input.length && input[i].trim().isEmpty) {
        i++;
      }
      final b = StringBuffer();
      String? quote;
      if (i < input.length &&
          (input[i] == '\'' || input[i] == '"' || input[i] == '{')) {
        quote = input[i++] == '{' ? '}' : input[i - 1];
        var closed = false;
        while (i < input.length) {
          if (input[i] == quote) {
            if (i + 1 < input.length && input[i + 1] == quote) {
              b.write(quote);
              i += 2;
              continue;
            }
            i++;
            closed = true;
            break;
          }
          b.write(input[i++]);
        }
        if (!closed) throw FormatException('Unclosed connection-string value');
      } else {
        while (i < input.length && input[i] != ';') {
          b.write(input[i++]);
        }
      }
      while (i < input.length && input[i].trim().isEmpty) {
        i++;
      }
      if (i < input.length && input[i] != ';') {
        throw FormatException('Expected semicolon after value');
      }
      if (i < input.length) {
        i++;
      }
      out[key] = quote == null ? b.toString().trim() : b.toString();
    }
    return out;
  }

  static String? _key(String raw) {
    switch (raw.trim().toLowerCase().replaceAll(RegExp(r'[ _]'), '')) {
      case 'server':
      case 'datasource':
      case 'address':
      case 'addr':
      case 'networkaddress':
        return 'server';
      case 'database':
      case 'initialcatalog':
        return 'database';
      case 'user':
      case 'userid':
      case 'uid':
        return 'user';
      case 'password':
      case 'pwd':
        return 'password';
      case 'encrypt':
        return 'encrypt';
      case 'trustservercertificate':
        return 'trust';
      case 'applicationname':
      case 'app':
        return 'applicationName';
      case 'connecttimeout':
      case 'connectiontimeout':
        return 'timeout';
    }
    return null;
  }

  static ({String host, int port, String? instance}) _endpoint(String raw,
      {int? port, bool allowCommaPort = true}) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('tcp:')) {
      s = s.substring(4).trim();
    }
    if (s.isEmpty) throw FormatException('Server host must not be empty');
    var p = port ?? defaultPort;
    final comma = allowCommaPort ? s.lastIndexOf(',') : -1;
    if (comma >= 0) {
      final parsed = int.tryParse(s.substring(comma + 1).trim());
      if (parsed == null || parsed < 1 || parsed > 65535) {
        throw FormatException('Invalid SQL Server port');
      }
      if (port == null) p = parsed;
      s = s.substring(0, comma).trim();
    }
    if (p < 1 || p > 65535) throw FormatException('Invalid SQL Server port');
    String? instance;
    final slash = s.indexOf(r'\');
    if (slash >= 0) {
      instance = s.substring(slash + 1).trim();
      s = s.substring(0, slash).trim();
      if (instance.isEmpty) {
        throw FormatException('SQL Server instance must not be empty');
      }
    }
    if (s.isEmpty) throw FormatException('Server host must not be empty');
    return (host: s, port: p, instance: instance);
  }

  static bool _bool(String v) {
    switch (v.trim().toLowerCase()) {
      case 'true':
      case 'yes':
      case '1':
        return true;
      case 'false':
      case 'no':
      case '0':
        return false;
    }
    throw FormatException('Invalid boolean value');
  }

  static MssqlEncryptMode _encrypt(String v) {
    switch (v.trim().toLowerCase()) {
      case 'true':
      case 'yes':
      case 'mandatory':
        return MssqlEncryptMode.mandatory;
      case 'false':
      case 'no':
      case 'optional':
        return MssqlEncryptMode.disabled;
      case 'strict':
        return MssqlEncryptMode.strict;
    }
    throw FormatException('Invalid Encrypt value');
  }

  static Duration _timeout(String v) {
    final n = int.tryParse(v.trim());
    // ADO.NET treats Connect Timeout=0 as "wait indefinitely", which this
    // driver's connect timeout cannot represent (it is always a finite
    // Duration). Silently turning 0 into Duration.zero would time out
    // almost instantly — the opposite of what was asked for — so it is
    // rejected instead of misinterpreted.
    if (n == null || n <= 0) {
      throw FormatException('Invalid connection timeout');
    }
    return Duration(seconds: n);
  }

  @override
  String toString() =>
      'MssqlConnectionString(host: $host, port: $port, user: $user, password: ***)';
}
