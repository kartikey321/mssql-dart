import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_tls_loader.dart';

final class _MssqlTlsConfig extends Struct {
  external Pointer<Utf8> serverName;
  external Pointer<Utf8> caFile;
  external Pointer<Utf8> caPath;
  @Int32()
  external int trustServerCertificate;
  @Int32()
  external int verifyHostname;
  @Size()
  external int maximumPlaintextPacket;
}

/// Result from an OpenSSL read/drain operation.
final class NativeTlsRead {
  final int code;
  final Uint8List bytes;

  const NativeTlsRead(this.code, this.bytes);
}

/// Result from accepting encrypted bytes into the native TLS BIO.
final class NativeTlsFeed {
  final int code;
  final int consumed;

  const NativeTlsFeed(this.code, this.consumed);
}

/// Synchronous native TLS operations owned exclusively by [NativeTlsTransport].
abstract interface class NativeTlsDriver {
  int handshake();
  NativeTlsFeed feedEncrypted(Uint8List bytes);
  NativeTlsRead drainEncrypted({int capacity = 16384});
  NativeTlsRead readPlaintext({int capacity = 16384});
  int writePacket(Uint8List packet);
  int retryWrite();
  bool get hasPendingWrite;
  Uint8List peerCertificateDer();
  void dispose();
}

/// Minimal FFI owner for one OpenSSL memory-BIO TLS session.
final class NativeTlsEngine implements Finalizable, NativeTlsDriver {
  static final _finalizer = NativeFinalizer(
    loadMssqlTls()
        .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'mssql_tls_destroy',
        )
        .cast(),
  );

  final DynamicLibrary _library;
  late final Pointer<Void> _handle;
  late final Pointer<NativeFunction<Void Function(Pointer<Void>)>> _destroy;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _feedEncrypted;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _drainEncrypted;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int) _writePacket;
  late final int Function(Pointer<Void>) _retryWrite;
  late final int Function(Pointer<Void>) _hasPendingWrite;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _readPlaintext;
  late final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>)
      _peerCertificateDer;

  NativeTlsEngine({
    required String serverName,
    required bool trustServerCertificate,
    String? trustedCertificateFile,
    String? trustedCertificateDirectory,
  }) : _library = loadMssqlTls() {
    final create = _library.lookupFunction<
        Pointer<Void> Function(Pointer<_MssqlTlsConfig>),
        Pointer<Void> Function(Pointer<_MssqlTlsConfig>)>('mssql_tls_create');
    final config = calloc<_MssqlTlsConfig>();
    final name = serverName.toNativeUtf8();
    final caFile = trustedCertificateFile?.toNativeUtf8() ?? nullptr;
    final caPath = trustedCertificateDirectory?.toNativeUtf8() ?? nullptr;
    try {
      config.ref
        ..serverName = name
        ..caFile = caFile
        ..caPath = caPath
        ..trustServerCertificate = trustServerCertificate ? 1 : 0
        ..verifyHostname = trustServerCertificate ? 0 : 1
        ..maximumPlaintextPacket = 16383;
      _handle = create(config);
      if (_handle == nullptr) {
        throw StateError('Unable to create native SQL Server TLS session.');
      }
      _destroy = _library.lookup('mssql_tls_destroy');
      _feedEncrypted = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_feed_encrypted');
      _drainEncrypted = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_drain_encrypted');
      _writePacket = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size),
          int Function(Pointer<Void>, Pointer<Uint8>, int)>(
        'mssql_tls_write_packet',
      );
      _retryWrite = _library.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('mssql_tls_retry_write');
      _hasPendingWrite = _library.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('mssql_tls_has_pending_write');
      _readPlaintext = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_read_plaintext');
      _peerCertificateDer = _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<IntPtr>),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              Pointer<IntPtr>)>('mssql_tls_peer_certificate_der');
      _finalizer.attach(this, _handle, detach: this);
    } finally {
      calloc.free(name);
      if (caFile != nullptr) calloc.free(caFile);
      if (caPath != nullptr) calloc.free(caPath);
      calloc.free(config);
    }
  }

  /// Starts or continues the TLS handshake. The caller drains ciphertext after.
  @override
  int handshake() => _library.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mssql_tls_handshake')(_handle);

  @override
  NativeTlsFeed feedEncrypted(Uint8List bytes) {
    final input = calloc<Uint8>(bytes.length);
    final consumed = calloc<IntPtr>();
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      final code = _feedEncrypted(_handle, input, bytes.length, consumed);
      return NativeTlsFeed(code, consumed.value);
    } finally {
      calloc.free(consumed);
      calloc.free(input);
    }
  }

  @override
  NativeTlsRead drainEncrypted({int capacity = 16384}) =>
      _read(_drainEncrypted, capacity);

  @override
  NativeTlsRead readPlaintext({int capacity = 16384}) =>
      _read(_readPlaintext, capacity);

  @override
  int writePacket(Uint8List packet) {
    final input = calloc<Uint8>(packet.length);
    try {
      input.asTypedList(packet.length).setAll(0, packet);
      return _writePacket(_handle, input, packet.length);
    } finally {
      calloc.free(input);
    }
  }

  @override
  int retryWrite() => _retryWrite(_handle);

  @override
  bool get hasPendingWrite => _hasPendingWrite(_handle) != 0;

  @override
  Uint8List peerCertificateDer() {
    final required = calloc<IntPtr>();
    try {
      final sizeCode = _peerCertificateDer(_handle, nullptr, 0, required);
      if (sizeCode != -3 || required.value == 0) return Uint8List(0);
      final output = calloc<Uint8>(required.value);
      try {
        final code =
            _peerCertificateDer(_handle, output, required.value, required);
        if (code != 0) {
          throw StateError('Unable to read peer certificate: $code.');
        }
        return Uint8List.fromList(output.asTypedList(required.value));
      } finally {
        calloc.free(output);
      }
    } finally {
      calloc.free(required);
    }
  }

  NativeTlsRead _read(
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<IntPtr>) call,
    int capacity,
  ) {
    final output = calloc<Uint8>(capacity);
    final written = calloc<IntPtr>();
    try {
      final code = call(_handle, output, capacity, written);
      return NativeTlsRead(
        code,
        Uint8List.fromList(output.asTypedList(written.value)),
      );
    } finally {
      calloc.free(written);
      calloc.free(output);
    }
  }

  @override
  void dispose() {
    _finalizer.detach(this);
    _destroy.asFunction<void Function(Pointer<Void>)>()(_handle);
  }
}
