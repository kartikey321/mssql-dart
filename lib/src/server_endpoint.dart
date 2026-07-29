import 'tds/constants.dart';

/// Parsed SQL Server address for LAN named-instance connections.
///
/// Accepts common forms:
/// - `host` / `host,1433`
/// - `host\INSTANCE` / `host\INSTANCE,15001`
///
/// [shouldResolvePort] is true when an instance name is present and no
/// explicit port was given — the caller should query SQL Browser (UDP 1434).
class ServerEndpoint {
  final String host;
  final int port;
  final String? instanceName;

  /// When true, [port] is still the default and SQL Browser should resolve it.
  final bool shouldResolvePort;

  const ServerEndpoint({
    required this.host,
    required this.port,
    this.instanceName,
    this.shouldResolvePort = false,
  });

  /// Parses [input] and merges optional [port] / [instanceName] overrides.
  ///
  /// Explicit ports win: `host\INST,15001`, or a non-default [port] argument,
  /// both disable Browser lookup.
  factory ServerEndpoint.parse(
    String input, {
    int port = defaultPort,
    String? instanceName,
  }) {
    var host = input.trim();
    if (host.isEmpty) {
      throw ArgumentError('host must not be empty');
    }

    var inst = instanceName?.trim();
    var p = port;
    var explicitPort = port != defaultPort;

    // SQL-style host,port (comma). Checked before backslash so
    // HOST\INST,15001 works.
    final comma = host.lastIndexOf(',');
    if (comma > 0) {
      final portStr = host.substring(comma + 1).trim();
      final parsedPort = int.tryParse(portStr);
      if (parsedPort != null && parsedPort > 0 && parsedPort <= 65535) {
        host = host.substring(0, comma).trim();
        p = parsedPort;
        explicitPort = true;
      }
    }

    // Named instance: HOST\INSTANCE (also accept HOST/INSTANCE).
    final sep = host.indexOf(r'\');
    final sepAlt = sep < 0 ? host.indexOf('/') : -1;
    final cut = sep >= 0 ? sep : sepAlt;
    if (cut > 0) {
      final fromHost = host.substring(cut + 1).trim();
      host = host.substring(0, cut).trim();
      inst ??= fromHost;
    }

    if (inst != null && inst.isEmpty) inst = null;

    final shouldResolve =
        inst != null && !explicitPort; // named instance, default port

    return ServerEndpoint(
      host: host,
      port: p,
      instanceName: inst,
      shouldResolvePort: shouldResolve,
    );
  }
}
