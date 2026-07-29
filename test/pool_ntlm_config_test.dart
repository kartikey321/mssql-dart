import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// Offline pool config coverage for NTLM / SSPI open path selection.
// Live domain NTLM still needs AD; this verifies config wiring only.
// Provenance: mirrors node-mssql pool auth options / go-mssqldb Windows auth.

void main() {
  group('MssqlPoolConfig NTLM', () {
    test('SQL auth leaves ntlmDomain null', () {
      const c = MssqlPoolConfig(
        host: 'localhost',
        user: 'sa',
        password: 'P@ssw0rd',
      );
      expect(c.ntlmDomain, isNull);
      expect(c.ntlmWorkstation, isNull);
    });

    test('ntlm factory sets domain and workstation', () {
      final c = MssqlPoolConfig.ntlm(
        host: 'sql.corp.example',
        port: 1433,
        domain: 'CORP',
        user: 'alice',
        password: 'SecREt01',
        workstation: 'DEVBOX',
        database: 'appdb',
        encrypt: false,
        trustServerCertificate: true,
        min: 1,
        max: 4,
        idleTimeout: const Duration(seconds: 10),
        acquireTimeout: const Duration(seconds: 5),
        connectionTimeout: const Duration(seconds: 20),
      );

      expect(c.host, 'sql.corp.example');
      expect(c.ntlmDomain, 'CORP');
      expect(c.ntlmWorkstation, 'DEVBOX');
      expect(c.user, 'alice');
      expect(c.password, 'SecREt01');
      expect(c.database, 'appdb');
      expect(c.encrypt, isFalse);
      expect(c.trustServerCertificate, isTrue);
      expect(c.min, 1);
      expect(c.max, 4);
      expect(c.idleTimeout, const Duration(seconds: 10));
      expect(c.acquireTimeout, const Duration(seconds: 5));
      expect(c.connectionTimeout, const Duration(seconds: 20));
    });

    test('direct ntlmDomain on const config', () {
      const c = MssqlPoolConfig(
        host: 'localhost',
        user: 'bob',
        password: 'x',
        ntlmDomain: 'CONTOSO',
        ntlmWorkstation: 'WS2',
      );
      expect(c.ntlmDomain, 'CONTOSO');
      expect(c.ntlmWorkstation, 'WS2');
    });

    test('MssqlPool holds NTLM config without opening', () {
      final pool = MssqlPool(MssqlPoolConfig.ntlm(
        host: 'localhost',
        domain: 'CORP',
        user: 'alice',
        password: 'secret',
      ));
      expect(pool.config.ntlmDomain, 'CORP');
      expect(pool, isA<MssqlPool>());
    });
  });
}
