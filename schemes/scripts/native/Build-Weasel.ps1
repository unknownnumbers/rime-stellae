# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory)][ValidateSet('weasel-61047','weasel-server-61042','weasel-61020')][string]$Variant,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $IsWindows) { throw 'This recipe targets the Windows MSVC toolchain.' }
$manifest = Get-NativeManifest
$variantSpec = $manifest.variants[$Variant]
$source = (Resolve-Path -LiteralPath $SourcePath).Path
Assert-NativeAssembly $source $Variant
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory.' }
if (Test-Path -LiteralPath (Join-Path $source 'output/WeaselServer.exe')) {
    throw 'Use a fresh source assembly; do not invoke build.bat against an existing server output.'
}
foreach ($tool in @('7z','msbuild','cscript','cl')) { $null = Get-Command $tool -ErrorAction Stop }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = (& $vswhere -latest -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
if (-not $vs) { throw 'VS2022 C++ toolchain is required.' }
$vc = (Get-Content -LiteralPath (Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
foreach ($name in @('atlmfc/include/atlbase.h','atlmfc/include/afxres.h','bin/Hostx64/x64/cl.exe','bin/Hostx64/x86/cl.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $vs "VC/Tools/MSVC/$vc/$name"))) { throw "Required ATL/MFC/toolchain component missing: $name" }
}
$cache = [IO.Path]::GetFullPath($CacheDirectory)
$boostArchive = Get-NativeAsset 'boost' $cache
if (-not (Test-Path -LiteralPath (Join-Path $cache 'boost_1_84_0/boost/version.hpp'))) { Expand-NativeArchive $boostArchive $cache }
$env:BOOST_ROOT = Join-Path $cache 'boost_1_84_0'
$env:boost_version = '1.84.0'
$env:RELEASE_BUILD = '1'
$env:WEASEL_BUILD = $variantSpec.buildNumber
$env:FILE_VERSION = $variantSpec.sourceVersion
$env:PRODUCT_VERSION = $variantSpec.sourceVersion
$env:VERSION_MAJOR = '0'
$env:VERSION_MINOR = '17'
$env:VERSION_PATCH = '4'
$env:PLATFORM_TOOLSET = 'v143'
Copy-Item -LiteralPath (Join-Path $source 'env.vs2022.bat') -Destination (Join-Path $source 'env.bat')
foreach ($arch in @('x64','x86')) {
    $sdk = Join-Path $SdkRoot "engine-r5-$arch"
    $result = Get-Content -LiteralPath (Join-Path $sdk 'build-result.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($result.variant -cne 'engine-r5' -or $result.architecture -cne $arch -or
        $result.compilationPassed -ne $true -or $result.upstreamCTestPassed -ne $true -or
        $result.publicBuildCommit -cne $env:GITHUB_SHA -or $result.publicBuildRunId -cne $env:GITHUB_RUN_ID -or
        $result.manifestSha256 -cne (Get-FileHash -LiteralPath $script:NativeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'SDK must be produced from this manifest in the same public workflow commit.'
    }
    $dll = Join-Path $sdk 'dist/lib/rime.dll'
    $null = Assert-NativeHash $dll $result.sha256
    Assert-NativePe $dll $(if ($arch -ceq 'x64') { 0x8664 } else { 0x014c })
    $libTarget = Join-Path $source $(if ($arch -ceq 'x64') { 'lib64' } else { 'lib' })
    $dllTarget = Join-Path $source $(if ($arch -ceq 'x64') { 'output' } else { 'output/Win32' })
    New-Item -ItemType Directory -Path $libTarget,$dllTarget -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sdk 'dist/lib/rime.lib') -Destination $libTarget
    Copy-Item -LiteralPath $dll -Destination $dllTarget
    foreach ($header in Get-ChildItem -LiteralPath (Join-Path $sdk 'dist/include') -File -Filter 'rime_*.h') {
        Copy-Item -LiteralPath $header.FullName -Destination (Join-Path $source 'include')
    }
}
# Extract the fixed shared data. Never execute this official installer.
$dataArchive = Get-NativeAsset 'shared-data' $cache
Expand-NativeArchive $dataArchive (Join-Path $source 'output') @('data\*')
foreach ($name in @('output/data/essay.txt','output/data/opencc/TSCharacters.ocd2')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name))) { throw "Pinned shared data missing: $name" }
}
$logs = Join-Path $source 'ci-logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
Push-Location -LiteralPath $source
try {
    & .\build.bat boost 2>&1 | Tee-Object -FilePath (Join-Path $logs 'boost-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Boost compilation failed.' }
    foreach ($arch in @('x32','x64')) {
        foreach ($library in @('filesystem','json','locale','regex','serialization','system','thread')) {
            if (-not (Test-Path -LiteralPath (Join-Path $env:BOOST_ROOT "stage/lib/libboost_$library-vc143-mt-s-$arch-1_84.lib"))) {
                throw "Expected Boost library missing: $library / $arch"
            }
        }
    }
    & cscript.exe //nologo render.js weasel.props BOOST_ROOT PLATFORM_TOOLSET VERSION_MAJOR VERSION_MINOR VERSION_PATCH PRODUCT_VERSION FILE_VERSION 2>&1 |
        Tee-Object -FilePath (Join-Path $logs 'generate-properties.log')
    if ($LASTEXITCODE -ne 0) { throw 'Weasel property generation failed.' }
    # Build only this source variant's declared product and its project references.
    # TSF and IME therefore never share a target/PDB output in the same assembly.
    foreach ($platform in $variantSpec.platforms) {
        & msbuild weasel.sln /m "/t:$($variantSpec.msbuildTarget):Rebuild" /p:Configuration=Release "/p:Platform=$platform" /v:minimal 2>&1 |
            Tee-Object -FilePath (Join-Path $logs "$($variantSpec.msbuildTarget)-$platform-build.log")
        if ($LASTEXITCODE -ne 0) { throw "Declared Weasel product compilation failed: $Variant / $platform" }
    }
    foreach ($platform in @('x64','Win32')) {
        & (Get-NativeRepositoryPath 'native/tests/shift/Run-ShiftKeySnapshotTests.ps1') -Platform $platform -SourceRoot $source
        $shift = Get-Content -LiteralPath (Join-Path $logs "shift-key-snapshot-$platform.json") -Raw | ConvertFrom-Json
        if ($shift.Passed -ne $true -or $shift.PassedCases -ne 36 -or $shift.FailedCases -ne 0) {
            throw "Controlled Shift fixture did not pass all 36 checks: $platform"
        }
    }
} finally { Pop-Location }
[xml]$props = Get-Content -LiteralPath (Join-Path $source 'weasel.props') -Raw
$version = $props.Project.PropertyGroup | Where-Object { $_.Label -ceq 'UserMacros' }
if ($version.PRODUCT_VERSION -cne $env:FILE_VERSION -or $version.FILE_VERSION -cne $env:FILE_VERSION) { throw 'Generated Weasel product version differs.' }
if (@(Get-ChildItem -LiteralPath (Join-Path $source 'output') -Recurse -File -Filter '*installer.exe').Count -ne 0) {
    throw 'This source build must not create an installer.'
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$products = @()
foreach ($name in $variantSpec.products) {
    $path = Join-Path $source "output/$name"
    $machine = if ($name -ceq 'WeaselServer.exe' -or $name.Contains('x64')) { 0x8664 } else { 0x014c }
    Assert-NativePe $path $machine
    Copy-Item -LiteralPath $path -Destination $OutputDirectory
    $products += [ordered]@{name=$name; machine=$machine; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
Copy-Item -LiteralPath $logs -Destination (Join-Path $OutputDirectory 'ci-logs') -Recurse
Copy-Item -LiteralPath (Join-Path $source 'native-source-assembly.json') -Destination $OutputDirectory
Copy-NativeSourceNotices $OutputDirectory
[ordered]@{
    schema='rymcp-native-build/1'; variant=$Variant; sourceVersion=$env:FILE_VERSION
    msbuildTarget=$variantSpec.msbuildTarget; platforms=$variantSpec.platforms
    compilationPassed=$true; controlledShiftChecksPerArchitecture=36
    completeProductRegressionRun=$false; realHostInputTested=$false; installerBuilt=$false; installed=$false
    sdk='R5 x64/x86 rebuilt in this workflow'; runtimeEngine='N01 x64 is a separate engine artifact'
    manifestSha256=(Get-FileHash -LiteralPath $script:NativeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    publicBuildCommit=$env:GITHUB_SHA; publicBuildRunId=$env:GITHUB_RUN_ID; toolset=$vc; products=$products; bitReproducible=$false
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-result.json') -Encoding utf8
