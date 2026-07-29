import 'tds/constants.dart';

/// Parsed SQL Server connection settings (ADO.NET / ODBC / `sqlserver://` URL).
///
/// Keyword aliases follow microsoft/go-mssqldb `msdsn` (case-insensitive;
/// spaces ignored in keys). Unsupported options are ignored.
///
/// Examples:
/// ```text
/// Server=10.0.0.5,1433;Database=app;User Id=sa;Password=x;Encrypt=false;
/// Server=sql01\SQLEXPRESS;User Id=DOMAIN\bob;Password=x;Trusted_Connection=yes;
/// sqlserver://sa:x@localhost:1433?database=master&encrypt=false
/// ```
class MssqlConnectionString {
  final String host;
  final int port;
  final String? instanceName;
  final String user;
  final String password;
  final String database;
  final String appName;
  final int packetSize;
  final bool encrypt;
  final bool trustServerCertificate;

  /// Optional PEM file containing additional certificate authorities.
  final String? trustedCertificateFile;

  /// Optional directory containing hashed PEM certificate authorities.
  final String? trustedCertificateDirectory;

  /// Hostname for SNI / cert validation (ADO `HostNameInCertificate`).
  final String? hostNameInCertificate;

  final Duration connectionTimeout;
  final Duration? queryTimeout;

  /// When non-null, open with NTLM (`DOMAIN\user` or Integrated Security).
  final String? ntlmDomain;
  final String? workstation;

  /// Always On `ApplicationIntent=ReadOnly`.
  final bool readOnlyIntent;

  /// Database mirroring partner (tried when primary connect fails).
  final String? failoverPartner;
  final int? failoverPort;

  /// Parallel-dial all DNS A/AAAA records (AG multi-subnet listeners).
  final bool multiSubnetFailover;

  /// TCP keepalive interval (go-mssqldb `keepAlive`; default 30s).
  /// [Duration.zero] disables.
  final Duration keepAlive;

  const MssqlConnectionString({
    required this.host,
    this.port = defaultPort,
    this.instanceName,
    required this.user,
    required this.password,
    this.database = '',
    this.appName = 'mssql-dart',
    this.packetSize = defaultPacketSize,
    this.encrypt = true,
    this.trustServerCertificate = false,
    this.trustedCertificateFile,
    this.trustedCertificateDirectory,
    this.hostNameInCertificate,
    this.connectionTimeout = const Duration(seconds: 15),
    this.queryTimeout,
    this.ntlmDomain,
    this.workstation,
    this.readOnlyIntent = false,
    this.failoverPartner,
    this.failoverPort,
    this.multiSubnetFailover = false,
    this.keepAlive = const Duration(seconds: 30),
  });

  bool get useNtlm => ntlmDomain != null;

