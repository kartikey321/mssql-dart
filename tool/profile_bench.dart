// Profiling benchmark for the mssql driver.
//
// Run with:
//   devtools-profiler run \
//     --hide-sdk --hide-runtime-helpers \
//     --method-table \
//     --cwd . \
//     -- dart run tool/profile_bench.dart
//
// Each section is wrapped in a dart:developer Timeline event so the profiler
// can attribute CPU time to specific driver operations.

import 'dart:developer';
import 'dart:io';

import 'package:mssql/mssql.dart';

// Connection details from environment variables. Defaults target the standard
// local dev container; override for other environments:
//   export MSSQL_HOST=127.0.0.1 MSSQL_PORT=14330
//   export MSSQL_USER=sa MSSQL_PASSWORD=your_password MSSQL_DATABASE=master
final _host = Platform.environment['MSSQL_HOST'] ?? '127.0.0.1';
final _port = int.parse(Platform.environment['MSSQL_PORT'] ?? '14330');
final _user = Platform.environment['MSSQL_USER'] ?? 'sa';
final _pass = Platform.environment['MSSQL_PASSWORD'] ?? '';
final _db = Platform.environment['MSSQL_DATABASE'] ?? 'master';

const _warmup = 5;
const _iters = 30;

Future<MssqlConnection> _openConn() => MssqlConnection.connect(
      host: _host,
      port: _port,
      user: _user,
      password: _pass,
      database: _db,
      encrypt: false,
      trustServerCertificate: true,
    );

void _header(String title) {
  print('\n── $title ─────────────────────────────────────────');
}

Future<void> _time(String name, Future<void> Function() fn) async {
  for (var i = 0; i < _warmup; i++) {
    await fn();
  }
  final sw = Stopwatch()..start();
  Timeline.startSync(name);
  for (var i = 0; i < _iters; i++) {
    await fn();
  }
  Timeline.finishSync();
  sw.stop();
  final avg = sw.elapsedMicroseconds ~/ _iters;
  print('  $_iters × $name: avg $avgµs  (${sw.elapsedMilliseconds}ms total)');
}

// ── 1. Connection open/close ───────────────────────────────────────────────

Future<void> benchConnect() async {
  _header('1. Connection open + close');
  const n = 10;
  final sw = Stopwatch()..start();
  Timeline.startSync('connect+close');
  for (var i = 0; i < n; i++) {
    final c = await _openConn();
    await c.close();
  }
  Timeline.finishSync();
  sw.stop();
  print(
      '  $n × connect+close: avg ${sw.elapsedMicroseconds ~/ n}µs  (${sw.elapsedMilliseconds}ms total)');
}

// ── 2. Simple query ───────────────────────────────────────────────────────

Future<void> benchSimpleQuery(MssqlConnection conn) async {
  _header('2. Simple query — SELECT 1 (no params)');
  await _time('query SELECT 1', () async {
    await conn.query('SELECT 1 AS v');
  });
}

// ── 3. Parameterised query ────────────────────────────────────────────────

Future<void> benchParamQuery(MssqlConnection conn) async {
  _header('3. Parameterised query — sp_executesql encoding');
  await _time('query w/ int param', () async {
    await conn.query('SELECT @v AS v', {'v': 42});
  });
  await _time('query w/ string param', () async {
    await conn.query('SELECT @v AS v', {'v': 'hello world'});
  });
  await _time('query w/ DateTime param', () async {
    await conn.query('SELECT @v AS v', {'v': DateTime.utc(2024, 6, 15)});
  });
  await _time('query w/ 5 mixed params', () async {
    await conn.query(
      'SELECT @a AS a, @b AS b, @c AS c, @d AS d, @e AS e',
      {'a': 1, 'b': 'x', 'c': true, 'd': 3.14, 'e': null},
    );
  });
}

// ── 4. Type decoding ──────────────────────────────────────────────────────

Future<void> benchTypeDecoding(MssqlConnection conn) async {
  _header('4. Type decoding — server-side round-trips');
  await _time('INT decode', () async {
    await conn.query('SELECT CAST(42 AS INT) AS v');
  });
  await _time('NVARCHAR decode', () async {
    await conn.query("SELECT CAST(N'hello world' AS NVARCHAR(50)) AS v");
  });
  await _time('DATETIME2 decode', () async {
    await conn.query("SELECT CAST('2024-06-15 10:30:00' AS DATETIME2) AS v");
  });
  await _time('DECIMAL(18,6) decode', () async {
    await conn.query('SELECT CAST(12345.678901 AS DECIMAL(18,6)) AS v');
  });
  await _time('UNIQUEIDENTIFIER decode', () async {
    await conn.query(
        "SELECT CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS UNIQUEIDENTIFIER) AS v");
  });
}

