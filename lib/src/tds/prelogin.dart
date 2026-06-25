import 'dart:typed_data';

import 'buf.dart';
import 'constants.dart';

/// Result of the PRELOGIN exchange — what the server agreed to.
class PreloginResult {
  final int encryption; // one of the encryptXxx constants
  final bool fedAuthRequired;

  const PreloginResult(
      {required this.encryption, required this.fedAuthRequired});

  bool get requiresTls =>
      encryption == encryptOn || encryption == encryptRequired;
}

/// Sends the PRELOGIN packet and parses the server's PRELOGIN response.
///
/// ms-tds §2.2.6.4 / §2.2.6.5
class Prelogin {
  static const _clientVersion = [0x0E, 0x00, 0x06, 0xD0, 0x00, 0x00];

  /// Sends a PRELOGIN packet.
  ///
  /// [requestEncrypt]: the encryption byte to advertise.
  ///   - [encryptOn] (1): request TLS — required for production / Azure SQL.
  ///   - [encryptNotSupported] (2): client cannot do TLS — server skips it for
  ///     dev containers with default settings.
  static Future<void> send(
    TdsBuffer buf, {
    int requestEncrypt = encryptOn,
    bool fedAuthRequired = false,
  }) async {
    final fields = <int, List<int>>{
      preloginVersion: _clientVersion,
      preloginEncryption: [requestEncrypt],
      // INSTOPT: null-terminated instance name — empty means default instance.
      preloginInstopt: [0x00],
      // THREADID: client thread/process ID (4 bytes big-endian), zero is fine.
      preloginThreadId: [0x00, 0x00, 0x00, 0x00],
      preloginMars: [0x00],
      // TRACEID: 36 bytes (16-byte conn ID + 16-byte activity ID + 4-byte seq).
      preloginTraceId: List.filled(36, 0),
    };
    if (fedAuthRequired) {
      fields[preloginFedAuthRequired] = [0x01];
    }

    buf.beginPacket(packPrelogin);
    _writeFields(buf, fields);
    await buf.finishPacket(packPrelogin);
  }

  /// Reads the server's PRELOGIN response.
  static Future<PreloginResult> read(TdsBuffer buf) async {
    final pktType = await buf.beginRead();
    if (pktType != packReply) {
      throw StateError('Expected PRELOGIN response (type 4), got $pktType');
    }
    final data = await buf.readAll();
    final fields = _parseFields(data);

    final encByte = fields[preloginEncryption]?.first ?? encryptNotSupported;
    final fedAuth = (fields[preloginFedAuthRequired]?.first ?? 0) != 0;
    return PreloginResult(encryption: encByte, fedAuthRequired: fedAuth);
  }

  static void _writeFields(TdsBuffer buf, Map<int, List<int>> fields) {
    final keys = fields.keys.toList()..sort();

    // Header section: token(1) + offset(2BE) + length(2BE) per field, then terminator(1)
    int offset = keys.length * 5 + 1;
    for (final k in keys) {
      buf.writeByte(k);
      buf.writeUint16BE(offset);
      buf.writeUint16BE(fields[k]!.length);
      offset += fields[k]!.length;
    }
    buf.writeByte(preloginTerminator);

    // Value section
    for (final k in keys) {
      buf.writeBytes(fields[k]!);
    }
  }

  static Map<int, Uint8List> _parseFields(Uint8List data) {
    final result = <int, Uint8List>{};
    int i = 0;
    while (i < data.length) {
      final token = data[i];
      if (token == preloginTerminator) break;
      if (i + 5 > data.length) break;

      final offset = (data[i + 1] << 8) | data[i + 2];
      final length = (data[i + 3] << 8) | data[i + 4];
      i += 5;

      if (token != preloginTraceId && offset + length <= data.length) {
        result[token] =
            Uint8List.fromList(data.sublist(offset, offset + length));
      }
    }
    return result;
  }
}
