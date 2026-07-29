import 'dart:io';

import 'package:mssql/src/native_tls/native_tls_engine.dart';
import 'package:test/test.dart';

void main() {
  final supported =
      Platform.isWindows || Platform.isLinux || Platform.isAndroid;

  test(
    'native TLS engine emits a ClientHello',
    () {
      final engine = NativeTlsEngine(
        serverName: 'localhost',
        trustServerCertificate: true,
      );
      addTearDown(engine.dispose);

      final result = engine.handshake();
      expect(result, anyOf(1, 2, 3));
      final bytes = engine.drainEncrypted();
      expect(bytes.bytes, isNotEmpty);
      expect(bytes.bytes.first, 0x16);
    },
    skip: supported ? false : 'Native TLS is unsupported on this platform.',
  );
}
