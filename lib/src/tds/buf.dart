import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import '../protocol_limits.dart';
import 'constants.dart';
import 'transport.dart';

/// TDS packet framing over an interchangeable cleartext or TLS transport.
class TdsBuffer {
  late TdsTransport _transport;
  int packetSize;
  final MssqlProtocolLimits limits;

  // A single reader owns the incoming byte stream.
  ChunkedStreamReader<int> _reader;
  final _wbuf = BytesBuilder(copy: false);

  /// Set by [sendAttention]; cleared when an Attention DONE token is parsed.
  bool attentionSent = false;

  // Read state, populated one TDS packet at a time.
  Uint8List _rbuf = Uint8List(0);
  int _rpos = 0;
  bool _rFinal = false;
  int _rPacketType = 0;

  /// Current transaction descriptor from server ENVCHANGE type 8.
  int transactionDescriptor = 0;

  /// Applies RESETCONNECTION to the next SQL batch, RPC, or TM request.
  bool resetConnectionPending = false;

  TdsBuffer(
    Socket socket, {
    this.packetSize = defaultPacketSize,
    this.limits = const MssqlProtocolLimits(),
  }) : _reader = ChunkedStreamReader(socket) {
    _transport = SocketTdsTransport(socket);
  }

  /// The current raw reader, retained across the native TLS handshake.
  ChunkedStreamReader<int> get rawReader => _reader;

  /// Replaces packet I/O after the native TLS handshake.
  void replaceTransport(TdsTransport transport) {
    _transport = transport;
    _reader = ChunkedStreamReader(transport.incoming);
  }

  bool get isTls => _transport.isEncrypted;

  // ── Write API ──────────────────────────────────────────────────────────────

  void beginPacket(int type) {
    _wbuf.clear();
    // Reserve 8-byte header placeholder; filled in finishPacket.
    _wbuf.add(Uint8List(headerSize));
  }

  void writeByte(int b) => _wbuf.addByte(b & 0xFF);

  void writeBytes(List<int> bytes) => _wbuf.add(bytes);

  void writeUint8(int v) => _wbuf.addByte(v & 0xFF);

  void writeUint16LE(int v) {
    _wbuf.addByte(v & 0xFF);
    _wbuf.addByte((v >> 8) & 0xFF);
  }

  void writeUint16BE(int v) {
    _wbuf.addByte((v >> 8) & 0xFF);
    _wbuf.addByte(v & 0xFF);
  }

  void writeUint32LE(int v) {
    _wbuf.addByte(v & 0xFF);
    _wbuf.addByte((v >> 8) & 0xFF);
    _wbuf.addByte((v >> 16) & 0xFF);
    _wbuf.addByte((v >> 24) & 0xFF);
  }

  void writeUint32BE(int v) {
    _wbuf.addByte((v >> 24) & 0xFF);
    _wbuf.addByte((v >> 16) & 0xFF);
    _wbuf.addByte((v >> 8) & 0xFF);
    _wbuf.addByte(v & 0xFF);
  }

  void writeUint64LE(int v) {
    writeUint32LE(v & 0xFFFFFFFF);
    writeUint32LE((v >> 32) & 0xFFFFFFFF);
  }

  void writeInt16LE(int v) => writeUint16LE(v & 0xFFFF);

  void writeInt32LE(int v) => writeUint32LE(v & 0xFFFFFFFF);

  /// Flush the accumulated write buffer as one or more TDS packets.
  Future<void> finishPacket(int packetType) async {
    final payload = _wbuf.toBytes();
    // Body = everything after the 8-byte header placeholder.
    final body = payload.sublist(headerSize);

    // RESETCONNECTION only on first packet of Batch / RPC / TM request.
    final applyReset = resetConnectionPending &&
        (packetType == packSQLBatch ||
            packetType == packRPCRequest ||
            packetType == packTransMgrReq);
    final maxBody = packetSize - headerSize;
    int offset = 0;
    int seq = 1;
    while (true) {
      final remaining = body.length - offset;
      final isLast = remaining <= maxBody;
      final chunkLen = isLast ? remaining : maxBody;
      final totalSize = headerSize + chunkLen;

      final pkt = Uint8List(totalSize);
      pkt[0] = packetType;
      var status = isLast ? statusEOM : statusNormal;
      // ms-tds: RESETCONNECTION must be on the first packet of the message.
      if (applyReset && seq == 1) {
        status |= statusResetConn;
      }
      pkt[1] = status;
      pkt[2] = (totalSize >> 8) & 0xFF;
      pkt[3] = totalSize & 0xFF;
      pkt[4] = 0; // SPID hi
      pkt[5] = 0; // SPID lo
      pkt[6] = seq & 0xFF;
      pkt[7] = 0; // window

      if (chunkLen > 0) {
        pkt.setRange(headerSize, totalSize, body, offset);
      }

      await _transport.writePacket(pkt, urgent: packetType == packAttention);
      if (applyReset && seq == 1) {
        resetConnectionPending = false;
        transactionDescriptor = 0;
      }
      offset += chunkLen;
      seq++;
      if (isLast) break;
    }
    _wbuf.clear();
  }

