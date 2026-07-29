import 'dart:io';
import 'dart:typed_data';

import '../native_tls/native_tls_transport.dart';

/// Byte transport below TDS framing.
///
/// Implementations own their encryption boundary; [writePacket] receives one
/// complete TDS packet and must not split it into separate logical writes.
abstract interface class TdsTransport {
  bool get isEncrypted;

  Stream<Uint8List> get incoming;

  Future<void> writePacket(Uint8List packet, {bool urgent = false});

  Future<void> writePackets(List<Uint8List> packets, {bool urgent = false});

  Future<void> close();
}

/// Cleartext transport used when SQL Server TLS is disabled.
final class SocketTdsTransport implements TdsTransport {
  final Socket socket;

  SocketTdsTransport(this.socket);

  @override
  bool get isEncrypted => false;

  @override
  Stream<Uint8List> get incoming => socket.map(Uint8List.fromList);

  @override
  Future<void> writePacket(Uint8List packet, {bool urgent = false}) async {
    socket.add(packet);
    await socket.flush();
  }

  @override
  Future<void> writePackets(List<Uint8List> packets, {bool urgent = false}) async {
    for (final packet in packets) {
      await writePacket(packet, urgent: urgent);
    }
  }

  @override
  Future<void> close() => socket.close();
}

/// Native OpenSSL transport adapter used after SQL Server's TLS handshake.
final class NativeTlsTdsTransport implements TdsTransport {
  final NativeTlsTransport transport;

  NativeTlsTdsTransport(this.transport);

  @override
  bool get isEncrypted => true;

  @override
  Stream<Uint8List> get incoming => transport.plaintext;

  @override
  Future<void> writePacket(Uint8List packet, {bool urgent = false}) =>
      transport.writePacket(packet, urgent: urgent);

  @override
  Future<void> writePackets(List<Uint8List> packets, {bool urgent = false}) {
    final size = packets.fold<int>(0, (sum, packet) => sum + packet.length);
    if (size <= 16383) {
      final message = Uint8List(size);
      var offset = 0;
      for (final packet in packets) {
        message.setRange(offset, offset + packet.length, packet);
        offset += packet.length;
      }
      return transport.writePacket(message, urgent: urgent);
    }
    return _writeIndividually(packets, urgent);
  }

  Future<void> _writeIndividually(List<Uint8List> packets, bool urgent) async {
    for (final packet in packets) {
      await transport.writePacket(packet, urgent: urgent);
    }
  }

  @override
  Future<void> close() => transport.close();
}
