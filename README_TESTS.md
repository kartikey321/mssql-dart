# Testing mssql

## Offline tests

```powershell
dart test
```

`test/live/**` is gated: without `MSSQL_LIVE_TESTS=1` those files skip rather
than fail.

## Native TLS C++ tests

The native OpenSSL ABI has an in-memory client/server CTest that covers the
handshake, certificate extraction, and encrypted request/response flow.

GitHub Actions builds and tests self-contained Windows x64 and Linux x64
helpers on every pull request. It also cross-builds Android `arm64-v8a`,
`armeabi-v7a`, and `x86_64` helpers, statically linking OpenSSL into each
`libmssql_tls.so`. Tagged builds attach platform ZIPs, with `SHA256SUMS`, to
the GitHub release.

On Windows, with Visual Studio 2022, CMake, Ninja, and OpenSSL installed:

```powershell
.\tool\build_native.ps1
```

On Linux, with a C++ compiler, CMake, Ninja, and OpenSSL development headers:

```bash
cmake -S native -B build/native -G Ninja -DBUILD_TESTING=ON
cmake --build build/native
ctest --test-dir build/native --output-on-failure
```

## Android native TLS helper

Android encrypted connections load `libmssql_tls.so` through the platform
linker. Package the ABI-specific helpers from the `mssql-tls-android` release
asset in the consuming Flutter/Android app under:

```text
android/app/src/main/jniLibs/arm64-v8a/libmssql_tls.so
android/app/src/main/jniLibs/armeabi-v7a/libmssql_tls.so
android/app/src/main/jniLibs/x86_64/libmssql_tls.so
```

Build them locally with Android NDK r27 (or a compatible NDK), CMake, Ninja,
Perl, Make, and curl. The helper statically links both OpenSSL and the C++
runtime. The script downloads pinned OpenSSL 3.5.7 and verifies its SHA-256
before compiling:

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk
bash tool/build_android_native.sh
```

The resulting files are written to `dist/android/<abi>/`. Android has no
OpenSSL integration with its Java trust store; for certificate validation,
provide `trustedCertificateFile` or `trustedCertificateDirectory` with PEM
roots accessible to the app. `trustServerCertificate: true` remains suitable
only for local development and controlled test environments.

## Full SQL Server matrix

`tool/full_tests.ps1` builds the native helper, runs offline Dart tests, then
starts normal and force-encryption containers for SQL Server 2017, 2019, 2022,
and 2025. It runs `test/live` once per edition and leaves the matrix running
for reuse on later runs.

```powershell
.\tool\full_tests.ps1
```

Stop the matrix when finished with:

```powershell
docker compose -f .\docker-compose.matrix.yml down
```

The eight host ports are 14330/14331 (2017), 14334/14335 (2019),
14336/14337 (2022), and 14338/14339 (2025). SQL Server 2012 through 2016 have
no official Linux container images; test those releases against externally
provisioned Windows instances by setting the normal `MSSQL_*` environment
variables.

## Live SQL Server tests

One compose file starts two containers:

| Container | Host port | Used by |
| --- | --- | --- |
| `mssql-dart-live` | **14334** | Most of `test/live` (default `MSSQL_PORT` / `encrypt: false`) |
| `mssql-dart-live-force-tls` | **14335** | `tls_force_encrypt_stress_test.dart` (hard-wired; always `encrypt: true`) |

```powershell
Copy-Item .env.example .env   # once
docker compose --env-file .env -f docker-compose.live.yml up -d --build

$env:MSSQL_LIVE_TESTS = '1'
$env:MSSQL_HOST = '127.0.0.1'
$env:MSSQL_USER = 'sa'
$env:MSSQL_PASSWORD = 'Strong_test_password_123!'
$env:MSSQL_TRUST_SERVER_CERTIFICATE = '1'
# Defaults: MSSQL_PORT=14334, MSSQL_ENCRYPT=0

dart test test/live --concurrency=1

docker compose --env-file .env -f docker-compose.live.yml down
```

`MSSQL_LIVE_IMAGE` selects the SQL Server Linux image for both containers. It
defaults to SQL Server 2022. Set it before Compose (or edit `.env`) to run the
same suite against other releases:

```powershell
$env:MSSQL_LIVE_IMAGE = 'mcr.microsoft.com/mssql/server:2019-latest'
docker compose --env-file .env -f docker-compose.live.yml up -d --build

$env:MSSQL_LIVE_IMAGE = 'mcr.microsoft.com/mssql/server:2025-latest'
docker compose --env-file .env -f docker-compose.live.yml up -d --build
```

Any compatible SQL Server Linux image can be supplied. It must support the
standard `/var/opt/mssql` layout, run SQL Server as the `mssql` user, and be
able to install OpenSSL while building the live-test image.

`MSSQL_PASSWORD` is required whenever `MSSQL_LIVE_TESTS=1`. Compose has no
persistent volume; `docker compose down` wipes both containers. Do not use
production credentials.

```bash
cp -n .env.example .env
docker compose --env-file .env -f docker-compose.live.yml up -d --build
export MSSQL_LIVE_TESTS=1 MSSQL_HOST=127.0.0.1 \
  MSSQL_USER=sa MSSQL_PASSWORD='Strong_test_password_123!' \
  MSSQL_TRUST_SERVER_CERTIFICATE=1
dart test test/live --concurrency=1
```
