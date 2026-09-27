import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

Uint8List _browserReply(String text) {
  final body = Uint8List.fromList(text.codeUnits);
  return Uint8List.fromList([5, body.length & 255, body.length >> 8, ...body]);
}

void main() {
  test('parses all supported ADO.NET aliases', () {
    final aliases = <String, String>{
      'Server': 'server',
      'Data Source': 'source',
      'Address': 'address',
      'Addr': 'addr',
      'Network Address': 'network',
    };
    for (final entry in aliases.entries) {
      final c = MssqlConnectionString.parse(
        '${entry.key}=tcp:${entry.value},1444;Initial Catalog=db;'
        'User ID=user;Password=pass;Application Name=app;'
        'Connect Timeout=15;Encrypt=yes;TrustServerCertificate=true',
      );
      expect((c.host, c.port, c.database, c.user, c.applicationName),
          (entry.value, 1444, 'db', 'user', 'app'));
      expect(c.encryptMode, MssqlEncryptMode.mandatory);
      expect(c.trustServerCertificate, isTrue);
    }
  });

  test('parses URL and encryption modes', () {
    final c = MssqlConnectionString.parse(
      'sqlserver://user:p%40ss@host:1444/INSTANCE?database=x&encrypt=strict',
    );
    expect((c.host, c.port, c.instanceName, c.user, c.password),
        ('host', 1444, 'INSTANCE', 'user', 'p@ss'));
    expect(c.encryptMode, MssqlEncryptMode.strict);
  });

  test('parses quoted and braced ADO.NET values', () {
    final c = MssqlConnectionString.parse(
      "Server='db;one';UID='u''ser';PWD={p;ass}}word};Database=\"x;y\";Encrypt=optional",
    );
    expect((c.host, c.user, c.password, c.database),
        ('db;one', "u'ser", 'p;ass}word', 'x;y'));
    expect(c.encryptMode, MssqlEncryptMode.disabled);
  });

  test('maps every encryption spelling', () {
    final expected = {
      'true': MssqlEncryptMode.mandatory,
      'yes': MssqlEncryptMode.mandatory,
      'mandatory': MssqlEncryptMode.mandatory,
      'false': MssqlEncryptMode.disabled,
      'no': MssqlEncryptMode.disabled,
      'optional': MssqlEncryptMode.disabled,
      'strict': MssqlEncryptMode.strict,
    };
    expected.forEach((input, mode) {
      expect(MssqlConnectionString.parse('Server=x;Encrypt=$input').encryptMode,
          mode);
    });
  });

  test('rejects malformed secret values without echoing them', () {
    for (final input in [
      'Server=x;Password={very-secret',
      'Server=x;Password=very-secret;Encrypt=maybe',
      'Server=x,0;Password=very-secret',
      'Server=x;Unknown=very-secret',
      'Server=x;Password="very-secret',
    ]) {
      try {
        MssqlConnectionString.parse(input);
        fail('expected FormatException');
      } on FormatException catch (error) {
        expect(error.message.toString(), isNot(contains('very-secret')));
      }
    }
    expect(
        MssqlConnectionString.parse('Server=x;Password=very-secret').toString(),
        isNot(contains('very-secret')));
  });

  test('connectHost always carries the instance suffix; explicitPort is '
      'what decides whether connect() resolves it', () {
    // connectHost's job is only to tell connect() there IS an instance to
    // strip; connect() itself decides whether to resolve it through Browser,
    // based on explicitPort. Bypass-vs-resolve is proven end to end below
    // ("bypasses SQL Browser..." / "resolves a named instance..." tests).
    const withInstance = MssqlConnectionString(
        host: 'h', user: 'u', password: 'p', instanceName: 'SQLEXPRESS');
    expect(withInstance.connectHost, r'h\SQLEXPRESS');
    expect(withInstance.explicitPort, isNull);

    const withInstanceAndPort = MssqlConnectionString(
        host: 'h',
        user: 'u',
        password: 'p',
        port: 1533,
        explicitPort: 1533,
        instanceName: 'SQLEXPRESS');
    expect(withInstanceAndPort.connectHost, r'h\SQLEXPRESS');
    expect(withInstanceAndPort.explicitPort, 1533);

    const noInstance =
        MssqlConnectionString(host: 'h', user: 'u', password: 'p');
    expect(noInstance.connectHost, 'h');
  });

  test(
      'explicitPort is null when no port is stated even though port falls '
      'back to defaultPort, so an explicit "1433" is distinguishable from '
      '"nothing given"', () {
    final noPort = MssqlConnectionString.parse(r'Server=host\INSTANCE');
    expect((noPort.port, noPort.explicitPort), (1433, null));

    // A comma-syntax port that happens to equal defaultPort must still count
    // as explicit — this is exactly what previously made
    // MssqlPoolConfig.fromConnectionString wrongly re-query Browser and
    // clobber an explicitly stated 1433 with whatever Browser returned.
    final explicitDefaultPort =
        MssqlConnectionString.parse(r'Server=host\INSTANCE,1433');
    expect((explicitDefaultPort.port, explicitDefaultPort.explicitPort),
        (1433, 1433));
  });

  test('strips brackets from a literal IPv6 host in ADO.NET syntax', () {
    final c = MssqlConnectionString.parse('Server=[::1],1433');
    expect(c.host, '::1');
  });

  test(
      'a parse failure completes as a rejected Future, not a synchronous '
      'throw', () {
    late Future<MssqlConnection> future;
    // The exception must surface through the returned Future, not out of
    // this call — otherwise code like unawaited(x().catchError(...)) or
    // Future.wait([x(), ...]) crashes before any handler is attached.
    expect(
        () => future = MssqlConnection.connectWithString(''), returnsNormally);
    expect(future, throwsA(isA<FormatException>()));
  });

  test('rejects Connect Timeout=0 instead of producing an instant timeout', () {
    // ADO.NET treats 0 as "wait indefinitely"; this driver's timeout is
    // always a finite Duration, so silently turning 0 into Duration.zero
    // would time out almost immediately — the opposite of the request.
    expect(() => MssqlConnectionString.parse('Server=x;Connect Timeout=0'),
        throwsFormatException);
  });

  test(
      'a comma inside a URL instance-name path segment is preserved, not '
      'mistaken for a port', () {
    final c = MssqlConnectionString.parse(
        'sqlserver://myhost:1433/SQL,2019?user=u&password=p');
    expect((c.host, c.port, c.instanceName), ('myhost', 1433, 'SQL,2019'));
  });

  test('creates matching pool configuration', () async {
    final config = await MssqlPoolConfig.fromConnectionString(
      'Server=host;UID=sa;PWD=secret;Database=db;Encrypt=false;Connect Timeout=12',
      min: 1,
      max: 2,
    );
    expect((config.host, config.user, config.password, config.database),
        ('host', 'sa', 'secret', 'db'));
    expect(config.encryptMode, MssqlEncryptMode.disabled);
    expect(config.connectionTimeout, const Duration(seconds: 12));
    expect((config.min, config.max), (1, 2));
  });

  test(
      'connectWithString reaches the given port directly when both an '
      'instance name and an explicit port are present', () async {
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final sub = tcp.listen((s) {
      if (!accepted.isCompleted) accepted.complete();
      s.destroy();
    });
    addTearDown(() async {
      await sub.cancel();
      await tcp.close();
    });

    // No Browser responder is even started: reaching the TCP listener
    // proves resolution was skipped, not merely that it would have worked.
    unawaited(MssqlConnection.connectWithString(
      'Server=127.0.0.1\\TESTINST,${tcp.port};User Id=sa;Password=pw;'
      'Encrypt=false',
    ).then((_) {}, onError: (_) {}));

    await accepted.future.timeout(const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException(
            'connectWithString never reached the explicitly given port; '
            'an instance name alongside an explicit port broke routing'));
  });

  test(
      'connectWithString resolves a named instance through SQL Server '
      'Browser when no port is given', () async {
    // This is the primary, no-frills use of the feature — an instance name
    // and nothing else — and it never actually worked: connectHost correctly
    // kept the "\INSTANCE" suffix, but connectWithString used to forward
    // MssqlConnectionString.port (always a concrete int, never null) as
    // connect()'s port, so connect()'s own "no port given" sentinel could
    // never fire and it dialed the literal, unresolved "host\INSTANCE"
    // string instead of resolving it.
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final sub = tcp.listen((s) {
      if (!accepted.isCompleted) accepted.complete();
      s.destroy();
    });
    final browser =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final browserSub = browser.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = browser.receive();
      if (d == null) return;
      browser.send(
          _browserReply('ServerName;h;InstanceName;TESTINST;tcp;${tcp.port};'),
          d.address,
          d.port);
    });
    addTearDown(() async {
      await sub.cancel();
      await tcp.close();
      browserSub.cancel();
      browser.close();
    });

    // The TDS handshake fails against this bare TCP listener; only the
    // routing (Browser resolution -> dial the resolved port) is under test.
    unawaited(MssqlConnection.connectWithString(
      r'Server=127.0.0.1\TESTINST;User Id=sa;Password=pw;Encrypt=false',
      sqlBrowserPort: browser.port,
    ).then((_) {}, onError: (_) {}));

    await accepted.future.timeout(const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException(
            'connectWithString never reached the Browser-resolved TCP '
            'port; a plain "Server=host\\INSTANCE" string with no port is '
            'broken'));
  });

  test(
      'MssqlPoolConfig.fromConnectionString does not requery Browser when '
      'an explicit port equal to defaultPort is given via comma syntax',
      () async {
    var browserWasQueried = false;
    final browser =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final browserSub = browser.listen((e) {
      if (e != RawSocketEvent.read) return;
      if (browser.receive() != null) browserWasQueried = true;
    });
    addTearDown(() {
      browserSub.cancel();
      browser.close();
    });

    final config = await MssqlPoolConfig.fromConnectionString(
      r'Server=127.0.0.1\TESTINST,1433;User Id=sa;Password=pw',
      sqlBrowserPort: browser.port,
    );

    expect(browserWasQueried, isFalse);
    expect((config.host, config.port), ('127.0.0.1', 1433));
  });

  test(
      'MssqlPoolConfig.fromConnectionString resolves a named instance once, '
      'eagerly, not per pooled connection', () async {
    var requestCount = 0;
    final browser =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final browserSub = browser.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = browser.receive();
      if (d == null) return;
      requestCount++;
      browser.send(
          _browserReply('ServerName;h;InstanceName;TESTINST;tcp;4321;'),
          d.address,
          d.port);
    });
    addTearDown(() {
      browserSub.cancel();
      browser.close();
    });

    final config = await MssqlPoolConfig.fromConnectionString(
      r'Server=127.0.0.1\TESTINST;User Id=sa;Password=pw',
      sqlBrowserPort: browser.port,
    );

    // A concrete, already-resolved host/port pair — no residual instance
    // suffix that would make a later connect() call resolve again.
    expect((config.host, config.port), ('127.0.0.1', 4321));
    expect(requestCount, equals(1));
  });
}
