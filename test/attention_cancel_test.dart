import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:mssql/src/tds/buf.dart';
import 'package:mssql/src/tds/constants.dart';
import 'package:mssql/src/tds/token_stream.dart';
import 'package:test/test.dart';

import 'helpers/tds_socket.dart';

/// Offline Attention / cancel protocol tests.
///
/// Sources:
/// - ms-tds §2.2.1.7 Attention, §2.2.7.6 DONE `doneAttn`
/// - microsoft/go-mssqldb attention / cancel patterns
Uint8List _doneAttn() {
  final out = BytesBuilder(copy: false);
  out.addByte(tokenDone);
  writeUint16LE(out, doneFlagAttn);
  writeUint16LE(out, 0);
  writeUint64LE(out, 0);
  return Uint8List.fromList(out.toBytes());
}

void main() {
  group('Attention cancel (mock server)', () {
    // Client sends Attention while blocked on query read; server ACKs with doneAttn
    test('sendAttention then DONE doneAttn completes processQueryResponse',
        () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final serverReader = ChunkedStreamReader(pair.server);
      final buf = TdsBuffer(pair.client);

      final queryFuture = TokenStream(buf).processQueryResponse();

      // Let the client block in beginRead awaiting a reply packet.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await buf.sendAttention();

      final hdr = await serverReader.readChunk(headerSize);
      expect(hdr[0], equals(packAttention));
      expect(hdr[1] & statusEOM, equals(statusEOM));
      final size = (hdr[2] << 8) | hdr[3];
      expect(size, equals(headerSize));

      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: _doneAttn()),
      );

      final result = await queryFuture.timeout(const Duration(seconds: 2));
      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
      expect(result.rowsAffected, equals(0));
    });

    // Server may send aborted-batch DONE then a separate Attention ACK message
    test('drains DONE then Attention ACK across two messages', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final buf = TdsBuffer(pair.client);

      final queryFuture = TokenStream(buf).processQueryResponse();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await buf.sendAttention();

      // 1) Normal final DONE (aborted batch) — no ATTN bit
      await tdsSend(
        pair.server,
        tdsPacket(
          type: packReply,
          body: () {
            final out = BytesBuilder(copy: false);
            out.addByte(tokenDone);
            writeUint16LE(out, doneFlagFinal);
            writeUint16LE(out, 0);
            writeUint64LE(out, 0);
            return out.toBytes();
          }(),
        ),
      );
      // 2) Attention acknowledgement
      await tdsSend(
        pair.server,
        tdsPacket(type: packReply, body: _doneAttn()),
      );

      final result = await queryFuture.timeout(const Duration(seconds: 2));
      expect(result.rows, isEmpty);
      expect(buf.attentionSent, isFalse);
    });

    test('streamQueryResponse completes on Attention ACK (two messages)',
        () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final buf = TdsBuffer(pair.client);

      final done = () async {
        await for (final _ in TokenStream(buf).streamQueryResponse()) {}
      }();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await buf.sendAttention();

      await tdsSend(
        pair.server,
        tdsPacket(
          type: packReply,
          body: () {
            final out = BytesBuilder(copy: false);
            out.addByte(tokenDone);
            writeUint16LE(out, doneFlagFinal);
            writeUint16LE(out, 0);
            writeUint64LE(out, 0);
            return out.toBytes();
          }(),
        ),
      );
      await tdsSend(pair.server, tdsPacket(type: packReply, body: _doneAttn()));

      await done.timeout(const Duration(seconds: 2));
      expect(buf.attentionSent, isFalse);
    });

    test('drainUntilAttentionAck after beginRead', () async {
      final pair = await TdsSocketPair.open();
      addTearDown(pair.close);
      final buf = TdsBuffer(pair.client);
      buf.attentionSent = true;

      await tdsSend(
        pair.server,
        tdsPacket(
          type: packReply,
          body: () {
            final out = BytesBuilder(copy: false);
            out.addByte(tokenDone);
            writeUint16LE(out, doneFlagFinal);
            writeUint16LE(out, 0);
            writeUint64LE(out, 0);
            return out.toBytes();
          }(),
        ),
      );
      await tdsSend(pair.server, tdsPacket(type: packReply, body: _doneAttn()));

      await buf.beginRead();
      await TokenStream(buf).drainUntilAttentionAck();
      expect(buf.attentionSent, isFalse);
    });
  });
}
