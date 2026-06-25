import 'dart:typed_data';

import 'buf.dart';
import 'constants.dart';

/// Parameters for a LOGIN7 packet.
class LoginConfig {
  final String host;
  final String username;
  final String password;
  final String appName;
  final String serverName;
  final String database;
  final String language;
  final int packetSize;

  /// If set, SSPI (NTLM) bytes are sent instead of username/password.
  final Uint8List? sspi;

  /// If non-null, includes FedAuth feature extension with this bearer token.
  final String? fedAuthToken;

  const LoginConfig({
    required this.host,
    required this.username,
    required this.password,
    this.appName = 'mssql-dart',
    required this.serverName,
    this.database = '',
    this.language = '',
    this.packetSize = defaultPacketSize,
    this.sspi,
    this.fedAuthToken,
  });
}

/// Builds and sends the TDS LOGIN7 packet (ms-tds §2.2.6.3).
class Login7 {
  static Future<void> send(TdsBuffer buf, LoginConfig cfg) async {
    final hostBytes = _ucs2(cfg.host);
    final userBytes = _ucs2(cfg.username);
    final passBytes = _obfuscate(_ucs2(cfg.password));
    final appBytes = _ucs2(cfg.appName);
    final serverBytes = _ucs2(cfg.serverName);
    final dbBytes = _ucs2(cfg.database);
    final langBytes = _ucs2(cfg.language);
    final ctlIntBytes = _ucs2('');
    final sspiBytes = cfg.sspi ?? Uint8List(0);

    // Feature extensions
    final featBytes = _buildFeatureExt(cfg);
    final hasFeat = featBytes.isNotEmpty;

    // Fixed header is 94 bytes (loginHeader struct in go-mssqldb)
    const fixedHdr = 94;

    // Variable data layout: strings concatenated after fixed header
    int dataOffset = fixedHdr;
    // Helper to encode offset/length pairs
    int off = dataOffset;

    int hostOff = off;
    off += hostBytes.length;
    int userOff = off;
    off += userBytes.length;
    int passOff = off;
    off += passBytes.length;
    int appOff = off;
    off += appBytes.length;
    int serverOff = off;
    off += serverBytes.length;
    int ctlIntOff = off;
    off += ctlIntBytes.length;
    int langOff = off;
    off += langBytes.length;
    int dbOff = off;
    off += dbBytes.length;
    // ClientID: 6 bytes at fixed position (offset 86 in fixed header)
    int sspiOff = off;
    off += sspiBytes.length;
    int atchOff = off; // AtchDBFile – empty
    int chpwOff = off; // ChangePassword – empty
    int featOff = hasFeat ? off : 0;
    off += featBytes.length;

    final totalLength = off;

    buf.beginPacket(packLogin7);

    // Length (LE uint32) – total packet body length
    buf.writeUint32LE(totalLength);
    // TDS version
    buf.writeUint32LE(verTDS74);
    // PacketSize
    buf.writeUint32LE(cfg.packetSize);
    // ClientProgVer
    buf.writeUint32LE(0x01000000);
    // ClientPID
    buf.writeUint32LE(0);
    // ConnectionID
    buf.writeUint32LE(0);

    // OptionFlags1
    int opt1 = fUseDB | fSetLang;
    buf.writeUint8(opt1);

    // OptionFlags2
    int opt2 = cfg.sspi != null ? fIntSecurity : fODBC;
    buf.writeUint8(opt2);

    // TypeFlags
    buf.writeUint8(0);

    // OptionFlags3
    int opt3 = hasFeat ? fExtension : 0;
    buf.writeUint8(opt3);

    // ClientTimeZone (int32 LE) – local UTC offset in minutes
    buf.writeInt32LE(0);
    // ClientLCID
    buf.writeUint32LE(0x0409); // en-US

    // Variable-length field offset/length pairs (each 2+2 bytes, LE)
    _writeOffLen(buf, hostOff, hostBytes.length >> 1);
    _writeOffLen(buf, userOff, userBytes.length >> 1);
    _writeOffLen(buf, passOff, passBytes.length >> 1);
    _writeOffLen(buf, appOff, appBytes.length >> 1);
    _writeOffLen(buf, serverOff, serverBytes.length >> 1);
    // ExtensionOffset / ExtensionLength (pointer to feature ext block)
    _writeOffLen(buf, hasFeat ? featOff : 0, hasFeat ? featBytes.length : 0);
    _writeOffLen(buf, ctlIntOff, ctlIntBytes.length >> 1);
    _writeOffLen(buf, langOff, langBytes.length >> 1);
    _writeOffLen(buf, dbOff, dbBytes.length >> 1);

    // ClientID – 6 bytes (MAC address placeholder)
    buf.writeBytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

    // SSPI
    _writeOffLen(buf, sspiOff, sspiBytes.length);
    // AtchDBFile
    _writeOffLen(buf, atchOff, 0);
    // ChangePassword
    _writeOffLen(buf, chpwOff, 0);
    // SSPILongLength (uint32 – for SSPI > 65535; zero otherwise)
    buf.writeUint32LE(0);

    // Variable data
    buf.writeBytes(hostBytes);
    buf.writeBytes(userBytes);
    buf.writeBytes(passBytes);
    buf.writeBytes(appBytes);
    buf.writeBytes(serverBytes);
    buf.writeBytes(ctlIntBytes);
    buf.writeBytes(langBytes);
    buf.writeBytes(dbBytes);
    buf.writeBytes(sspiBytes);
    if (hasFeat) buf.writeBytes(featBytes);

    await buf.finishPacket(packLogin7);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Encode a string as UTF-16LE bytes.
  static Uint8List _ucs2(String s) {
    final codes = s.codeUnits;
    final out = Uint8List(codes.length * 2);
    for (int i = 0; i < codes.length; i++) {
      out[i * 2] = codes[i] & 0xFF;
      out[i * 2 + 1] = (codes[i] >> 8) & 0xFF;
    }
    return out;
  }

  /// Password obfuscation per ms-tds §2.2.6.3:
  /// For each byte: swap high/low nibbles first, then XOR with 0xA5.
  static Uint8List _obfuscate(Uint8List bytes) {
    final out = Uint8List(bytes.length);
    for (int i = 0; i < bytes.length; i++) {
      final swapped = ((bytes[i] & 0x0F) << 4) | ((bytes[i] & 0xF0) >> 4);
      out[i] = swapped ^ 0xA5;
    }
    return out;
  }

  static void _writeOffLen(TdsBuffer buf, int offset, int length) {
    buf.writeUint16LE(offset);
    buf.writeUint16LE(length);
  }

  static Uint8List _buildFeatureExt(LoginConfig cfg) {
    if (cfg.fedAuthToken == null) return Uint8List(0);

    final token = cfg.fedAuthToken!;
    final tokenBytes = _ucs2(token);

    // FedAuth security-token feature extension
    // options byte: library=SecurityToken (0x01) << 1 | fedAuthEcho=0
    final options = fedAuthLibSecurityToken << 1;

    final featureData = Uint8List(5 + tokenBytes.length);
    featureData[0] = options;
    // token length as LE uint32
    featureData[1] = tokenBytes.length & 0xFF;
    featureData[2] = (tokenBytes.length >> 8) & 0xFF;
    featureData[3] = (tokenBytes.length >> 16) & 0xFF;
    featureData[4] = (tokenBytes.length >> 24) & 0xFF;
    featureData.setRange(5, featureData.length, tokenBytes);

    // Feature block: featureID(1) + featureDataLen(4LE) + featureData + terminator
    final block = Uint8List(1 + 4 + featureData.length + 1);
    int i = 0;
    block[i++] = featExtFedAuth;
    block[i++] = featureData.length & 0xFF;
    block[i++] = (featureData.length >> 8) & 0xFF;
    block[i++] = (featureData.length >> 16) & 0xFF;
    block[i++] = (featureData.length >> 24) & 0xFF;
    block.setRange(i, i + featureData.length, featureData);
    i += featureData.length;
    block[i] = featExtTerminator;
    return block;
  }
}
