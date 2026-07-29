$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $root 'docker-compose.matrix.yml'
$password = $env:MSSQL_SA_PASSWORD
if ([string]::IsNullOrWhiteSpace($password)) {
    $password = 'Strong_test_password_123!'
}

$matrixImages = @(
    @{ Service = 'sqlserver-2017'; Image = 'mssql-dart-live:2017' },
    @{ Service = 'sqlserver-2019'; Image = 'mssql-dart-live:2019' },
    @{ Service = 'sqlserver-2022'; Image = 'mssql-dart-live:2022' },
    @{ Service = 'sqlserver-2025'; Image = 'mssql-dart-live:2025' }
)
$matrixImageRevision = '2'
$rebuiltServices = @()

function Wait-SqlServer([string]$Container) {
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        & docker exec $Container test -x /opt/mssql-tools18/bin/sqlcmd *> $null
        $sqlcmd = if ($LASTEXITCODE -eq 0) {
            '/opt/mssql-tools18/bin/sqlcmd'
        } else {
            '/opt/mssql-tools/bin/sqlcmd'
        }
        # Keep the query as one native-command argument under Windows PowerShell.
        # ODBC 18 encrypts by default; trust the self-signed test certificate.
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & docker exec $Container $sqlcmd -S localhost -U sa -P $password -C -Q 'SELECT/**/1;' *> $null
            $sqlcmdExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($sqlcmdExitCode -eq 0) { return }
        Start-Sleep -Seconds 2
    }
    & docker compose -f $compose logs
    throw "SQL Server container did not become ready: $Container"
}

function Build-MissingMatrixImages {
    $missingServices = @()
    foreach ($entry in $matrixImages) {
        $imageJson = & docker image inspect $entry.Image 2> $null
        if ($LASTEXITCODE -ne 0) {
            $missingServices += $entry.Service
            continue
        }
        $image = $imageJson | ConvertFrom-Json
        $revision = $image.Config.Labels.'org.mssql.dart.live.revision'
        if ($revision -ne $matrixImageRevision) {
            $missingServices += $entry.Service
        }
    }
    if ($missingServices.Count -eq 0) { return }

    Write-Host "Building missing SQL Server matrix images: $($missingServices -join ', ')"
    & docker compose -f $compose build @missingServices
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose failed to build SQL Server matrix images.' }
    $script:rebuiltServices = $missingServices
}

function Remove-StaleMatrixContainers {
    if ($rebuiltServices.Count -eq 0) { return }
    $staleServices = @()
    foreach ($service in $rebuiltServices) {
        $staleServices += $service, "$service-force-tls"
    }
    # Recreate only containers whose image was rebuilt. Healthy containers using
    # the current image remain running and are reused by later test runs.
    & docker compose -f $compose rm -sf @staleServices
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose failed to remove stale SQL Server containers.' }
}

try {
    Push-Location $root
    & (Join-Path $PSScriptRoot 'build_native.ps1')
    # Keep the offline phase honest: test/live is run below once per SQL Server
    # edition, rather than being invoked here only to report skipped tests.
    $offlineTests = Get-ChildItem (Join-Path $root 'test') -File -Filter '*.dart' |
        ForEach-Object { $_.FullName }
    & dart test @offlineTests
    if ($LASTEXITCODE -ne 0) { throw 'Offline Dart tests failed.' }

    Build-MissingMatrixImages
    Remove-StaleMatrixContainers
    # Do not rebuild or recreate the matrix on each test run. Existing healthy
    # containers keep their initialized databases and are simply reused.
    & docker compose -f $compose up -d --no-build --no-recreate
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose failed to start the SQL Server matrix.' }

    $editions = @(
        @{ Name = 'SQL Server 2017'; NormalPort = '14330'; ForcePort = '14331'; Container = 'mssql-dart-live-2017' },
        @{ Name = 'SQL Server 2019'; NormalPort = '14334'; ForcePort = '14335'; Container = 'mssql-dart-live-2019' },
        @{ Name = 'SQL Server 2022'; NormalPort = '14336'; ForcePort = '14337'; Container = 'mssql-dart-live-2022' },
        @{ Name = 'SQL Server 2025'; NormalPort = '14338'; ForcePort = '14339'; Container = 'mssql-dart-live-2025' }
    )
    foreach ($edition in $editions) {
        Write-Host "Waiting for $($edition.Name)..."
        Wait-SqlServer $edition.Container
        Write-Host "Running live tests against $($edition.Name)..."
        $env:MSSQL_LIVE_TESTS = '1'
        $env:MSSQL_HOST = '127.0.0.1'
        $env:MSSQL_PORT = $edition.NormalPort
        $env:MSSQL_FORCE_TLS_PORT = $edition.ForcePort
        $env:MSSQL_ENCRYPT = '0'
        $env:MSSQL_USER = 'sa'
        $env:MSSQL_PASSWORD = $password
        $env:MSSQL_TRUST_SERVER_CERTIFICATE = '1'
        & dart test test/live --concurrency=1
        if ($LASTEXITCODE -ne 0) { throw "Live tests failed against $($edition.Name)." }
    }
} finally {
    Pop-Location
    Write-Host ''
    Write-Host 'SQL Server matrix containers were kept for reuse.'
    Write-Host 'Stop them manually when finished:'
    Write-Host '  docker compose -f .\docker-compose.matrix.yml down'
}
