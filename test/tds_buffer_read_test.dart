import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

// TDS tokens are not aligned to packet boundaries: a server splits its reply
// into packets at the packet size, so a multi-byte field can straddle two
// packets. These tests feed TdsBuffer crafted packets over a loopback socket
// (no SQL Server needed).

Uint8List _packet(List<int> body, {required bool last, int seq = 1}) {
  final size = headerSize + body.length;
  return Uint8List.fromList([
    packReply,
    last ? statusEOM : statusNormal,
    (size >> 8) & 0xFF,
    size & 0xFF,
    0,
    0,
    seq,
    0,
    ...body,
  ]);
}

/// Serves [packets] to a TdsBuffer and returns it, plus a cleanup function.
Future<(TdsBuffer, Future<void> Function())> _bufferFed(
    List<Uint8List> packets) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clientFuture =
      Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final peer = await server.first;
  final client = await clientFuture;
  for (final p in packets) {
    peer.add(p);
  }
  await peer.flush();
  return (
    TdsBuffer(client),
    () async {
      client.destroy();
      peer.destroy();
      await server.close();
    }
  );
}

void main() {
  test('a uint32 split across two packets is read intact', () async {
    final (buf, done) = await _bufferFed([
      _packet([0xAA, 0x01], last: false),
      _packet([0x02, 0x03, 0x04, 0xBB], last: true, seq: 2),
    ]);
    try {
      await buf.beginRead();
      expect(await buf.readUint8(), equals(0xAA));
      // Only 1 byte (0x01) is left in this packet; the rest is in the next.
      expect(await buf.readUint32LE(), equals(0x04030201));
      expect(await buf.readUint8(), equals(0xBB));
    } finally {
      await done();
    }
  });

  test('a uint64 split across three packets is read intact', () async {
    final (buf, done) = await _bufferFed([
      _packet([1, 2, 3], last: false),
      _packet([4, 5], last: false, seq: 2),
      _packet([6, 7, 8], last: true, seq: 3),
    ]);
    try {
      await buf.beginRead();
      expect(await buf.readUint64LE(), equals(0x0807060504030201));
    } finally {
      await done();
    }
  });

  test('big-endian and 16-bit reads across a boundary', () async {
    final (buf, done) = await _bufferFed([
      _packet([0x11], last: false),
      _packet([0x22, 0x33], last: false, seq: 2),
      _packet([0x44, 0x55, 0x66], last: true, seq: 3),
    ]);
    try {
      await buf.beginRead();
      expect(await buf.readUint16BE(), equals(0x1122));
      expect(await buf.readUint16LE(), equals(0x4433));
      expect(await buf.readUint16BE(), equals(0x5566));
    } finally {
      await done();
    }
  });

  test('a truncated message still reports the stream ended', () async {
    final (buf, done) = await _bufferFed([
      _packet([1, 2], last: true),
    ]);
    try {
      await buf.beginRead();
      await expectLater(buf.readUint32LE(), throwsA(isA<StateError>()));
    } finally {
      await done();
    }
  });

  test('bytes left unread in one message are not leaked into the next',
      () async {
    final (buf, done) = await _bufferFed([
      _packet([9, 9, 9], last: true),
      _packet([1, 2, 3, 4], last: true),
    ]);
    try {
      await buf.beginRead();
      expect(await buf.readUint8(), equals(9)); // leave two bytes unread
      await buf.beginRead(); // next server message
      expect(await buf.readUint32LE(), equals(0x04030201));
    } finally {
      await done();
    }
  });
}
