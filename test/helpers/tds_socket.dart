import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/src/tds/constants.dart';

/// Shared helpers for offline TDS protocol unit tests.
///
/// Pattern source: microsoft/go-mssqldb mock transports in `buf_test.go` /
/// `bad_server_test.go` (localhost socket pair instead of embedding a full
/// mock `io.ReadWriteCloser`). Also used by Tedious-style packet framing tests.
class TdsSocketPair {
  TdsSocketPair(this.client, this.server, this._listener);

  final Socket client;
  final Socket server;
  final ServerSocket _listener;

  static Future<TdsSocketPair> open() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clientFuture = Socket.connect(listener.address, listener.port);
    final server = await listener.first;
    final client = await clientFuture;
    return TdsSocketPair(client, server, listener);
  }

  Future<void> close() async {
    try {
      client.destroy();
    } catch (_) {}
    try {
      server.destroy();
    } catch (_) {}
    await _listener.close();
  }
}

/// Build a TDS packet: 8-byte header + [body].
/// Layout matches ms-tds §2.2.3.1 / go-mssqldb `header` + Tedious `Packet`.
Uint8List tdsPacket({
  required int type,
  required List<int> body,
  bool eom = true,
  int seq = 1,
}) {
  final total = headerSize + body.length;
  final pkt = Uint8List(total);
  pkt[0] = type;
  pkt[1] = eom ? statusEOM : statusNormal;
  pkt[2] = (total >> 8) & 0xFF;
  pkt[3] = total & 0xFF;
  pkt[4] = 0;
  pkt[5] = 0;
  pkt[6] = seq & 0xFF;
  pkt[7] = 0;
  pkt.setRange(headerSize, total, body);
  return pkt;
}

Future<void> tdsSend(Socket sock, Uint8List data) async {
  sock.add(data);
  await sock.flush();
}

/// Encode [s] as UTF-16LE (TDS UCS-2), same as go-mssqldb `str2ucs2`.
Uint8List ucs2(String s) {
  final out = Uint8List(s.length * 2);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    out[i * 2] = c & 0xFF;
    out[i * 2 + 1] = (c >> 8) & 0xFF;
  }
  return out;
}

/// LOGIN7 password obfuscation (ms-tds §2.2.6.3; go-mssqldb `manglePassword`).
Uint8List obfuscatePassword(Uint8List bytes) {
  final out = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final swapped = ((bytes[i] & 0x0F) << 4) | ((bytes[i] & 0xF0) >> 4);
    out[i] = swapped ^ 0xA5;
  }
  return out;
}

int readUint16LE(List<int> b, int offset) =>
    b[offset] | (b[offset + 1] << 8);

int readUint32LE(List<int> b, int offset) =>
    b[offset] |
    (b[offset + 1] << 8) |
    (b[offset + 2] << 16) |
    (b[offset + 3] << 24);

int readUint64LE(List<int> b, int offset) {
  final lo = readUint32LE(b, offset);
  final hi = readUint32LE(b, offset + 4);
  return lo | (hi << 32);
}

void writeUint16LE(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void writeUint32LE(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}

void writeUint64LE(BytesBuilder b, int v) {
  writeUint32LE(b, v & 0xFFFFFFFF);
  writeUint32LE(b, (v >> 32) & 0xFFFFFFFF);
}
