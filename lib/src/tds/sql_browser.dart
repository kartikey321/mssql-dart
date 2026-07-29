import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../exception.dart';

/// SQL Server Browser (SSRP) client — resolves named-instance TCP ports.
///
/// Speaks UDP on port 1434 ([CLNT_UCAST_INST] / [SVR_RESP]), per
/// [MS-SSRP] / go-mssqldb instance lookup. Used when connecting to
/// `HOST\INSTANCE` without an explicit port.
class SqlBrowser {
  static const int defaultBrowserPort = 1434;

  /// Resolves [instanceName] through the Browser on [host].
  ///
  /// The returned address is the Browser endpoint that supplied [port]. Use it
  /// for the ensuing TCP dial, but retain [host] for TLS SNI and certificate
  /// validation.
  static Future<ResolvedSqlInstance> resolve(
    String host,
    String instanceName, {
    Duration timeout = const Duration(seconds: 3),
    int browserPort = defaultBrowserPort,
  }) async {
    if (instanceName.isEmpty) {
      throw ArgumentError('instanceName must not be empty');
    }

    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw MssqlException('SQL Browser: could not resolve host "$host"');
    }

    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    for (final browserAddress in addresses) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      try {
        final port = await _resolveAddress(
          browserAddress,
          instanceName,
          browserPort: browserPort,
          timeout: remaining,
        );
        return ResolvedSqlInstance(browserAddress, port);
      } catch (error) {
        lastError = error;
      }
    }

    throw MssqlException(
      'SQL Browser could not resolve $host\\$instanceName via UDP '
      '$browserPort${lastError == null ? '' : ': $lastError'}',
    );
  }

  /// Asks the Browser on [host] for the TCP port of [instanceName].
  ///
  /// Prefer [resolve] internally when the eventual TCP dial should reuse the
  /// exact address that answered discovery.
  static Future<int> resolveTcpPort(
    String host,
    String instanceName, {
    Duration timeout = const Duration(seconds: 3),
    int browserPort = defaultBrowserPort,
  }) async {
    return (await resolve(
      host,
      instanceName,
      timeout: timeout,
      browserPort: browserPort,
    ))
        .port;
  }

  static Future<int> _resolveAddress(
    InternetAddress browserAddress,
    String instanceName, {
    required int browserPort,
    required Duration timeout,
  }) async {
    final bindAddress = browserAddress.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4;
    final sock = await RawDatagramSocket.bind(bindAddress, 0);
    try {
      final request = buildClntUcastInst(instanceName);
      final sent = sock.send(request, browserAddress, browserPort);
      if (sent == 0) {
        throw MssqlException(
          'SQL Browser request could not be queued for '
          '${browserAddress.address}:$browserPort',
        );
      }

      final dg = await _receive(
        sock,
        expectedAddress: browserAddress,
        expectedPort: browserPort,
      ).timeout(timeout);
      return parseTcpPort(dg.data, expectedInstance: instanceName);
    } finally {
      sock.close();
    }
  }

  /// CLNT_UCAST_INST: `0x04` + instance name + NUL.
  static Uint8List buildClntUcastInst(String instanceName) {
    final name = utf8.encode(instanceName);
    return Uint8List.fromList([0x04, ...name, 0x00]);
  }

  /// Parses SVR_RESP (`0x05` + LE length + semicolon key/value pairs).
  static int parseTcpPort(
    Uint8List data, {
    String? expectedInstance,
  }) {
    if (data.length < 3 || data[0] != 0x05) {
      throw FormatException(
        'SQL Browser: expected SVR_RESP (0x05), got '
        '${data.isEmpty ? "empty" : "0x${data[0].toRadixString(16)}"}',
      );
    }
    final len = data[1] | (data[2] << 8);
    final start = 3;
    if (data.length != start + len) {
      throw FormatException(
        'SQL Browser: response length is $len bytes but received '
        '${data.length - start}',
      );
    }
    final text = utf8.decode(data.sublist(start));
    final fields = parseResponseFields(text);

    if (expectedInstance != null) {
      final got = fields['InstanceName'];
      if (got != null && got.toLowerCase() != expectedInstance.toLowerCase()) {
        throw MssqlException(
          'SQL Browser: expected instance "$expectedInstance", got "$got"',
        );
      }
    }

    final tcp = fields['tcp'];
    if (tcp == null || tcp.isEmpty) {
      throw MssqlException(
        'SQL Browser: no tcp port in response'
        '${expectedInstance == null ? "" : " for $expectedInstance"}',
      );
    }
    final port = int.tryParse(tcp);
    if (port == null || port <= 0 || port > 65535) {
      throw MssqlException('SQL Browser: invalid tcp port "$tcp"');
    }
    return port;
  }

  /// Splits `Key;Value;Key;Value;...` (and `;;`-separated instances) into a map.
  static Map<String, String> parseResponseFields(String text) {
    // CLNT_UCAST_INST returns a single instance block.
    final block = text.split(';;').first;
    final parts = block.split(';');
    final map = <String, String>{};
    for (var i = 0; i + 1 < parts.length; i += 2) {
      final k = parts[i].trim();
      final v = parts[i + 1].trim();
      if (k.isNotEmpty) map[k] = v;
    }
    return map;
  }

  static Future<Datagram> _receive(
    RawDatagramSocket sock, {
    required InternetAddress expectedAddress,
    required int expectedPort,
  }) {
    return _receiveLoop(sock, expectedAddress, expectedPort);
  }

  static Future<Datagram> _receiveLoop(
    RawDatagramSocket sock,
    InternetAddress expectedAddress,
    int expectedPort,
  ) async {
    await for (final event in sock) {
      if (event == RawSocketEvent.read) {
        Datagram? dg;
        while ((dg = sock.receive()) != null) {
          final received = dg!;
          if (received.port == expectedPort &&
              _sameAddress(received.address, expectedAddress)) {
            return received;
          }
        }
      }
      if (event == RawSocketEvent.closed) {
        throw MssqlException(
          'SQL Browser socket closed before receiving a response',
        );
      }
    }
    throw MssqlException(
        'SQL Browser socket ended before receiving a response');
  }

  static bool _sameAddress(InternetAddress a, InternetAddress b) {
    if (a.type != b.type || a.rawAddress.length != b.rawAddress.length) {
      return false;
    }
    for (var i = 0; i < a.rawAddress.length; i++) {
      if (a.rawAddress[i] != b.rawAddress[i]) return false;
    }
    return true;
  }
}

/// A named SQL Server instance endpoint resolved through SQL Browser.
class ResolvedSqlInstance {
  final InternetAddress address;
  final int port;

  const ResolvedSqlInstance(this.address, this.port);
}
