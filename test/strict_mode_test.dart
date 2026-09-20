import 'dart:async';
import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// Strict mode (TDS 8.0) checks that need no SQL Server. Full-handshake
// coverage needs a server with a trusted certificate and is not included.

Future<MssqlConnection> _strict({
  required int port,
  bool trustServerCertificate = false,
}) =>
    MssqlConnection.connect(
      host: '127.0.0.1',
      port: port,
      user: 'sa',
      password: 'pw',
      encryptMode: MssqlEncryptMode.strict,
      trustServerCertificate: trustServerCertificate,
      timeout: const Duration(seconds: 5),
    );

void main() {
  group('MssqlEncryptMode.strict', () {
    test('rejects trustServerCertificate: true before connecting', () async {
      // Port 1 has no listener: the check must fail first, not with a
      // connection error.
      await expectLater(
        _strict(port: 1, trustServerCertificate: true),
        throwsA(isA<MssqlException>().having(
            (e) => e.message, 'message', contains('trustServerCertificate'))),
      );
    });

    test('rejects trustServerCertificate: true via the pool config too',
        () async {
      final pool = MssqlPool(MssqlPoolConfig(
        host: '127.0.0.1',
        port: 1,
        user: 'sa',
        password: 'pw',
        encryptMode: MssqlEncryptMode.strict,
        trustServerCertificate: true,
        min: 0,
        max: 1,
      ));
      await expectLater(
        pool.query('SELECT 1'),
        throwsA(isA<MssqlException>()),
      );
      await pool.close();
    });

    test('fails when the server does not speak TLS first', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen((s) {
        sockets.add(s);
        s.add(List.filled(64, 0)); // not a TLS ServerHello
      });
      try {
        await expectLater(_strict(port: server.port), throwsA(anything));
      } finally {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      }
    });
  });
}
