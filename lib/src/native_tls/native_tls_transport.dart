import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'native_tls_engine.dart';

/// Post-handshake TLS transport backed by one serialized memory-BIO owner.
///
/// OpenSSL permits a write to need inbound TLS records. Consequently, reads and
/// writes must be progressed by one state machine: an Attention write cannot
/// await peer input while a separate task owns [NativeTlsDriver.feedEncrypted].
final class NativeTlsTransport {
  static const _ok = 0;
  static const _wantInput = 1;
  static const _wantOutput = 2;

  final Socket _socket;
  final ChunkedStreamReader<int> _reader;
  final NativeTlsDriver _engine;
  final StreamController<Uint8List> _plaintext = StreamController();
  final Queue<Uint8List> _incoming = Queue();
  final Queue<_WriteRequest> _urgentWrites = Queue();
  final Queue<_WriteRequest> _writes = Queue();

  _WriteRequest? _activeWrite;
  Future<void>? _readerTask;
  Future<void>? _runner;
  Object? _failure;
  StackTrace? _failureStack;
  var _closed = false;
  var _ended = false;

  NativeTlsTransport({
    required Socket socket,
    required ChunkedStreamReader<int> reader,
    required NativeTlsDriver engine,
  })  : _socket = socket,
        _reader = reader,
        _engine = engine;

  Stream<Uint8List> get plaintext => _plaintext.stream;

  /// DER-encoded leaf certificate from the completed TLS session.
  Uint8List peerCertificateDer() => _engine.peerCertificateDer();

  void start() => _readerTask ??= _readCiphertext();

  Future<void> writePacket(Uint8List packet, {bool urgent = false}) {
    _checkOpen();
    final request = _WriteRequest(Uint8List.fromList(packet));
    (urgent ? _urgentWrites : _writes).add(request);
    _schedule();
    return request.done.future;
  }

  Future<void> _readCiphertext() async {
    try {
      await for (final chunk in _reader.readStream(0x7fffffff)) {
        if (chunk.isEmpty) continue;
        _incoming.add(Uint8List.fromList(chunk));
        _schedule();
      }
      _ended = true;
      _schedule();
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  void _schedule() {
    if (_runner != null || _closed || _failure != null) return;
    _runner = _run().whenComplete(() {
      _runner = null;
      // Input can arrive in the tiny gap while the previous runner is still
      // completing. Schedule it again so a WANT_INPUT write never strands
      // queued peer ciphertext.
      if (_incoming.isNotEmpty && !_closed) _schedule();
    });
  }

  Future<void> _run() async {
    try {
      while (!_closed) {
        var progressed = false;

        while (_incoming.isNotEmpty) {
          final input = _incoming.removeFirst();
          final feed = _engine.feedEncrypted(input);
          if (feed.consumed < 0 || feed.consumed > input.length) {
            throw StateError(
              'Native TLS reported an invalid input count: ${feed.consumed}.',
            );
          }
          _checkResult(feed.code, 'TLS input');
          progressed = true;
          await _flushCiphertext();
          _emitPlaintext();
          if (feed.consumed < input.length) {
            if (feed.consumed == 0) {
              throw StateError('Native TLS accepted no encrypted input bytes.');
            }
            _incoming.addFirst(Uint8List.sublistView(input, feed.consumed));
          }
        }

        final active = _activeWrite ??= _takeWrite();
        if (active != null) {
          var code = _engine.hasPendingWrite
              ? _engine.retryWrite()
              : _engine.writePacket(active.packet);
          await _flushCiphertext();
          _emitPlaintext();
          // A memory-BIO write may report WANT_READ before the ciphertext it
          // produced is flushed. Retry once after that local progress; later
          // WANT_READ states wait for the reader to queue peer records.
          if (code == _wantInput || code == _wantOutput) {
            code = _engine.retryWrite();
            await _flushCiphertext();
            _emitPlaintext();
          }
          progressed = true;
          if (code == _ok) {
            _activeWrite = null;
            active.done.complete();
            continue;
          }
          if (code != _wantInput && code != _wantOutput) {
            _checkResult(code, 'TLS packet write');
          }
          // WANT_INPUT has no local progress until the reader queues bytes.
          // WANT_OUTPUT has already been drained; retry only after new work.
          break;
        }

        await _flushCiphertext();
        _emitPlaintext();
        if (!progressed) break;
      }
      if (_ended && _activeWrite == null && _incoming.isEmpty) {
        _fail(StateError('TLS peer closed while the connection was active.'),
            StackTrace.current);
      }
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  _WriteRequest? _takeWrite() => _urgentWrites.isNotEmpty
      ? _urgentWrites.removeFirst()
      : (_writes.isNotEmpty ? _writes.removeFirst() : null);

  Future<void> _flushCiphertext() async {
    var wrote = false;
    while (true) {
      final read = _engine.drainEncrypted();
      _checkResult(read.code, 'TLS ciphertext drain', allowWant: true);
      if (read.bytes.isEmpty) break;
      _socket.add(read.bytes);
      wrote = true;
    }
    if (wrote) await _socket.flush();
  }

  void _emitPlaintext() {
    while (true) {
      final read = _engine.readPlaintext();
      _checkResult(read.code, 'TLS plaintext read', allowWant: true);
      if (read.bytes.isEmpty) break;
      _plaintext.add(read.bytes);
    }
  }

  void _checkResult(int code, String operation, {bool allowWant = false}) {
    if (code == _ok ||
        (allowWant && (code == _wantInput || code == _wantOutput))) {
      return;
    }
    throw StateError('$operation failed with native result $code.');
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_failure != null) return;
    _failure = error;
    _failureStack = stackTrace;
    _closed = true;
    _activeWrite?.done.completeError(error, stackTrace);
    _activeWrite = null;
    for (final request in [..._urgentWrites, ..._writes]) {
      request.done.completeError(error, stackTrace);
    }
    _urgentWrites.clear();
    _writes.clear();
    _engine.dispose();
    _plaintext.addError(error, stackTrace);
    unawaited(_plaintext.close());
    unawaited(_socket.close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final error = StateError('Native TLS transport is closed.');
    _activeWrite?.done.completeError(error);
    for (final request in [..._urgentWrites, ..._writes]) {
      request.done.completeError(error);
    }
    _engine.dispose();
    await _plaintext.close();
    await _socket.close();
  }

  void _checkOpen() {
    if (_closed) {
      Error.throwWithStackTrace(
        _failure ?? StateError('Native TLS transport is closed.'),
        _failureStack ?? StackTrace.current,
      );
    }
  }
}

final class _WriteRequest {
  final Uint8List packet;
  final Completer<void> done = Completer<void>();

  _WriteRequest(this.packet);
}
