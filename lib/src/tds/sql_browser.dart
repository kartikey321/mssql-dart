// Adapted from github.com/Alexqwesa/mssql-dart (MIT)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../exception.dart';

/// SQL Server Browser (SSRP) named-instance discovery client.
class SqlBrowser {
  static const int defaultPort = 1434;

  static Future<int> resolveTcpPort(
    String host,
    String instance, {
    Duration timeout = const Duration(seconds: 3),
    int browserPort = defaultPort,
    int retries = 1,
  }) async {
    if (instance.isEmpty) throw ArgumentError.value(instance, 'instance');
    // Resolved once and reused across retries: host never changes between
    // attempts, a retry exists to ride out a lost or delayed UDP packet
    // (not a flaky DNS answer), and re-resolving on every attempt risks a
    // different address answering a later retry than the one the caller
    // actually queried.
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw MssqlException('SQL Browser could not resolve host');
    }
    final address = addresses.first;
    Object? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      RawDatagramSocket? socket;
      try {
        socket = await RawDatagramSocket.bind(
            address.type == InternetAddressType.IPv6
                ? InternetAddress.anyIPv6
                : InternetAddress.anyIPv4,
            0);
        if (socket.send(buildRequest(instance), address, browserPort) == 0) {
          throw MssqlException('SQL Browser request could not be sent');
        }
        final reply = await socket
            .where((e) => e == RawSocketEvent.read)
            .expand((_) sync* {
              Datagram? d;
              while ((d = socket!.receive()) != null) {
                yield d!;
              }
            })
            // Only accept a reply from the address and port we queried, so a
            // spoofed UDP datagram from elsewhere on the network cannot
            // redirect the connection to an attacker-controlled port.
            .firstWhere((d) => d.address == address && d.port == browserPort)
            .timeout(timeout);
        return parseTcpPort(reply.data, expectedInstance: instance);
      } catch (e) {
        last = e;
      } finally {
        socket?.close();
      }
    }
    throw MssqlException('SQL Browser could not resolve named instance: $last');
  }

  static Uint8List buildRequest(String instance) =>
      Uint8List.fromList([4, ...utf8.encode(instance), 0]);

  static int parseTcpPort(Uint8List data, {required String expectedInstance}) {
    if (data.length < 3 || data[0] != 5) {
      throw FormatException('Invalid SQL Browser response');
    }
    final length = data[1] | (data[2] << 8);
    if (length != data.length - 3) {
      throw FormatException('Invalid SQL Browser response length');
    }
    final parts = utf8.decode(data.sublist(3)).split(';');
    final values = <String, String>{};
    for (var i = 0; i + 1 < parts.length; i += 2) {
      values[parts[i].toLowerCase()] = parts[i + 1];
    }
    final instance = values['instancename'];
    if (instance == null ||
        instance.toLowerCase() != expectedInstance.toLowerCase()) {
      throw MssqlException('SQL Browser returned a different instance');
    }
    final port = int.tryParse(values['tcp'] ?? '');
    if (port == null || port < 1 || port > 65535) {
      throw FormatException('Invalid SQL Browser tcp port');
    }
    return port;
  }
}
