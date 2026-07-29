import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// Offline pool config coverage for Azure AD FedAuth open path selection.
// Live Azure SQL still needs a real token/server; this verifies config wiring.
// Provenance: mirrors MssqlConnection.connectAzureAd / node-mssql azure-active-directory-*.

void main() {
  group('MssqlPoolConfig Azure AD', () {
    test('SQL auth leaves azureAdAuth null', () {
      const c = MssqlPoolConfig(
        host: 'localhost',
        user: 'sa',
        password: 'P@ssw0rd',
      );
      expect(c.azureAdAuth, isNull);
    });

    test('azureAd factory stores auth and forces encrypt', () {
      final auth = AzureAdAuth.fromToken('eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.x.y');
      final c = MssqlPoolConfig.azureAd(
        host: 'myserver.database.windows.net',
        azureAdAuth: auth,
        database: 'appdb',
        trustServerCertificate: false,
        min: 1,
        max: 4,
        idleTimeout: const Duration(seconds: 10),
        acquireTimeout: const Duration(seconds: 5),
        connectionTimeout: const Duration(seconds: 20),
      );

      expect(c.host, 'myserver.database.windows.net');
      expect(c.azureAdAuth, same(auth));
      expect(c.azureAdAuth!.bearerToken, startsWith('eyJ'));
      expect(c.encrypt, isTrue);
      expect(c.database, 'appdb');
      expect(c.ntlmDomain, isNull);
      expect(c.user, isEmpty);
      expect(c.password, isEmpty);
      expect(c.min, 1);
      expect(c.max, 4);
      expect(c.idleTimeout, const Duration(seconds: 10));
      expect(c.acquireTimeout, const Duration(seconds: 5));
      expect(c.connectionTimeout, const Duration(seconds: 20));
    });

    test('azureAd takes precedence field over ntlm when both set', () {
      final auth = AzureAdAuth.fromToken('tok');
      final c = MssqlPoolConfig(
        host: 'localhost',
        user: 'alice',
        password: 'x',
        azureAdAuth: auth,
        ntlmDomain: 'CORP',
      );
      expect(c.azureAdAuth, same(auth));
      expect(c.ntlmDomain, 'CORP');
      // Open path prefers azureAdAuth (see MssqlPool._openConnection).
    });

    test('MssqlPool holds Azure AD config without opening', () {
      final pool = MssqlPool(MssqlPoolConfig.azureAd(
        host: 'myserver.database.windows.net',
        azureAdAuth: AzureAdAuth.fromToken('tok'),
      ));
      expect(pool.config.azureAdAuth!.bearerToken, 'tok');
      expect(pool, isA<MssqlPool>());
    });
  });
}
