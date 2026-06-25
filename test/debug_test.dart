import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/src/tds/constants.dart';

void main() async {
  print('1. Connecting TCP...');
  final socket = await Socket.connect('127.0.0.1', 14330);
  print('   TCP connected');

  final reader = ChunkedStreamReader<int>(socket);

  // Helper to read exactly n raw bytes
  Future<Uint8List> readRaw(int n) async {
    final chunk = await reader.readChunk(n);
    return Uint8List.fromList(chunk);
  }

  // Helper to read one TDS packet: returns (type, body)
  Future<(int, Uint8List)> readPacket() async {
    final hdr = await readRaw(8);
    final type = hdr[0];
    final size = (hdr[2] << 8) | hdr[3];
    final body = size > 8 ? await readRaw(size - 8) : Uint8List(0);
    print('   ← packet type=$type size=$size body=${body.length}b');
    return (type, body);
  }

  // Helper to send one TDS packet
  void sendPacket(int type, List<int> body) {
    final size = 8 + body.length;
    final pkt = Uint8List(size);
    pkt[0] = type;
    pkt[1] = 0x01; // EOM
    pkt[2] = (size >> 8) & 0xFF;
    pkt[3] = size & 0xFF;
    pkt[6] = 1; // seq
    pkt.setRange(8, size, body);
    socket.add(pkt);
    print('   → packet type=$type size=$size');
  }

  // ── PRELOGIN ──────────────────────────────────────────────────────────────
  // Fields: VERSION(0) ENCRYPTION(1) INSTOPT(2) THREADID(3) MARS(4) TRACEID(5)
  // Header: 6 fields × 5 bytes + 1 terminator = 31 bytes
  // Values start at offset 31:
  //   VERSION    off=31 len=6  → ends at 37
  //   ENCRYPTION off=37 len=1  → ends at 38
  //   INSTOPT    off=38 len=1  → ends at 39
  //   THREADID   off=39 len=4  → ends at 43
  //   MARS       off=43 len=1  → ends at 44
  //   TRACEID    off=44 len=36 → ends at 80
  print('2. Sending PRELOGIN (encrypt=NOT_SUP)...');
  final preloginBody = <int>[
    // Header entries (token, offsetHi, offsetLo, lenHi, lenLo)
    0x00, 0x00, 0x1F, 0x00, 0x06, // VERSION:    offset=31, len=6
    0x01, 0x00, 0x25, 0x00, 0x01, // ENCRYPTION: offset=37, len=1
    0x02, 0x00, 0x26, 0x00, 0x01, // INSTOPT:    offset=38, len=1
    0x03, 0x00, 0x27, 0x00, 0x04, // THREADID:   offset=39, len=4
    0x04, 0x00, 0x2B, 0x00, 0x01, // MARS:       offset=43, len=1
    0x05, 0x00, 0x2C, 0x00, 0x24, // TRACEID:    offset=44, len=36
    0xFF,                          // TERMINATOR
    // Values
    0x0E, 0x00, 0x06, 0xD0, 0x00, 0x00, // VERSION = 14.0.1744.0
    0x02,                                  // ENCRYPTION = NOT_SUPPORTED (0x02)
    0x00,                                  // INSTOPT = default instance
    0x00, 0x00, 0x00, 0x00,               // THREADID = 0
    0x00,                                  // MARS = off
    // TRACEID = 36 zero bytes (conn ID 16b + activity ID 16b + seq 4b)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
  ];
  sendPacket(packPrelogin, preloginBody);
  await socket.flush();

  print('3. Reading PRELOGIN response...');
  final (rType, rBody) = await readPacket();
  print('   type=$rType body=${rBody.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

  // Parse encryption byte from response
  int encByte = 2; // default: not supported
  int i = 0;
  while (i < rBody.length) {
    final tok = rBody[i];
    if (tok == 0xFF) break;
    if (i + 4 >= rBody.length) break;
    final off = (rBody[i + 1] << 8) | rBody[i + 2];
    // ignore: unused_local_variable
    final len = (rBody[i + 3] << 8) | rBody[i + 4];
    i += 5;
    if (tok == 0x01 && off < rBody.length) {
      encByte = rBody[off];
    }
  }
  print('   Server encryption byte: $encByte');

  // ── LOGIN7 ────────────────────────────────────────────────────────────────
  print('4. Sending LOGIN7...');
  final login7 = _buildLogin7('127.0.0.1', 'sa', 'Knex_Test1!', 'master');
  sendPacket(packLogin7, login7);
  await socket.flush();

  print('5. Reading login response...');
  // Read until DONE token
  outer:
  while (true) {
    final hdr = await readRaw(8);
    final pktType = hdr[0];
    final pktSize = (hdr[2] << 8) | hdr[3];
    final body = pktSize > 8 ? await readRaw(pktSize - 8) : Uint8List(0);
    print('   ← pkt type=$pktType size=$pktSize');

    // Walk tokens in body
    int pos = 0;
    while (pos < body.length) {
      final tok = body[pos++];
      print('     token=0x${tok.toRadixString(16)}');
      if (tok == 0xFD || tok == 0xFE || tok == 0xFF) {
        print('     → DONE token — login complete');
        break outer;
      } else if (tok == 0xAA || tok == 0xAB) {
        // Error (0xAA) or Info (0xAB)
        // Structure: length(2LE) number(4LE) state(1) class(1) msgLen(2LE) msgText(msgLen*2 UTF-16LE) ...
        final len = body[pos] | (body[pos + 1] << 8);
        pos += 2;
        final number = body[pos] | (body[pos+1]<<8) | (body[pos+2]<<16) | (body[pos+3]<<24);
        final state = body[pos + 4];
        final cls = body[pos + 5];
        final msgLen = body[pos + 6] | (body[pos + 7] << 8);
        final msgBytes = body.sublist(pos + 8, pos + 8 + msgLen * 2);
        final msg = String.fromCharCodes([for (int j = 0; j < msgBytes.length; j += 2) msgBytes[j] | (msgBytes[j + 1] << 8)]);
        print('     ${tok == 0xAA ? "ERROR" : "INFO"} #$number class=$cls state=$state msg="$msg"');
        pos += len;
      } else {
        // Unknown token — can't parse, stop
        print('     (unknown token, stopping parse)');
        break outer;
      }
    }

    if ((hdr[1] & 0x01) != 0) break; // EOM
  }

  await socket.close();
  print('Done.');
}

Uint8List _buildLogin7(String server, String user, String pass, String db) {
  Uint8List ucs2(String s) {
    final out = Uint8List(s.length * 2);
    for (int i = 0; i < s.length; i++) {
      out[i * 2] = s.codeUnitAt(i) & 0xFF;
      out[i * 2 + 1] = (s.codeUnitAt(i) >> 8) & 0xFF;
    }
    return out;
  }

  Uint8List obfuscate(Uint8List b) {
    final out = Uint8List(b.length);
    for (int i = 0; i < b.length; i++) {
      // TDS: swap nibbles first, then XOR with 0xA5
      final swapped = ((b[i] & 0x0F) << 4) | ((b[i] & 0xF0) >> 4);
      out[i] = swapped ^ 0xA5;
    }
    return out;
  }

  void u32le(BytesBuilder b, int v) {
    b.addByte(v & 0xFF); b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF); b.addByte((v >> 24) & 0xFF);
  }
  void u16le(BytesBuilder b, int v) {
    b.addByte(v & 0xFF); b.addByte((v >> 8) & 0xFF);
  }

  final hostB = ucs2(server);
  final userB = ucs2(user);
  final passB = obfuscate(ucs2(pass));
  final appB  = ucs2('mssql-dart-debug');
  final srvB  = ucs2(server);
  final dbB   = ucs2(db);
  final ctlB  = ucs2('');
  final langB = ucs2('');

  const fixed = 94;
  int off = fixed;
  final hostOff = off; off += hostB.length;
  final userOff = off; off += userB.length;
  final passOff = off; off += passB.length;
  final appOff  = off; off += appB.length;
  final srvOff  = off; off += srvB.length;
  final ctlOff  = off; off += ctlB.length;
  final langOff = off; off += langB.length;
  final dbOff   = off; off += dbB.length;
  final total = off;

  final b = BytesBuilder();
  u32le(b, total);          // Length
  u32le(b, 0x74000004);     // TDS 7.4
  u32le(b, 4096);           // PacketSize
  u32le(b, 0x01000000);     // ClientProgVer
  u32le(b, 0);              // ClientPID
  u32le(b, 0);              // ConnectionID
  b.addByte(0x20 | 0x80);   // OptionFlags1: fUseDB | fSetLang
  b.addByte(0x02);          // OptionFlags2: fODBC
  b.addByte(0);             // TypeFlags
  b.addByte(0);             // OptionFlags3
  u32le(b, 0);              // ClientTimeZone
  u32le(b, 0x0409);         // ClientLCID en-US

  void secBuf(int o, int l) { u16le(b, o); u16le(b, l); }
  secBuf(hostOff, hostB.length >> 1);
  secBuf(userOff, userB.length >> 1);
  secBuf(passOff, passB.length >> 1);
  secBuf(appOff,  appB.length >> 1);
  secBuf(srvOff,  srvB.length >> 1);
  secBuf(0, 0);             // ExtensionOffset / ExtensionLength
  secBuf(ctlOff,  0);
  secBuf(langOff, 0);
  secBuf(dbOff,   dbB.length >> 1);
  b.add([0, 0, 0, 0, 0, 0]); // ClientID
  secBuf(0, 0);             // SSPI
  secBuf(0, 0);             // AtchDBFile
  secBuf(0, 0);             // ChangePassword
  u32le(b, 0);              // SSPILongLength

  b.add(hostB); b.add(userB); b.add(passB);
  b.add(appB);  b.add(srvB);  b.add(ctlB);
  b.add(langB); b.add(dbB);
  return b.toBytes();
}
