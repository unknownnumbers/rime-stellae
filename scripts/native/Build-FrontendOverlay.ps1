# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory)][ValidateSet('x64','x86')][string]$Architecture,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$DeployerOnly,
    [switch]$ClientOnly
)
if ($DeployerOnly -and $ClientOnly) { throw 'Select either the settings component or client images.' }
if ($ClientOnly -and $Architecture -cne 'x86') { throw 'The compatibility client build targets x86.' }
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $IsWindows) { throw 'Build the frontend with the Windows MSVC toolchain.' }
$source = (Resolve-Path -LiteralPath $SourcePath).Path
Assert-NativeAssembly $source 'stellae-61052'
$inputs = Get-Content -LiteralPath (Get-NativeRepositoryPath 'native/notification-inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$configuration = $inputs.architectures[$Architecture]
$version = (Get-NativeManifest).variants['stellae-61052'].sourceVersion
$machine = [int]$configuration.machine
$platform = $configuration.platform
$paths = if ($DeployerOnly) {
    if ($Architecture -cne 'x64') { throw 'The settings component targets x64 Windows.' }
    @('StellaeDeployer.exe')
} elseif ($ClientOnly) {
    @('stellae.dll','stellae.ime')
} elseif ($Architecture -ceq 'x64') {
    @('stellaex64.dll','stellaex64.ime','StellaeServer.exe','StellaeDeployer.exe')
} else {
    @('stellae.dll','stellae.ime','Win32/StellaeServer.exe','Win32/StellaeDeployer.exe')
}
foreach ($path in $paths) {
    if (Test-Path -LiteralPath (Join-Path $source "output/$path")) { throw 'Use a clean frontend source assembly.' }
}
$out = [IO.Path]::GetFullPath($OutputDirectory)
$cache = [IO.Path]::GetFullPath($CacheDirectory)
if (Test-Path -LiteralPath $out) { throw 'Use a fresh output directory.' }
$logs = Join-Path $out 'logs'
$release = Join-Path $out 'release'
$null = New-Item -ItemType Directory -Path $logs,$release,$cache -Force
foreach ($tool in @('7z','msbuild','cl','lib','dumpbin','cscript')) { $null = Get-Command $tool -ErrorAction Stop }

function Hash([string]$path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}
function Run([string]$executable, [string[]]$arguments, [string]$directory, [string]$log) {
    Push-Location -LiteralPath $directory
    try {
        & $executable @arguments 2>&1 | Tee-Object -FilePath (Join-Path $logs $log)
        if ($LASTEXITCODE) { throw "Frontend build command failed: $log" }
    } finally { Pop-Location }
}
function Download($fixed, [string]$directory) {
    $url = [uri]$fixed.url
    $name = [IO.Path]::GetFileName($url.AbsolutePath)
    if ($url.Scheme -cne 'https' -or $name -cnotmatch '^[A-Za-z0-9._-]+$') { throw 'Expected a fixed HTTPS input.' }
    $null = New-Item -ItemType Directory -Path $directory -Force
    $file = Join-Path $directory $name
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest -Uri $url -OutFile $file -TimeoutSec 180 }
    $null = Assert-NativeHash $file $fixed.sha256
    $file
}