  /// Parses an ADO.NET / ODBC keyword string or a `sqlserver://` URL.
  factory MssqlConnectionString.parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Connection string must not be empty');
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('sqlserver://') || lower.startsWith('mssql://')) {
      return MssqlConnectionString._fromUrl(trimmed);
    }
    return MssqlConnectionString._fromAdo(trimmed);
  }

  factory MssqlConnectionString._fromAdo(String input) {
    final raw = _parseAdoPairs(input);
    final map = <String, String>{};
    for (final e in raw.entries) {
      final canon = _canonicalKey(e.key);
      if (canon == null) continue;
      if (map.containsKey(canon)) {
        throw FormatException(
          'Duplicate connection string key "${e.key}" (canonical "$canon")',
        );
      }
      map[canon] = e.value;
    }

    final server = map['server'];
    if (server == null || server.isEmpty) {
      throw FormatException(
          'Connection string requires Server (or Data Source)');
    }

    var user = map['user'] ?? '';
    var password = map['password'] ?? '';
    String? ntlmDomain;
    final workstation = map['workstation'];

    // DOMAIN\user → NTLM
    final slash = user.indexOf(r'\');
    if (slash > 0) {
      ntlmDomain = user.substring(0, slash);
      user = user.substring(slash + 1);
    }

    final integrated = _parseBool(map['integratedsecurity']) ||
        _parseBool(map['trustedconnection']);
    if (integrated) {
      if (ntlmDomain == null || user.isEmpty || password.isEmpty) {
        throw FormatException(
          'Integrated Security / Trusted_Connection requires '
          r'User Id=DOMAIN\user and Password (pure Dart has no Windows SSO)',
        );
      }
    }

    final portOverride =
        map['port'] != null ? int.tryParse(map['port']!) : null;
    if (map['port'] != null &&
        (portOverride == null || portOverride <= 0 || portOverride > 65535)) {
      throw FormatException('Invalid Port "${map['port']}"');
    }

    final ep = _parseServer(server, portOverride: portOverride);
    final instance = ep.instanceName ?? map['instancename'];

    final packetSize =
        map['packetsize'] != null ? int.tryParse(map['packetsize']!) : null;
    if (map['packetsize'] != null && (packetSize == null || packetSize < 512)) {
      throw FormatException('Invalid Packet Size "${map['packetsize']}"');
    }

    final loginSecs = _parseSeconds(
      map['connectiontimeout'] ?? map['logintimeout'],
    );
    final querySecs =
        _parseSeconds(map['querytimeout'] ?? map['commandtimeout']);

    // Encrypt: missing → package default true; disable/false → false.
    final encrypt =
        map.containsKey('encrypt') ? _parseEncrypt(map['encrypt']!) : true;
    final trust = map.containsKey('trustservercertificate')
        ? _parseBool(map['trustservercertificate'])
        : false;

    final readOnly = _parseApplicationIntent(map['applicationintent']);
    final database = map['database'] ?? '';
    if (readOnly && database.isEmpty) {
      throw FormatException(
        'Database must be specified when ApplicationIntent is ReadOnly',
      );
    }

    final failoverPort =
        map['failoverport'] != null ? int.tryParse(map['failoverport']!) : null;
    if (map['failoverport'] != null &&
        (failoverPort == null || failoverPort <= 0 || failoverPort > 65535)) {
      throw FormatException('Invalid Failover Port "${map['failoverport']}"');
    }

    return MssqlConnectionString(
      host: ep.host,
      port: ep.port,
      instanceName: instance,
      user: user,
      password: password,
      database: database,
      appName: map['appname'] ?? 'mssql-dart',
      packetSize: packetSize ?? defaultPacketSize,
      encrypt: encrypt,
      trustServerCertificate: trust,
      trustedCertificateFile: map['trustedcertificatefile'],
      trustedCertificateDirectory: map['trustedcertificatedirectory'],
      hostNameInCertificate: map['hostnameincertificate'],
      connectionTimeout: loginSecs != null
          ? Duration(seconds: loginSecs)
          : const Duration(seconds: 15),
      queryTimeout: querySecs != null ? Duration(seconds: querySecs) : null,
      ntlmDomain: ntlmDomain,
      workstation: workstation,
      readOnlyIntent: readOnly,
      failoverPartner: map['failoverpartner'],
      failoverPort: failoverPort,
      multiSubnetFailover: _parseBool(map['multisubnetfailover']),
      keepAlive: _parseKeepAlive(map['keepalive']),
    );
  }

  factory MssqlConnectionString._fromUrl(String input) {
    // Normalize scheme for Uri (mssql → sqlserver).
    var s = input;
    if (s.toLowerCase().startsWith('mssql://')) {
      s = 'sqlserver://${s.substring(8)}';
    }
    final uri = Uri.parse(s);
    if (uri.host.isEmpty) {
      throw FormatException('sqlserver URL requires a host');
    }

    var user = uri.userInfo.isEmpty
        ? ''
        : Uri.decodeComponent(
            uri.userInfo.contains(':')
                ? uri.userInfo.split(':').first
                : uri.userInfo,
          );
    var password = '';
    if (uri.userInfo.contains(':')) {
      password = Uri.decodeComponent(
        uri.userInfo.substring(uri.userInfo.indexOf(':') + 1),
      );
    }

    String? ntlmDomain;
    final slash = user.indexOf(r'\');
    if (slash > 0) {
      ntlmDomain = user.substring(0, slash);
      user = user.substring(slash + 1);
    }

    // Instance: first path segment (sqlserver://host/INSTANCE)
    String? instance;
    final segments = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      instance = Uri.decodeComponent(segments.first);
    }

    final q = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      final canon = _canonicalKey(k);
      if (canon != null) q[canon] = v;
    });

    // Query can override user/password/database/…
    if (q.containsKey('user')) user = q['user']!;
    if (q.containsKey('password')) password = q['password']!;
    if (user.contains(r'\')) {
      final i = user.indexOf(r'\');
      ntlmDomain = user.substring(0, i);
      user = user.substring(i + 1);
    }

    final port = uri.hasPort
        ? uri.port
        : (q['port'] != null ? int.tryParse(q['port']!) : null) ?? defaultPort;

    final packetSize =
        q['packetsize'] != null ? int.tryParse(q['packetsize']!) : null;
    final loginSecs = _parseSeconds(
      q['connectiontimeout'] ?? q['logintimeout'],
    );
    final querySecs = _parseSeconds(q['querytimeout'] ?? q['commandtimeout']);

    final encrypt =
        q.containsKey('encrypt') ? _parseEncrypt(q['encrypt']!) : true;
    final trust = q.containsKey('trustservercertificate')
        ? _parseBool(q['trustservercertificate'])
        : false;

    final readOnly = _parseApplicationIntent(q['applicationintent']);
    final database = q['database'] ?? '';
    if (readOnly && database.isEmpty) {
      throw FormatException(
        'Database must be specified when ApplicationIntent is ReadOnly',
      );
    }

    final failoverPort =
        q['failoverport'] != null ? int.tryParse(q['failoverport']!) : null;

    return MssqlConnectionString(
      host: uri.host,
      port: port,
      instanceName: instance ?? q['instancename'],
      user: user,
      password: password,
      database: database,
      appName: q['appname'] ?? 'mssql-dart',
      packetSize: packetSize ?? defaultPacketSize,
      encrypt: encrypt,
      trustServerCertificate: trust,
      trustedCertificateFile: q['trustedcertificatefile'],
      trustedCertificateDirectory: q['trustedcertificatedirectory'],
      hostNameInCertificate: q['hostnameincertificate'],
      connectionTimeout: loginSecs != null
          ? Duration(seconds: loginSecs)
          : const Duration(seconds: 15),
      queryTimeout: querySecs != null ? Duration(seconds: querySecs) : null,
      ntlmDomain: ntlmDomain,
      workstation: q['workstation'],
      readOnlyIntent: readOnly,
      failoverPartner: q['failoverpartner'],
      failoverPort: failoverPort,
      multiSubnetFailover: _parseBool(q['multisubnetfailover']),
      keepAlive: _parseKeepAlive(q['keepalive']),
    );
  }

  /// Splits `key=value;key=value` with optional `{braced;values}`.
  static Map<String, String> _parseAdoPairs(String input) {
    final out = <String, String>{};
    var i = 0;
    while (i < input.length) {
      while (i < input.length &&
          (input[i] == ';' || input[i] == ' ' || input[i] == '\t')) {
        i++;
      }
      if (i >= input.length) break;

      final eq = input.indexOf('=', i);
      if (eq < 0) {
        throw FormatException(
            'Expected key=value near "${input.substring(i)}"');
      }
      final key = input.substring(i, eq).trim();
      i = eq + 1;
      while (i < input.length && (input[i] == ' ' || input[i] == '\t')) {
        i++;
      }

      String value;
      if (i < input.length && input[i] == '{') {
        final end = input.indexOf('}', i + 1);
        if (end < 0) {
          throw FormatException('Unclosed { in connection string value');
        }
        value = input.substring(i + 1, end);
        i = end + 1;
        if (i < input.length && input[i] == ';') i++;
      } else {
        final semi = input.indexOf(';', i);
        if (semi < 0) {
          value = input.substring(i).trim();
          i = input.length;
        } else {
          value = input.substring(i, semi).trim();
          i = semi + 1;
        }
      }
      if (key.isNotEmpty) out[key] = value;
    }
    return out;
  }

  static String? _canonicalKey(String raw) {
    final k = raw.toLowerCase().replaceAll(' ', '').replaceAll('_', '');
    switch (k) {
      case 'server':
      case 'addr':
      case 'address':
      case 'networkaddress':
      case 'datasource':
        return 'server';
      case 'user':
      case 'userid':
      case 'uid':
      case 'username':
        return 'user';
      case 'password':
      case 'pwd':
        return 'password';
      case 'database':
      case 'initialcatalog':
        return 'database';
      case 'appname':
      case 'applicationname':
      case 'app':
        return 'appname';
      case 'port':
        return 'port';
      case 'encrypt':
        return 'encrypt';
      case 'trustservercertificate':
        return 'trustservercertificate';
      case 'trustedcertificatefile':
      case 'cafile':
        return 'trustedcertificatefile';
      case 'trustedcertificatedirectory':
      case 'capath':
        return 'trustedcertificatedirectory';
      case 'hostnameincertificate':
        return 'hostnameincertificate';
      case 'packetsize':
        return 'packetsize';
      case 'connectiontimeout':
      case 'connecttimeout':
      case 'timeout':
      case 'logintimeout':
        return 'connectiontimeout';
      case 'querytimeout':
      case 'commandtimeout':
        return 'querytimeout';
      case 'workstationid':
      case 'wsid':
      case 'workstation':
        return 'workstation';
      case 'instancename':
      case 'instance':
        return 'instancename';
      case 'integratedsecurity':
        return 'integratedsecurity';
      case 'trustedconnection':
        return 'trustedconnection';
      case 'applicationintent':
        return 'applicationintent';
      case 'failoverpartner':
        return 'failoverpartner';
      case 'failoverport':
        return 'failoverport';
      case 'multisubnetfailover':
        return 'multisubnetfailover';
      case 'keepalive':
        return 'keepalive';
      default:
        return null; // ignore unknown
    }
  }

  static ({String host, int port, String? instanceName}) _parseServer(
    String server, {
    int? portOverride,
  }) {
    var s = server.trim();
    // Strip tcp: / np: prefixes (np: not supported).
    final lower = s.toLowerCase();
    if (lower.startsWith('tcp:')) {
      s = s.substring(4).trim();
    } else if (lower.startsWith('np:')) {
      throw FormatException('Named pipes (np:) are not supported');
    }

    // server,port or server\instance,port
    int port = portOverride ?? defaultPort;
    String? instance;
    var host = s;

    final comma = host.lastIndexOf(',');
    if (comma > 0) {
      final p = int.tryParse(host.substring(comma + 1).trim());
      if (p != null && p > 0 && p <= 65535) {
        host = host.substring(0, comma).trim();
        if (portOverride == null) port = p;
      }
    }

    final bs = host.indexOf(r'\');
    if (bs > 0) {
      instance = host.substring(bs + 1).trim();
      host = host.substring(0, bs).trim();
    }

    if (host.isEmpty) {
      throw FormatException('Server host must not be empty');
    }
    return (host: host, port: port, instanceName: instance);
  }

  static bool _parseBool(String? v) {
    if (v == null) return false;
    switch (v.trim().toLowerCase()) {
      case 'true':
      case 'yes':
      case 'y':
      case '1':
      case 't':
      case 'on':
        return true;
      default:
        return false;
    }
  }

  /// Maps go-mssqldb encrypt values → our bool (strict → true).
  static bool _parseEncrypt(String v) {
    switch (v.trim().toLowerCase()) {
      case 'true':
      case 'yes':
      case 'y':
      case '1':
      case 't':
      case 'mandatory':
      case 'strict':
        return true;
      case 'false':
      case 'no':
      case 'n':
      case '0':
      case 'f':
      case 'optional':
      case 'disable':
      case 'disabled':
        return false;
      default:
        throw FormatException('Invalid Encrypt value "$v"');
    }
  }

  /// `ApplicationIntent=ReadOnly` (case-insensitive); other values → false.
  static bool _parseApplicationIntent(String? v) {
    if (v == null || v.isEmpty) return false;
    final t = v.trim().toLowerCase();
    if (t == 'readonly') return true;
    if (t == 'readwrite') return false;
    throw FormatException(
      'Invalid ApplicationIntent "$v" (expected ReadOnly or ReadWrite)',
    );
  }

  /// go-mssqldb `keepAlive` seconds; missing → 30s; `0` → disabled.
  static Duration _parseKeepAlive(String? v) {
    if (v == null || v.isEmpty) return const Duration(seconds: 30);
    final n = int.tryParse(v.trim());
    if (n == null || n < 0) {
      throw FormatException('Invalid KeepAlive seconds "$v"');
    }
    return Duration(seconds: n);
  }

  static int? _parseSeconds(String? v) {
    if (v == null || v.isEmpty) return null;
    final n = int.tryParse(v.trim());
    if (n == null || n < 0) {
      throw FormatException('Invalid timeout seconds "$v"');
    }
    return n;
  }
}