// ── 5. Multi-row result ───────────────────────────────────────────────────

Future<void> benchMultiRow(MssqlConnection conn) async {
  _header('5. Multi-row result — buffered vs streaming');
  const sql = '''
    SELECT TOP 100 number AS v
    FROM master.dbo.spt_values
    WHERE type = 'P'
    ORDER BY number
  ''';
  await _time('query 100 rows buffered', () async {
    await conn.query(sql);
  });
  await _time('queryStream 100 rows', () async {
    await for (final _ in conn.queryStream(sql)) {}
  });
}

// ── 6. execute (DML) ──────────────────────────────────────────────────────

Future<void> benchExecute(MssqlConnection conn) async {
  _header('6. execute — DML path');
  await conn.execute('CREATE TABLE #bench_exec (v INT)');
  await _time('execute INSERT', () async {
    await conn.execute('INSERT INTO #bench_exec VALUES (1)');
  });
}

// ── 7. Transaction overhead ───────────────────────────────────────────────

Future<void> benchTransaction(MssqlConnection conn) async {
  _header('7. Transaction overhead');
  await conn.execute('CREATE TABLE #bench_tx (v INT)');
  const n = 20;

  final sw = Stopwatch()..start();
  Timeline.startSync('transaction callback');
  for (var i = 0; i < n; i++) {
    await conn.transaction(
        (c) async => c.execute('INSERT INTO #bench_tx VALUES (1)'));
  }
  Timeline.finishSync();
  sw.stop();
  print(
      '  $n × transaction (1 INSERT): avg ${sw.elapsedMicroseconds ~/ n}µs  (${sw.elapsedMilliseconds}ms total)');

  final sw2 = Stopwatch()..start();
  Timeline.startSync('begin+commit');
  for (var i = 0; i < n; i++) {
    await conn.beginTransaction();
    await conn.execute('INSERT INTO #bench_tx VALUES (2)');
    await conn.commitTransaction();
  }
  Timeline.finishSync();
  sw2.stop();
  print(
      '  $n × begin+INSERT+commit: avg ${sw2.elapsedMicroseconds ~/ n}µs  (${sw2.elapsedMilliseconds}ms total)');
}

// ── 8. Pool throughput ────────────────────────────────────────────────────

Future<void> benchPool() async {
  _header('8. Pool throughput');
  final pool = MssqlPool(MssqlPoolConfig(
    host: _host,
    port: _port,
    user: _user,
    password: _pass,
    database: _db,
    encrypt: false,
    trustServerCertificate: true,
    min: 4,
    max: 8,
  ));
  await pool.open();
  try {
    final sw = Stopwatch()..start();
    Timeline.startSync('pool sequential');
    for (var i = 0; i < _iters; i++) {
      await pool.query('SELECT 1 AS v');
    }
    Timeline.finishSync();
    sw.stop();
    print(
        '  $_iters × pool.query sequential: avg ${sw.elapsedMicroseconds ~/ _iters}µs');

    const concurrency = 8;
    const batches = 4;
    final sw2 = Stopwatch()..start();
    Timeline.startSync('pool concurrent');
    for (var b = 0; b < batches; b++) {
      await Future.wait([
        for (var i = 0; i < concurrency; i++) pool.query('SELECT $i AS v'),
      ]);
    }
    Timeline.finishSync();
    sw2.stop();
    print(
        '  ${concurrency * batches} × pool.query concurrent ($concurrency at once): '
        'avg ${sw2.elapsedMicroseconds ~/ (concurrency * batches)}µs');
  } finally {
    await pool.close();
  }
}

void main() async {
  print('mssql driver profiling benchmark');
  print('host=$_host:$_port  iterations=$_iters  warmup=$_warmup');

  await benchConnect();

  final conn = await _openConn();
  try {
    await benchSimpleQuery(conn);
    await benchParamQuery(conn);
    await benchTypeDecoding(conn);
    await benchMultiRow(conn);
    await benchExecute(conn);
    await benchTransaction(conn);
  } finally {
    await conn.close();
  }

  await benchPool();

  print('\n✓ done');
}