$installer = Download $inputs.baselineInstaller $cache
$engineDirectory = Join-Path $out 'engine'
Run '7z.exe' @('x',$installer,('-o'+$engineDirectory),'-aou','-y','-bso0','-bsp0','rime.dll') $out 'engine.log'
$engines = @(Get-ChildItem -LiteralPath $engineDirectory -File -Filter 'rime*.dll' | Where-Object { (Hash $_.FullName) -ceq $configuration.engineSha256 })
if ($engines.Count -ne 1) { throw 'Expected the pinned runtime engine for import inspection.' }
$engine = $engines[0].FullName
Assert-NativePe $engine $machine
$exports = (& dumpbin.exe /nologo /exports $engine | Out-String)
if ($LASTEXITCODE) { throw 'Engine export inspection failed.' }
$names = @([regex]::Matches($exports,'(?m)^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|$)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($names -cnotcontains 'rime_get_api') { throw 'The published engine C API is missing.' }
$definition = Join-Path $out 'rime.def'
[IO.File]::WriteAllLines($definition,(@('LIBRARY rime.dll','EXPORTS')+$names),[Text.Encoding]::ASCII)
$library = Join-Path $source $configuration.libraryDirectory
$null = New-Item -ItemType Directory -Path $library -Force
Run 'lib.exe' @('/nologo',('/def:'+$definition),('/machine:'+$Architecture),('/out:'+(Join-Path $library 'rime.lib'))) $source 'import-library.log'
foreach ($header in $inputs.apiHeaders) {
    Copy-Item -LiteralPath (Download $header (Join-Path $cache 'api-headers')) -Destination (Join-Path $source ('include/'+$header.name))
}

$boost = Get-NativeAsset 'boost' $cache
$env:BOOST_ROOT = Join-Path $cache 'boost_1_84_0'
if (-not (Test-Path -LiteralPath (Join-Path $env:BOOST_ROOT 'boost/version.hpp'))) { Expand-NativeArchive $boost $cache }
$env:boost_version = '1.84.0'
$env:RELEASE_BUILD = '1'
$env:WEASEL_BUILD = '61052'
$env:FILE_VERSION = $env:PRODUCT_VERSION = $version
$env:VERSION_MAJOR = '0'
$env:VERSION_MINOR = '17'
$env:VERSION_PATCH = '4'
$env:PLATFORM_TOOLSET = 'v143'
$env:CL = '/DSTELLAE_ENABLE_PROMPT_TRACE=0 /DSTELLAE_SHIFT_CALLBACK_TRACE=0'
Remove-Item Env:_CL_ -ErrorAction SilentlyContinue
$env:LINK = $env:_LINK_ = '/PDBALTPATH:stellae.pdb'
Copy-Item -LiteralPath (Join-Path $source 'env.vs2022.bat') -Destination (Join-Path $source 'env.bat')
$boostTool = Join-Path $env:BOOST_ROOT 'b2.exe'
if (-not (Test-Path -LiteralPath $boostTool)) { Run $env:ComSpec @('/d','/c','bootstrap.bat') $env:BOOST_ROOT 'boost-bootstrap.log' }
Run $boostTool @('-j2','--with-filesystem','--with-json','--with-locale','--with-regex','--with-serialization','--with-system','--with-thread','define=BOOST_USE_WINAPI_VERSION=0x0603','toolset=msvc','architecture=x86',('address-model='+$configuration.addressModel),'variant=release','link=static','runtime-link=static','threading=multi','stage') $env:BOOST_ROOT 'boost.log'
Run 'cscript.exe' @('//nologo','render.js','weasel.props','BOOST_ROOT','PLATFORM_TOOLSET','VERSION_MAJOR','VERSION_MINOR','VERSION_PATCH','WEASEL_BUILD','PRODUCT_VERSION','FILE_VERSION') $source 'properties.log'
$archive = Join-Path $release 'candidate-source.zip'
$null = Export-NativeAssemblySource $source 'stellae-61052' $archive
$targets = if ($DeployerOnly) { @('WeaselDeployer') } elseif ($ClientOnly) { @('WeaselTSF','WeaselIME') } else { @('WeaselTSF','WeaselIME','WeaselServer','WeaselDeployer') }
foreach ($target in $targets) {
    Run 'msbuild.exe' @('weasel.sln','/m',('/t:'+$target+':Rebuild'),'/p:Configuration=Release',('/p:Platform='+$platform),'/v:minimal') $source ($target+'.log')
}
$records = foreach ($relative in $paths) {
    $image = Join-Path $source "output/$relative"
    Assert-NativePe $image $machine
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo($image).FileVersion -cne $version) { throw 'A frontend image has an unexpected version.' }
    $name = [IO.Path]::GetFileName($image)
    Copy-Item -LiteralPath $image -Destination (Join-Path $release $name)
    [ordered]@{name=$name;installedRelativePath=$relative;machine=$machine;version=$version;bytes=(Get-Item -LiteralPath $image).Length;sha256=(Hash $image)}
}
$scope = if ($DeployerOnly) { 'settings-component' } elseif ($ClientOnly) { 'frontend-client-images' } else { 'frontend-images' }
[ordered]@{passed=$true;buildScope=$scope;architecture=$Architecture;sourceVersion=$version;products=@($records);candidateSourceArchiveSha256=(Hash $archive);symbolsBundled=$false;engineBundled=$false;engineRebuilt=$false;optInNumericTraceCompiled=$false} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $release 'build-result.json') -Encoding utf8
