param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$vsDevCmd = 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $vsDevCmd)) {
    throw 'Visual Studio 2022 developer tools were not found.'
}

cmd /c "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 && cmake -UOPENSSL_* -ULIB_EAY_* -USSL_EAY_* -S `"$root\native`" -B `"$root\build\native`" -G Ninja -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=$Configuration -DOPENSSL_USE_STATIC_LIBS=TRUE && cmake --build `"$root\build\native`" --config $Configuration && ctest --test-dir `"$root\build\native`" --output-on-failure"

$outputDir = Join-Path $root 'native\bin\windows-x64'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
Copy-Item (Join-Path $root 'build\native\mssql_tls.dll') $outputDir -Force
