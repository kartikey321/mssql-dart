import 'dart:io';
import 'dart:math';

import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:test/test.dart';

// Property tests for TdsBuffer.tlsAlignPadBytes, the arithmetic behind the TLS
// record-wrap workaround (see lib/src/tds/constants.dart). No server needed.

/// Wire bytes of a message with [payload] payload bytes at [packetSize]: every
/// chunk carries at most packetSize - 8 payload bytes plus an 8-byte header.
int _wireBytes(int payload, int packetSize) {
  if (payload <= 0) return headerSize;
  final chunks =
      (payload + packetSize - headerSize - 1) ~/ (packetSize - headerSize);
  return payload + headerSize * chunks;
}

void main() {
  for (final packetSize in [512, 1024, 2048, 4096]) {
    test(
        'pad reaches an aligned end for every payload (packetSize $packetSize)',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientFuture =
          Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final peer = await server.first;
      final client = await clientFuture;
      final drained = peer.drain<void>();
      final buf = TdsBuffer(client, secureTransport: true)
        ..packetSize = packetSize;
      final rng = Random(packetSize);

      try {
        for (var round = 0; round < 40; round++) {
          // Move the sealed offset around with messages of random size.
          final n = rng.nextInt(3 * packetSize);
          buf.beginPacket(packSQLBatch);
          buf.writeBytes(List.filled(n, 0));
          await buf.finishPacket(packSQLBatch);

          for (var payload = 0; payload <= 3 * packetSize; payload += 1) {
            for (final step in [1, 2]) {
              final pad = buf.tlsAlignPadBytes(payload, step: step);
              final oddStream = (buf.sealedBytes + payload).isOdd;
              if (step == 1) {
                expect(pad, isNotNull,
                    reason: 'step 1 must always align '
                        '(sealed=${buf.sealedBytes} payload=$payload)');
              }
              if (pad == null) {
                // Only allowed when 2-byte padding cannot fix the parity.
                expect(step, equals(2));
                expect(oddStream, isTrue,
                    reason: 'null although parity allows alignment '
                        '(sealed=${buf.sealedBytes} payload=$payload)');
                continue;
              }
              expect(pad % step, equals(0));
              expect(
                  (buf.sealedBytes + _wireBytes(payload + pad, packetSize)) %
                      packetSize,
                  equals(0),
                  reason: 'sealed=${buf.sealedBytes} payload=$payload '
                      'step=$step pad=$pad');
              expect(pad, lessThan(packetSize + 2 * headerSize + 2));
            }
          }
        }
      } finally {
        await client.close();
        await drained;
        peer.destroy();
        await server.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('a buffer without TLS awareness never pads', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clientFuture =
        Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final peer = await server.first;
    final client = await clientFuture;
    final buf = TdsBuffer(client);
    expect(buf.tlsAlignPadBytes(123), equals(0));
    await client.close();
    peer.destroy();
    await server.close();
  });
}
