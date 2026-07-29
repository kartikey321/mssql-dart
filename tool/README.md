# Development tools

This directory contains developer-only utilities for profiling and diagnosing the `mssql` driver. These programs are not part of the public package API and are not intended to be imported by applications.

Run commands from the repository root so package imports and relative paths resolve correctly.

## `profile_bench.dart`

`profile_bench.dart` runs a small set of SQL Server round-trip benchmarks and adds `dart:developer` timeline events around each measured operation. It can be run directly for simple timing output or through a Dart profiler for CPU analysis.

The benchmark covers:

- connection open and close;
- parameterless queries;
- parameterized RPC queries;
- decoding common SQL Server data types;
- buffered and streamed multi-row results;
- DML execution;
- transaction overhead;
- sequential and concurrent pool queries.

The tool performs warm-up iterations before measuring most operations. Results are printed as average elapsed microseconds and total elapsed time.

## Prerequisites

- used the same docker container as for live testing.

The benchmark currently connects with `encrypt: false`. Use it only against a trusted local development server unless the tool is updated to enable TLS.

## Run directly

### PowerShell

```powershell
$env:MSSQL_HOST = "127.0.0.1"
$env:MSSQL_PORT = "14334"
$env:MSSQL_USER = "sa"
$env:MSSQL_PASSWORD = "Strong_test_password_123!"
$env:MSSQL_DATABASE = "master"

dart pub get
dart run tool/profile_bench.dart
```

### Bash

```bash
export MSSQL_HOST=127.0.0.1
export MSSQL_PORT=14334
export MSSQL_USER=sa
export MSSQL_PASSWORD='Strong_test_password_123!'
export MSSQL_DATABASE=master

dart pub get
dart run tool/profile_bench.dart
```

Example output:

```text
mssql driver profiling benchmark
host=127.0.0.1:14334  iterations=30  warmup=5

── 2. Simple query — SELECT 1 (no params) ─────────────
  30 × query SELECT 1: avg 850µs  (25ms total)
```

Exact values depend heavily on SQL Server load, network latency, Docker or VM overhead, CPU power management, and whether the process is running in JIT or compiled mode.

## Run with the profiler

The benchmark wraps major sections in timeline events so profiler output can be grouped by driver operation.

```bash
devtools-profiler run \
  --hide-sdk \
  --hide-runtime-helpers \
  --method-table \
  --cwd . \
  -- dart run tool/profile_bench.dart
```

PowerShell equivalent:

```powershell
devtools-profiler run `
  --hide-sdk `
  --hide-runtime-helpers `
  --method-table `
  --cwd . `
  -- dart run tool/profile_bench.dart
```

Useful timeline labels include:

- `connect+close`;
- `query SELECT 1`;
- `query w/ int param`;
- `query w/ string param`;
- `query w/ DateTime param`;
- `query w/ 5 mixed params`;
- type-specific decode labels;
- `query 100 rows buffered`;
- `queryStream 100 rows`;
- `execute INSERT`;
- `transaction callback`;
- `begin+commit`;
- `pool sequential`;
- `pool concurrent`.

## Comparing changes

For useful before-and-after comparisons:

1. Use the same Dart SDK and SQL Server version.
2. Run against the same host and database.
3. Keep the server otherwise idle.
4. Run each revision several times.
5. Compare medians or distributions, not one individual run.
6. Profile only after confirming that the timing regression is repeatable.
7. Benchmark debug/JIT and compiled executables separately when both deployment modes matter.

To reduce startup and JIT effects for standalone measurements, compile the tool first:

```bash
dart compile exe tool/profile_bench.dart -o build/profile_bench
./build/profile_bench
```

On Windows:

```powershell
dart compile exe tool/profile_bench.dart -o build/profile_bench.exe
.\build\profile_bench.exe
```

Do not directly compare `dart run` results with compiled executable results.

## Benchmark limitations

This tool is intended for development profiling, not for publishing general performance claims.

- It measures complete client/server round trips, not only Dart CPU time.
- The iteration counts are intentionally small for interactive profiling.
- Temporary tables are created for DML and transaction benchmarks and disappear when the connection closes.
- The multi-row benchmark reads from `master.dbo.spt_values`, which is available on common SQL Server installations but should not be treated as application data.
- Pool benchmarks include SQL Server and network concurrency effects.
- A faster result does not prove protocol correctness; run the unit and live integration tests separately.

## Adding another tool

Keep tools self-contained and runnable from the repository root. A new tool should:

- read credentials and endpoints from environment variables;
- avoid hard-coded production hosts or secrets;
- print its configuration without printing passwords or tokens;
- close connections and pools in `finally` blocks;
- clearly distinguish destructive utilities from read-only diagnostics;
- document its command and required environment variables in this file.
