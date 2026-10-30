# SPDX-License-Identifier: GPL-3.0-only
param(
    [ValidateSet('stellae-61052')][string]$Variant = 'stellae-61052',
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $IsWindows) { throw 'This recipe targets the Windows MSVC toolchain.' }
$manifest = Get-NativeManifest
$spec = $manifest.variants[$Variant]
$source = (Resolve-Path -LiteralPath $SourcePath).Path
Assert-NativeAssembly $source $Variant
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory.' }
foreach ($name in @('StellaeServer.exe','Win32/StellaeServer.exe')) {
    if (Test-Path -LiteralPath (Join-Path $source "output/$name")) { throw 'Use a fresh source assembly with no running product outputs.' }
}
foreach ($tool in @('7z','msbuild','cscript','cl','python')) { $null = Get-Command $tool -ErrorAction Stop }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$sourceArchive = Export-NativeAssemblySource $source $Variant (Join-Path $OutputDirectory 'assembled-source.zip')
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = (& $vswhere -latest -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
if (-not $vs) { throw 'VS2022 C++ toolchain is required.' }
$vc = (Get-Content -LiteralPath (Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
foreach ($name in @('atlmfc/include/atlbase.h','atlmfc/include/afxres.h','bin/Hostx64/x64/cl.exe','bin/Hostx64/x86/cl.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $vs "VC/Tools/MSVC/$vc/$name"))) { throw "Required ATL/MFC toolchain component missing: $name" }
}
$cache = [IO.Path]::GetFullPath($CacheDirectory)
$boost = Get-NativeAsset 'boost' $cache
if (-not (Test-Path -LiteralPath (Join-Path $cache 'boost_1_84_0/boost/version.hpp'))) { Expand-NativeArchive $boost $cache }
$env:BOOST_ROOT = Join-Path $cache 'boost_1_84_0'
$env:boost_version = '1.84.0'
$env:RELEASE_BUILD = '1'
$env:WEASEL_BUILD = $spec.buildNumber
$env:FILE_VERSION = $spec.sourceVersion
$env:PRODUCT_VERSION = $spec.sourceVersion
$env:VERSION_MAJOR = '0'
$env:VERSION_MINOR = '17'
$env:VERSION_PATCH = '4'
$env:PLATFORM_TOOLSET = 'v143'
$env:CL = '/DSTELLAE_ENABLE_PROMPT_TRACE=0'
Remove-Item Env:_CL_ -ErrorAction SilentlyContinue
# Neutral filename only, regardless of the temporary runner's checkout path.
$env:LINK = '/PDBALTPATH:stellae.pdb'
$env:_LINK_ = '/PDBALTPATH:stellae.pdb'
Copy-Item -LiteralPath (Join-Path $source 'env.vs2022.bat') -Destination (Join-Path $source 'env.bat')
$manifestHash = (Get-FileHash -LiteralPath $script:NativeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
function Get-RunEngine([string]$Id, [string]$Architecture) {
    $root = Join-Path $SdkRoot "$Id-$Architecture"
    $result = Get-Content -LiteralPath (Join-Path $root 'build-result.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($result.variant -cne $Id -or $result.architecture -cne $Architecture -or
        $result.compilationPassed -ne $true -or $result.upstreamCTestPassed -ne $true -or
        $result.publicBuildCommit -cne $env:GITHUB_SHA -or $result.publicBuildRunId -cne $env:GITHUB_RUN_ID -or
        $result.manifestSha256 -cne $manifestHash -or $result.peMetadataVerified -ne $true -or $result.symbolsBundled -ne $false) {
        throw 'All SDK and runtime inputs must be verified products of this manifest and this workflow run.'
    }
    $dll = Join-Path $root 'dist/lib/rime.dll'
    $null = Assert-NativeHash $dll $result.sha256
    Assert-NativePe $dll $(if ($Architecture -ceq 'x64') { 0x8664 } else { 0x014c })
    $root
}
$engineRoots = @{}
foreach ($arch in @('x64','x86')) {
    $sdk = Get-RunEngine 'engine-r5' $arch
    $engineRoots["engine-r5-$arch"] = $sdk
    $lib = Join-Path $source $(if ($arch -ceq 'x64') { 'lib64' } else { 'lib' })
    $dll = Join-Path $source $(if ($arch -ceq 'x64') { 'output' } else { 'output/Win32' })
    New-Item -ItemType Directory -Path $lib,$dll -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sdk 'dist/lib/rime.lib') -Destination $lib
    Copy-Item -LiteralPath (Join-Path $sdk 'dist/lib/rime.dll') -Destination $dll
    foreach ($header in Get-ChildItem -LiteralPath (Join-Path $sdk 'dist/include') -File -Filter 'rime_*.h') {
        Copy-Item -LiteralPath $header.FullName -Destination (Join-Path $source 'include')
    }
}
$engineRoots['engine-n01-x64'] = Get-RunEngine 'engine-n01' 'x64'
$logs = Join-Path $source 'ci-logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
Push-Location -LiteralPath $source
try {
    # This target only builds Boost. It does not fetch schemes or rebuild Rime.
    & .\build.bat boost 2>&1 | Tee-Object -FilePath (Join-Path $logs 'boost-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Boost compilation failed.' }
    foreach ($arch in @('x32','x64')) {
        foreach ($library in @('filesystem','json','locale','regex','serialization','system','thread')) {
            if (-not (Test-Path -LiteralPath (Join-Path $env:BOOST_ROOT "stage/lib/libboost_$library-vc143-mt-s-$arch-1_84.lib"))) {
                throw "Expected Boost library missing: $library / $arch"
            }
        }
    }
    & cscript.exe //nologo render.js weasel.props BOOST_ROOT PLATFORM_TOOLSET VERSION_MAJOR VERSION_MINOR VERSION_PATCH WEASEL_BUILD PRODUCT_VERSION FILE_VERSION 2>&1 |
        Tee-Object -FilePath (Join-Path $logs 'generate-properties.log')
    if ($LASTEXITCODE -ne 0) { throw 'Frontend property generation failed.' }
    # Build targets sequentially so TSF and legacy IME never share an active PDB.
    foreach ($platform in @('x64','Win32')) {
        foreach ($target in @('WeaselTSF','WeaselIME','WeaselServer','WeaselDeployer')) {
            & msbuild weasel.sln /m "/t:${target}:Rebuild" /p:Configuration=Release "/p:Platform=$platform" /v:minimal 2>&1 |
                Tee-Object -FilePath (Join-Path $logs "$target-$platform-build.log")
            if ($LASTEXITCODE -ne 0) { throw "Frontend compilation failed: $target / $platform" }
        }
    }
    # The fixed source has one Win32 Setup, shared by both installation paths.
    & msbuild weasel.sln /m /t:WeaselSetup:Rebuild /p:Configuration=Release /p:Platform=Win32 /v:minimal 2>&1 |
        Tee-Object -FilePath (Join-Path $logs 'WeaselSetup-Win32-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Setup compilation failed.' }
} finally { Pop-Location }
[xml]$props = Get-Content -LiteralPath (Join-Path $source 'weasel.props') -Raw
$version = $props.Project.PropertyGroup | Where-Object { $_.Label -ceq 'UserMacros' }
if ($version.PRODUCT_VERSION -cne $spec.sourceVersion -or $version.FILE_VERSION -cne $spec.sourceVersion -or $version.WEASEL_BUILD -cne $spec.buildNumber) {
    throw 'Generated frontend version differs from the manifest.'
}
$output = Join-Path $OutputDirectory 'output'
New-Item -ItemType Directory -Path (Join-Path $output 'Win32') -Force | Out-Null
$products = @()
foreach ($name in $spec.products) {
    $path = Join-Path $source "output/$name"
    $machine = if ($name.StartsWith('Win32/') -or $name -cin @('stellae.dll','stellae.ime','StellaeSetup.exe')) { 0x014c } else { 0x8664 }
    Assert-NativePe $path $machine
    $actualVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion
    if ($actualVersion -cne $spec.sourceVersion) { throw "Product version differs: $name" }
    Copy-Item -LiteralPath $path -Destination (Join-Path $output $name)
    $products += [ordered]@{name=$name; machine=$machine; version=$actualVersion; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
Copy-Item -LiteralPath (Join-Path $engineRoots['engine-n01-x64'] 'dist/lib/rime.dll') -Destination (Join-Path $output 'rime.dll')
Copy-Item -LiteralPath (Join-Path $engineRoots['engine-r5-x86'] 'dist/lib/rime.dll') -Destination (Join-Path $output 'Win32/rime.dll')
& python (Get-NativeRepositoryPath 'scripts/package/verify_pe.py') --root $output --report (Join-Path $OutputDirectory 'pe-verification.json')
if ($LASTEXITCODE -ne 0) { throw 'Frontend PE metadata or runtime import verification failed.' }
if (@(Get-ChildItem -LiteralPath $output -Recurse -File -Filter '*.pdb').Count -ne 0) { throw 'Symbols are not part of the frontend payload.' }
Copy-Item -LiteralPath $logs -Destination (Join-Path $OutputDirectory 'ci-logs') -Recurse
Copy-Item -LiteralPath (Join-Path $source 'native-source-assembly.json') -Destination $OutputDirectory
Copy-NativeSourceNotices $OutputDirectory
[ordered]@{
    schema='stellae-native-build/1'; variant=$Variant; sourceVersion=$spec.sourceVersion
    msbuildTargets=$spec.msbuildTargets; platforms=$spec.platforms; compilationPassed=$true
    promptTraceCompiled=$false; symbolsBundled=$false; pdbAlternativePath='stellae.pdb'; peMetadataVerified=$true
    completeProductRegressionRun=$false; realHostInputTested=$false; installerBuilt=$false; installed=$false
    sdk='R5 x64/x86 rebuilt in this workflow'; runtimeEngineX64='N01'; runtimeEngineX86='R5'
    sourceTreeTestEngines='R5 x64/x86'; installerOverlayApplied=$false; finalInstallerSourceSeparate=$true
    manifestSha256=$manifestHash; publicBuildCommit=$env:GITHUB_SHA; publicBuildRunId=$env:GITHUB_RUN_ID
    toolset=$vc; products=$products; bitReproducible=$false
    assembledSourceSha256=$sourceArchive.sha256; assembledSourceFiles=$sourceArchive.files
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-result.json') -Encoding utf8
