import 'dart:async';
import 'dart:io';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Offline tests for [MssqlTransient] and INFO/ERROR metadata.
///
/// Sources: go-mssqldb retryable errors; Azure transient error docs;
/// ms-tds INFO/ERROR token fields.
void main() {
  group('MssqlTransient.isTransient', () {
    test('deadlock 1205 is transient', () {
      expect(
        MssqlTransient.isTransient(const MssqlException('deadlock', errorCode: 1205)),
        isTrue,
      );
    });

    test('login failed 18456 is not transient', () {
      expect(
        MssqlTransient.isTransient(
          const MssqlException('Login failed', errorCode: 18456),
        ),
        isFalse,
      );
    });

    test('wrapped TCP connect failure is transient', () {
      expect(
        MssqlTransient.isTransient(
          const MssqlException('TCP connect failed: Connection refused'),
        ),
        isTrue,
      );
    });

    test('SocketException is transient', () {
      expect(
        MssqlTransient.isTransient(
          const SocketException('Connection reset by peer'),
        ),
        isTrue,
      );
    });

    test('TimeoutException is transient', () {
      expect(
        MssqlTransient.isTransient(TimeoutException('late')),
        isTrue,
      );
    });
  });

  group('MssqlTransient.retry', () {
    test('retries then succeeds', () async {
      var attempts = 0;
      final value = await MssqlTransient.retry(
        () async {
          attempts++;
          if (attempts < 3) {
            throw const MssqlException('deadlock', errorCode: 1205);
          }
          return 42;
        },
        retries: 3,
        delay: Duration.zero,
      );
      expect(value, equals(42));
      expect(attempts, equals(3));
    });

    test('does not retry non-transient errors', () async {
      var attempts = 0;
      await expectLater(
        () => MssqlTransient.retry(
          () async {
            attempts++;
            throw const MssqlException('bad login', errorCode: 18456);
          },
          retries: 3,
          delay: Duration.zero,
        ),
        throwsA(isA<MssqlException>().having((e) => e.errorCode, 'code', 18456)),
      );
      expect(attempts, equals(1));
    });
  });

  group('MssqlException metadata', () {
    test('carries state severity server proc line', () {
      const e = MssqlException(
        'boom',
        errorCode: 50000,
        severity: 16,
        state: 2,
        serverName: 'sql01',
        procName: 'dbo.p',
        lineNo: 12,
      );
      expect(e.severity, equals(16));
      expect(e.state, equals(2));
      expect(e.serverName, equals('sql01'));
      expect(e.procName, equals('dbo.p'));
      expect(e.lineNo, equals(12));
    });
  });
}
