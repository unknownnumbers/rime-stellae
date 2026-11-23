# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory)][ValidateSet('engine-r5','engine-n01')][string]$Variant,
    [Parameter(Mandatory)][ValidateSet('x64','x86')][string]$Architecture,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $IsWindows) { throw 'This recipe targets the Windows MSVC toolchain.' }
$manifest = Get-NativeManifest
if ($Architecture -cnotin $manifest.variants[$Variant].architectures) { throw 'This variant does not declare that architecture.' }
$source = (Resolve-Path -LiteralPath $SourcePath).Path
Assert-NativeAssembly $source $Variant
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory.' }
foreach ($tool in @('7z','cl','cmake','ninja')) { $null = Get-Command $tool -ErrorAction Stop }
$cache = [IO.Path]::GetFullPath($CacheDirectory)
$boostArchive = Get-NativeAsset 'boost' $cache
if (-not (Test-Path -LiteralPath (Join-Path $cache 'boost_1_84_0/boost/version.hpp'))) {
    Expand-NativeArchive $boostArchive $cache
}
$env:BOOST_ROOT = Join-Path $cache 'boost_1_84_0'
$dependencyArchive = Get-NativeAsset "deps-$Architecture" $cache
Expand-NativeArchive $dependencyArchive $source
$logs = Join-Path $source 'ci-logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
@'
set RIME_ROOT=%CD%
set CMAKE_GENERATOR=Ninja
set CC=cl
set CXX=cl
set common_cmake_flags=-DCMAKE_POLICY_VERSION_MINIMUM=3.5
'@ | Set-Content -LiteralPath (Join-Path $source 'env.bat') -Encoding ascii
Push-Location -LiteralPath $source
try {
    $helper = Get-NativeRepositoryPath 'native/tests/preedit_spacing_tests.cc'
    & cl.exe /nologo /std:c++17 /EHsc /W4 /I src /Fopreedit_spacing_tests.obj /Fepreedit_spacing_tests.exe $helper 2>&1 |
        Tee-Object -FilePath (Join-Path $logs 'helper-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Production preedit helper compilation failed.' }
    & .\preedit_spacing_tests.exe (Join-Path $logs 'helper-results.json')
    if ($LASTEXITCODE -ne 0) { throw 'Production preedit helper tests failed.' }
    $helperResult = Get-Content -LiteralPath (Join-Path $logs 'helper-results.json') -Raw | ConvertFrom-Json
    if ($helperResult.Passed -ne $true -or $helperResult.Checks -ne 34 -or
        $helperResult.ProductionHelper -ne $true -or $helperResult.EngineLoaded -ne $false) {
        throw 'Unexpected production preedit helper evidence.'
    }
    & .\build.bat test 2>&1 | Tee-Object -FilePath (Join-Path $logs 'build-engine.log')
    if ($LASTEXITCODE -ne 0) { throw 'Engine compilation or upstream tests failed.' }
} finally { Pop-Location }
if ((Get-Content -LiteralPath (Join-Path $logs 'build-engine.log') -Raw) -notmatch '100% tests passed, 0 tests failed') {
    throw 'The build log does not confirm actual upstream CTest execution.'
}
$machine = if ($Architecture -ceq 'x64') { 0x8664 } else { 0x014c }
Assert-NativePe (Join-Path $source 'dist/lib/rime.dll') $machine
foreach ($name in @('dist/lib/rime.lib','dist/include/rime_api.h')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw "Missing engine product: $name" }
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'dist') -Destination (Join-Path $OutputDirectory 'dist') -Recurse
Copy-Item -LiteralPath $logs -Destination (Join-Path $OutputDirectory 'ci-logs') -Recurse
Copy-Item -LiteralPath (Join-Path $source 'native-source-assembly.json') -Destination $OutputDirectory
Copy-NativeSourceNotices $OutputDirectory
[ordered]@{
    schema='rymcp-native-build/1'; variant=$Variant; architecture=$Architecture
    compilationPassed=$true; preeditHelperChecks=34; upstreamCTestPassed=$true
    productInputIntegrationTested=$false; installerBuilt=$false; installed=$false
    sha256=(Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'dist/lib/rime.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    manifestSha256=(Get-FileHash -LiteralPath $script:NativeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    compiler=[Diagnostics.FileVersionInfo]::GetVersionInfo((Get-Command cl.exe).Source).FileVersion
    publicBuildCommit=$env:GITHUB_SHA; publicBuildRunId=$env:GITHUB_RUN_ID; bitReproducible=$false
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-result.json') -Encoding utf8
