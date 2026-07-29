import 'package:mssql/src/native_tls/native_tls_loader.dart';
import 'package:test/test.dart';

void main() {
  group('native TLS library lookup', () {
    test('uses the Android linker name without desktop fallback paths', () {
      expect(nativeTlsLibraryName('android'), 'libmssql_tls.so');
      expect(
        nativeTlsLibraryCandidates(
          operatingSystem: 'android',
          currentDirectory: '/unused',
          pathSeparator: '/',
        ),
        ['libmssql_tls.so'],
      );
    });

    test('puts an explicit override before the Android linker name', () {
      expect(
        nativeTlsLibraryCandidates(
          operatingSystem: 'android',
          currentDirectory: '/unused',
          pathSeparator: '/',
          override: '/data/local/tmp/libmssql_tls.so',
        ),
        ['/data/local/tmp/libmssql_tls.so', 'libmssql_tls.so'],
      );
    });

    test('keeps the checked-out helper fallback for desktop development', () {
      expect(
        nativeTlsLibraryCandidates(
          operatingSystem: 'linux',
          currentDirectory: '/project',
          pathSeparator: '/',
        ),
        [
          'libmssql_tls.so',
          '/project/native/bin/linux-x64/libmssql_tls.so',
        ],
      );
    });
  });
}