  /// Sends a TDS Attention packet (ms-tds §2.2.1.7) — empty body, type 6.
  ///
  /// Safe to call while a read is in progress (write path is independent).
  /// The server acknowledges with DONE where [doneFlagAttn] is set.
  Future<void> sendAttention() async {
    attentionSent = true;
    beginPacket(packAttention);
    await finishPacket(packAttention);
  }

  // ── Read API ───────────────────────────────────────────────────────────────

  /// Read the next TDS packet off the wire and fill [_rbuf].
  Future<void> _readNextPacket() async {
    final hdr = await _reader.readChunk(headerSize);
    if (hdr.length < headerSize) {
      throw StateError('Connection closed mid-header');
    }

    _rPacketType = hdr[0];
    final status = hdr[1];
    final size = (hdr[2] << 8) | hdr[3];
    _rFinal = (status & statusEOM) != 0;

    if (size < headerSize) {
      throw FormatException(
        'TDS packet size $size is smaller than header size $headerSize',
      );
    }
    final bodyLen = size - headerSize;
    final newBody = bodyLen > 0
        ? Uint8List.fromList(await _reader.readChunk(bodyLen))
        : Uint8List(0);
    if (newBody.length < bodyLen) {
      throw StateError('Connection closed mid-packet body');
    }

    // Preserve unread bytes when a multi-byte read straddles a packet
    // boundary (go-mssqldb / PR #3). Without this, leftover bytes in
    // `_rbuf` are discarded and length prefixes / tokens desync.
    final remaining = _rbuf.length - _rpos;
    if (remaining > 0) {
      final merged = Uint8List(remaining + newBody.length);
      merged.setRange(0, remaining, _rbuf, _rpos);
      merged.setRange(remaining, remaining + newBody.length, newBody);
      _rbuf = merged;
    } else {
      _rbuf = newBody;
    }
    _rpos = 0;
  }

  /// Begin reading a new server message; returns the packet type of the first packet.
  Future<int> beginRead() async {
    await _readNextPacket();
    return _rPacketType;
  }

  Future<int> readUint8() async {
    await _ensureBytes(1);
    return _rbuf[_rpos++];
  }

  Future<int> readUint16LE() async {
    await _ensureBytes(2);
    final v = _rbuf[_rpos] | (_rbuf[_rpos + 1] << 8);
    _rpos += 2;
    return v;
  }

  Future<int> readUint16BE() async {
    await _ensureBytes(2);
    final v = (_rbuf[_rpos] << 8) | _rbuf[_rpos + 1];
    _rpos += 2;
    return v;
  }

  Future<int> readUint32LE() async {
    await _ensureBytes(4);
    final v = _rbuf[_rpos] |
        (_rbuf[_rpos + 1] << 8) |
        (_rbuf[_rpos + 2] << 16) |
        (_rbuf[_rpos + 3] << 24);
    _rpos += 4;
    return v;
  }

  Future<int> readUint32BE() async {
    await _ensureBytes(4);
    final v = (_rbuf[_rpos] << 24) |
        (_rbuf[_rpos + 1] << 16) |
        (_rbuf[_rpos + 2] << 8) |
        _rbuf[_rpos + 3];
    _rpos += 4;
    return v;
  }

  Future<int> readUint64LE() async {
    final lo = await readUint32LE();
    final hi = await readUint32LE();
    return lo | (hi << 32);
  }

  Future<int> readInt32LE() async {
    final v = await readUint32LE();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  Future<Uint8List> readBytes(int n) async {
    if (n < 0) throw FormatException('TDS read length is negative: $n');
    final out = Uint8List(n);
    int written = 0;
    while (written < n) {
      await _ensureBytes(1);
      final available = _rbuf.length - _rpos;
      final take = available < (n - written) ? available : (n - written);
      out.setRange(written, written + take, _rbuf, _rpos);
      _rpos += take;
      written += take;
    }
    return out;
  }

  /// Read all remaining bytes in the current server message (across packets).
  Future<Uint8List> readAll() async {
    final parts = <Uint8List>[];
    while (true) {
      final remaining = _rbuf.length - _rpos;
      if (remaining > 0) parts.add(Uint8List.sublistView(_rbuf, _rpos));
      _rpos = _rbuf.length;
      if (_rFinal) break;
      await _readNextPacket();
    }
    if (parts.isEmpty) return Uint8List(0);
    if (parts.length == 1) {
      limits.checkTokenBytes(parts[0].length, 'TDS message');
      return parts[0];
    }
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    limits.checkTokenBytes(total, 'TDS message');
    final out = Uint8List(total);
    int offset = 0;
    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }

  Future<void> _ensureBytes(int n) async {
    while (_rbuf.length - _rpos < n) {
      if (_rFinal) throw StateError('TDS stream ended unexpectedly');
      await _readNextPacket();
    }
  }
}
