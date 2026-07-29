import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

/// Connection string parse tests (ADO.NET + sqlserver:// URL).
///
/// Keyword aliases / formats: microsoft/go-mssqldb msdsn + ADO.NET docs.

void main() {
  group('ADO.NET keyword string', () {
    test('basic LAN SQL auth', () {
      final c = MssqlConnectionString.parse(
        'Server=10.0.0.5,1433;Database=app;User Id=sa;Password=secret;'
        'Encrypt=false;TrustServerCertificate=true;App Name=pos;',
      );
      expect(c.host, '10.0.0.5');
      expect(c.port, 1433);
      expect(c.database, 'app');
      expect(c.user, 'sa');
      expect(c.password, 'secret');
      expect(c.encrypt, isFalse);
      expect(c.trustServerCertificate, isTrue);
      expect(c.appName, 'pos');
      expect(c.useNtlm, isFalse);
    });

    test('synonyms Data Source / Initial Catalog / UID / PWD', () {
      final c = MssqlConnectionString.parse(
        'Data Source=sql01;Initial Catalog=db1;UID=u;PWD=p;Encrypt=no',
      );
      expect(c.host, 'sql01');
      expect(c.database, 'db1');
      expect(c.user, 'u');
      expect(c.password, 'p');
      expect(c.encrypt, isFalse);
    });

    test(r'named instance Server=host\INSTANCE', () {
      final c = MssqlConnectionString.parse(
        r'Server=sql01\SQLEXPRESS;User Id=sa;Password=x;Encrypt=false',
      );
      expect(c.host, 'sql01');
      expect(c.instanceName, 'SQLEXPRESS');
      expect(c.port, 1433);
    });

    test('tcp: prefix and separate Port', () {
      final c = MssqlConnectionString.parse(
        'Server=tcp:sql01;Port=15001;User Id=sa;Password=x',
      );
      expect(c.host, 'sql01');
      expect(c.port, 15001);
    });

    test(r'DOMAIN\user enables NTLM', () {
      final c = MssqlConnectionString.parse(
        r'Server=sql01;User Id=CONTOSO\bob;Password=pw;Encrypt=true',
      );
      expect(c.useNtlm, isTrue);
      expect(c.ntlmDomain, 'CONTOSO');
      expect(c.user, 'bob');
      expect(c.password, 'pw');
    });

    test('Trusted_Connection without DOMAIN\\user throws', () {
      expect(
        () => MssqlConnectionString.parse(
          'Server=sql01;Trusted_Connection=yes;User Id=sa;Password=x',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('braced password with semicolon', () {
      final c = MssqlConnectionString.parse(
        'Server=h;User Id=sa;Password={a;b;c};Database=d',
      );
      expect(c.password, 'a;b;c');
    });

    test('connection / query timeout seconds', () {
      final c = MssqlConnectionString.parse(
        'Server=h;User Id=sa;Password=x;'
        'Connection Timeout=20;Command Timeout=45',
      );
      expect(c.connectionTimeout, const Duration(seconds: 20));
      expect(c.queryTimeout, const Duration(seconds: 45));
    });

    test('Encrypt=disable', () {
      final c = MssqlConnectionString.parse(
        'Server=h;User Id=sa;Password=x;Encrypt=disable',
      );
      expect(c.encrypt, isFalse);
    });

    test('HostNameInCertificate', () {
      final c = MssqlConnectionString.parse(
        'Server=10.0.0.5;User Id=sa;Password=x;'
        'Encrypt=true;HostNameInCertificate=sql.contoso.local',
      );
      expect(c.hostNameInCertificate, 'sql.contoso.local');
    });

    test('PEM trust roots', () {
      final c = MssqlConnectionString.parse(
        'Server=sql01;User Id=sa;Password=x;'
        r'Trusted Certificate File=C:\certs\ca.pem;'
        r'Trusted Certificate Directory=C:\certs\roots',
      );
      expect(c.trustedCertificateFile, r'C:\certs\ca.pem');
      expect(c.trustedCertificateDirectory, r'C:\certs\roots');
    });

    test('sqlserver URL HostNameInCertificate', () {
      final c = MssqlConnectionString.parse(
        'sqlserver://sa:x@10.0.0.5:1433?'
        'encrypt=true&hostnameincertificate=sql.contoso.local',
      );
      expect(c.hostNameInCertificate, 'sql.contoso.local');
    });

    test('sqlserver URL PEM trust roots', () {
      final c = MssqlConnectionString.parse(
        'sqlserver://sa:x@sql01?cafile=%2Fetc%2Fssl%2Fca.pem'
        '&capath=%2Fetc%2Fssl%2Fcerts',
      );
      expect(c.trustedCertificateFile, '/etc/ssl/ca.pem');
      expect(c.trustedCertificateDirectory, '/etc/ssl/certs');
    });

    test('ApplicationIntent=ReadOnly requires Database', () {
      expect(
        () => MssqlConnectionString.parse(
          'Server=ag;User Id=sa;Password=x;ApplicationIntent=ReadOnly',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('ApplicationIntent + FailoverPartner + MultiSubnetFailover', () {
      final c = MssqlConnectionString.parse(
        'Server=ag-listener;Database=app;User Id=sa;Password=x;'
        'ApplicationIntent=ReadOnly;Failover Partner=sql-mirror;'
        'Failover Port=1434;MultiSubnetFailover=true;Encrypt=false',
      );
      expect(c.readOnlyIntent, isTrue);
      expect(c.failoverPartner, 'sql-mirror');
      expect(c.failoverPort, 1434);
      expect(c.multiSubnetFailover, isTrue);
      expect(c.database, 'app');
    });

    test('sqlserver URL ApplicationIntent', () {
      final c = MssqlConnectionString.parse(
        'sqlserver://sa:x@ag:1433?database=app&applicationintent=ReadOnly'
        '&multisubnetfailover=yes',
      );
      expect(c.readOnlyIntent, isTrue);
      expect(c.multiSubnetFailover, isTrue);
    });

    test('KeepAlive seconds (default 30, 0 disables)', () {
      final def = MssqlConnectionString.parse(
        'Server=h;User Id=sa;Password=x',
      );
      expect(def.keepAlive, const Duration(seconds: 30));

      final off = MssqlConnectionString.parse(
        'Server=h;User Id=sa;Password=x;KeepAlive=0',
      );
      expect(off.keepAlive, Duration.zero);

      final custom = MssqlConnectionString.parse(
        'sqlserver://sa:x@h?keepalive=60',
      );
      expect(custom.keepAlive, const Duration(seconds: 60));
    });

    test('np: rejected', () {
      expect(
        () => MssqlConnectionString.parse(
          r'Server=np:\\.\pipe\sql\query;User Id=sa;Password=x',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing Server throws', () {
      expect(
        () => MssqlConnectionString.parse('User Id=sa;Password=x'),
        throwsA(isA<FormatException>()),
      );
    });

    test('pool fromConnectionString maps fields', () {
      final cfg = MssqlPoolConfig.fromConnectionString(
        'Server=10.0.0.5,1433;Database=app;User Id=sa;Password=x;'
        'Encrypt=false;App Name=lan;',
        max: 4,
      );
      expect(cfg.host, '10.0.0.5');
      expect(cfg.port, 1433);
      expect(cfg.database, 'app');
      expect(cfg.user, 'sa');
      expect(cfg.encrypt, isFalse);
      expect(cfg.appName, 'lan');
      expect(cfg.max, 4);
      expect(cfg.ntlmDomain, isNull);
    });

    test('pool fromConnectionString maps PEM trust roots', () {
      final cfg = MssqlPoolConfig.fromConnectionString(
        'Server=sql01;User Id=sa;Password=x;'
        'TrustedCertificateFile=ca.pem;TrustedCertificateDirectory=roots',
      );
      expect(cfg.trustedCertificateFile, 'ca.pem');
      expect(cfg.trustedCertificateDirectory, 'roots');
    });

    test(r'pool fromConnectionString NTLM DOMAIN\user', () {
      final cfg = MssqlPoolConfig.fromConnectionString(
        r'Server=sql01;User Id=CORP\alice;Password=pw;Encrypt=true',
      );
      expect(cfg.ntlmDomain, 'CORP');
      expect(cfg.user, 'alice');
    });
  });

  group('sqlserver:// URL', () {
    test('user:pass@host:port', () {
      final c = MssqlConnectionString.parse(
        'sqlserver://sa:secret@127.0.0.1:14330?database=master&encrypt=false',
      );
      expect(c.host, '127.0.0.1');
      expect(c.port, 14330);
      expect(c.user, 'sa');
      expect(c.password, 'secret');
      expect(c.database, 'master');
      expect(c.encrypt, isFalse);
    });

    test('instance in path', () {
      final c = MssqlConnectionString.parse(
        'sqlserver://sa:x@sql01/SQLEXPRESS?database=app',
      );
      expect(c.host, 'sql01');
      expect(c.instanceName, 'SQLEXPRESS');
      expect(c.database, 'app');
    });

    test('url-encoded password', () {
      final c = MssqlConnectionString.parse(
        'sqlserver://sa:my%7Bpass@host?database=d',
      );
      expect(c.password, 'my{pass');
    });

    test('mssql:// alias scheme', () {
      final c = MssqlConnectionString.parse('mssql://sa:x@host:1433');
      expect(c.host, 'host');
      expect(c.user, 'sa');
    });
  });
}
