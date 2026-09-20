import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'constants.dart';

/// Wraps a [Socket] and provides TDS packet framing for reads and writes.
///
/// TDS packets have an 8-byte header:
///   [0]   packet type
///   [1]   status (0x01 = last packet in message)
///   [2-3] total packet size (big-endian, including header)
///   [4-5] server process ID (SPID) – zero from client
///   [6]   packet sequence number (1-based, resets per message)
///   [7]   window (always 0)
class TdsBuffer {
  Socket _socket;
  int packetSize;

  // Single subscription to the socket stream – do not call _socket.listen again.
  ChunkedStreamReader<int> _reader;

  // Write state
  final _wbuf = BytesBuilder(copy: false);

  // TLS wrap-avoidance state (see constants.dart): true once writes go
  // through a SecureSocket; _sealedBytes counts plaintext bytes added to it.
  bool _tlsWrapAware;
  int _sealedBytes = 0;

  // Read state – filled one TDS packet at a time
  Uint8List _rbuf = Uint8List(0);
  int _rpos = 0;
  bool _rFinal = false;
  int _rPacketType = 0;

  /// Current transaction descriptor from server ENVCHANGE type 8.
  /// Sent in ALL_HEADERS; 0 = autocommit (no active transaction).
  int transactionDescriptor = 0;

  TdsBuffer(Socket socket,
      {this.packetSize = defaultPacketSize, bool secureTransport = false})
      : _socket = socket,
        _reader = ChunkedStreamReader(socket),
        _tlsWrapAware = secureTransport;

  /// The current stream reader. Used by the TLS bridge to keep a stable
  /// reference to the raw TCP reader before [replaceSocket] swaps it out.
  ChunkedStreamReader<int> get rawReader => _reader;

  /// Replace the underlying socket (called after TLS upgrade).
  void replaceSocket(Socket newSocket) {
    _socket = newSocket;
    _reader = ChunkedStreamReader(newSocket);
    // The new socket is a SecureSocket; its plaintext ring starts empty at
    // the midpoint, so the wrap-relative byte count starts from zero here.
    _tlsWrapAware = true;
    _sealedBytes = 0;
  }

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

    int offset = 0;
    int seq = 1;
    while (true) {
      final chunkLen = (body.length - offset).clamp(0, packetSize - headerSize);
      final isLast = offset + chunkLen >= body.length;
      final totalSize = headerSize + chunkLen;

      final pkt = Uint8List(totalSize);
      pkt[0] = packetType;
      pkt[1] = isLast ? statusEOM : statusNormal;
      pkt[2] = (totalSize >> 8) & 0xFF;
      pkt[3] = totalSize & 0xFF;
      pkt[4] = 0; // SPID hi
      pkt[5] = 0; // SPID lo
      pkt[6] = seq & 0xFF;
      pkt[7] = 0; // window

      pkt.setRange(headerSize, totalSize, body, offset);
      _socket.add(pkt);
      _sealedBytes += pkt.length;
      await _socket.flush();
      if (_tlsWrapAware && !isLast) {
        // Yield between chunks of a chained message so the SecureSocket's
        // SSL filter seals this packet before the next one is written.
        // Back-to-back chunk writes pile up in the filter's plaintext ring;
        // once the ring fills (8 KiB minus a byte), a write is deferred
        // mid-packet and its tail is sealed as a separate record, which the
        // server rejects. A real (not zero) delay gives the filter's
        // IOService dispatch time to drain the ring between chunks.
        await Future.delayed(const Duration(milliseconds: 1));
      }

      offset += chunkLen;
      seq++;
      if (isLast) break;
    }
    _wbuf.clear();
  }

  /// Whether writes go through a SecureSocket whose SSL filter needs
  /// wrap-aware message alignment (see [tlsAlignPadBytes]).
  bool get tlsWrapAware => _tlsWrapAware;

  /// Plaintext bytes sealed so far (post-handshake); used to keep message
  /// ends aligned to TLS record wrap boundaries.
  int get sealedBytes => _sealedBytes;

  /// Bytes accumulated for the message currently being built (excluding the
  /// reserved packet header). Used to measure a message before sending.
  int get pendingPayloadBytes => _wbuf.length - headerSize;

  /// Extra padding bytes needed so that a message with [payloadBytes] of
  /// payload ends exactly on a [packetSize] multiple of the sealed stream,
  /// keeping every TLS record wrap boundary coincident with a TDS packet
  /// boundary (see constants.dart).
  ///
  /// [step] is the padding granularity in bytes: 2 for UCS-2 text padding
  /// (spaces), 1 when the carrier can hold any byte count (e.g. a
  /// varbinary(max) parameter value). Returns null when no padding at this
  /// granularity can reach an aligned end (odd-parity payload with step 2);
  /// with step 1 an answer always exists.
  int? tlsAlignPadBytes(int payloadBytes, {int step = 2}) {
    if (!_tlsWrapAware) return 0;
    final int p = packetSize;
    int messageTotal(int q) {
      if (q <= 0) return headerSize;
      final chunks = 1 + (q - 1) ~/ (p - headerSize);
      return q + headerSize * chunks;
    }

    for (var delta = 0; delta <= p + 2 * headerSize + 2; delta += step) {
      if ((_sealedBytes + messageTotal(payloadBytes + delta)) % p == 0) {
        return delta;
      }
    }
    return null;
  }

  // ── Read API ───────────────────────────────────────────────────────────────

  /// Read the next TDS packet off the wire and fill [_rbuf].
  ///
  /// With [carry], bytes not yet consumed from the current packet are kept in
  /// front of the new packet's body. Tokens are not aligned to packet
  /// boundaries, so a multi-byte field can straddle two packets and must not
  /// lose its leading bytes.
  Future<void> _readNextPacket({bool carry = false}) async {
    final hdr = await _reader.readChunk(headerSize);
    if (hdr.length < headerSize) {
      throw StateError('Connection closed mid-header');
    }

    _rPacketType = hdr[0];
    final status = hdr[1];
    final size = (hdr[2] << 8) | hdr[3];
    _rFinal = (status & statusEOM) != 0;

    final bodyLen = size - headerSize;
    final body = bodyLen > 0
        ? Uint8List.fromList(await _reader.readChunk(bodyLen))
        : Uint8List(0);

    final remaining = carry ? _rbuf.length - _rpos : 0;
    if (remaining > 0) {
      final merged = Uint8List(remaining + body.length)
        ..setRange(0, remaining, _rbuf, _rpos)
        ..setRange(remaining, remaining + body.length, body);
      _rbuf = merged;
    } else {
      _rbuf = body;
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
    if (parts.length == 1) return parts[0];
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final out = Uint8List(total);
    int offset = 0;
    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }

  /// Reads exactly [n] raw bytes directly from the underlying stream,
  /// bypassing TDS packet framing. Used only during the TLS handshake bridge.
  /// Returns null if the stream closes.
  Future<Uint8List?> readBytesRaw(int n) async {
    try {
      final chunk = await _reader.readChunk(n);
      if (chunk.length < n) return null;
      return Uint8List.fromList(chunk);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureBytes(int n) async {
    while (_rbuf.length - _rpos < n) {
      if (_rFinal) throw StateError('TDS stream ended unexpectedly');
      await _readNextPacket(carry: true);
    }
  }
}
