# SPDX-License-Identifier: GPL-3.0-only
param(
  [ValidateSet('x64','x86')][string]$Architecture='x64',
  [Parameter(Mandatory)][string]$SourcePath,
  [Parameter(Mandatory)][string]$CacheDirectory,
  [Parameter(Mandatory)][string]$OutputDirectory
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$PSNativeCommandUseErrorActionPreference=$false
if(-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true'){throw 'Run this recipe on an ephemeral Windows CI runner.'}
foreach($tool in @('7z','msbuild','cl','lib','dumpbin','cscript','python')){$null=Get-Command $tool -ErrorAction Stop}
$source=(Resolve-Path -LiteralPath $SourcePath).Path
Assert-NativeAssembly $source 'stellae-61052'
$out=[IO.Path]::GetFullPath($OutputDirectory)
$cache=[IO.Path]::GetFullPath($CacheDirectory)
if(Test-Path -LiteralPath $out){throw 'Preserve previous server output.'}
foreach($name in @('StellaeServer.exe','Win32/StellaeServer.exe')){if(Test-Path -LiteralPath (Join-Path $source "output/$name")){throw 'Use a clean frontend source assembly.'}}
$null=New-Item -ItemType Directory -Path $out,$cache
$logs=Join-Path $out 'logs';$null=New-Item -ItemType Directory -Path $logs
$inputs=Get-Content -LiteralPath (Get-NativeRepositoryPath 'native/notification-inputs.json') -Raw|ConvertFrom-Json -AsHashtable
if($inputs.schema -cne 'stellae-notification-build-inputs/1'){throw 'Unexpected notification inputs.'}
$arch=$inputs.architectures[$Architecture]
if(-not $arch){throw 'Missing fixed server architecture mapping.'}
$platform=$arch.platform
$machine=[int]$arch.machine
function Hash([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Run([string]$exe,[string[]]$arguments,[string]$log){
  & $exe @arguments 2>&1|Tee-Object -FilePath $log
  if($LASTEXITCODE){throw ('Server build command failed: '+[IO.Path]::GetFileName($log))}
}
function Pinned-Download($spec,[string]$directory){
  $url=[uri]$spec.url
  if($url.Scheme -cne 'https'){throw 'Build inputs require HTTPS.'}
  $name=[IO.Path]::GetFileName($url.AbsolutePath)
  if($name -cnotmatch '^[A-Za-z0-9._-]+$'){throw 'Unsafe build input name.'}
  $null=New-Item -ItemType Directory -Path $directory -Force
  $path=Join-Path $directory $name
  if(-not(Test-Path -LiteralPath $path)){Invoke-WebRequest -Uri $url -OutFile $path -TimeoutSec 180}
  $null=Assert-NativeHash $path $spec.sha256
  return $path
}
$baselineCpp=Join-Path $source 'RimeWithWeasel/RimeWithWeasel.cpp'
$modeIconHeader=Join-Path $source 'include/RimeWithWeasel.h'
$null=Assert-NativeHash $baselineCpp $inputs.modeIconOverlay.candidateCppSha256
$null=Assert-NativeHash $modeIconHeader $inputs.modeIconOverlay.candidateHeaderSha256
$sourceArchive=Export-NativeAssemblySource $source 'stellae-61052' (Join-Path $out 'assembled-source.zip')
$patch=Get-NativeRepositoryPath $inputs.overlay.path
$modeIconPatch=Get-NativeRepositoryPath $inputs.modeIconOverlay.path
$null=Assert-NativeHash $patch $inputs.overlay.sha256
$null=Assert-NativeHash $modeIconPatch $inputs.modeIconOverlay.sha256
# Derive the old regression fixture without changing the assembled product.
$baselineRoot=Join-Path $out 'regression-baseline'
foreach($relative in @('RimeWithWeasel/RimeWithWeasel.cpp','include/RimeWithWeasel.h')){
  $target=Join-Path $baselineRoot $relative
  $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
  Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target
}
foreach($overlay in @($modeIconPatch,$patch)){
  Invoke-NativeGit @('-c','core.autocrlf=false','-C',$baselineRoot,'apply','--reverse','--check',$overlay)
  Invoke-NativeGit @('-c','core.autocrlf=false','-C',$baselineRoot,'apply','--reverse',$overlay)
}
$baselineCopy=Join-Path $baselineRoot 'RimeWithWeasel/RimeWithWeasel.cpp'
$baselineHeaderCopy=Join-Path $baselineRoot 'include/RimeWithWeasel.h'
$null=Assert-NativeHash $baselineCopy $inputs.baselineCppSha256
$null=Assert-NativeHash $baselineHeaderCopy $inputs.modeIconOverlay.baselineHeaderSha256
foreach($test in @($inputs.tests)+@($inputs.modeIconTests)+@($inputs.statusIconAssets)){$null=Assert-NativeHash (Get-NativeRepositoryPath $test.path) $test.sha256}
Run 'python' @((Get-NativeRepositoryPath 'assets/status/generate.py'),'--check') (Join-Path $logs 'status-icon-assets.log')
& (Get-NativeRepositoryPath 'native/tests/notifications/Run-NotificationTests.ps1') -BaselineCpp $baselineCopy -CandidateCpp $baselineCpp -OutputDirectory (Join-Path $out 'notification-tests')
if($LASTEXITCODE){throw 'Notification regressions failed.'}
& (Get-NativeRepositoryPath 'native/tests/mode-icon/Run-ModeIconTests.ps1') -SourceRoot $source -OutputDirectory (Join-Path $out 'mode-icon-tests') -BaselineCpp $baselineCopy -BaselineHeader $baselineHeaderCopy
if($LASTEXITCODE){throw 'Mode icon regressions failed.'}
& (Get-NativeRepositoryPath 'native/tests/shift/Run-ShiftKeySnapshotTests.ps1') -Platform $platform -SourceRoot $source
if($LASTEXITCODE){throw 'Shift snapshot regressions failed.'}

# Only the published engine's export table is used to construct an import library.
$installer=Pinned-Download $inputs.baselineInstaller $cache
$engineRoot=Join-Path $cache 'published-engine'
if(Test-Path -LiteralPath $engineRoot){throw 'Use a fresh published-engine extraction directory.'}
Run '7z.exe' @('x',$installer,('-o'+$engineRoot),'-aou','-y','-bso0','-bsp0','rime.dll') (Join-Path $logs 'extract-import-engine.log')
# NSIS carries x64 and Win32 members with the same name. Preserve both and
# select the published input by PE architecture and its exact hash pin.
$engines=@(Get-ChildItem -LiteralPath $engineRoot -File -Filter 'rime*.dll'|Where-Object {
  $raw=[IO.File]::ReadAllBytes($_.FullName)
  if($raw.Length -lt 64 -or $raw[0] -ne 0x4d -or $raw[1] -ne 0x5a){return $false}
  $offset=[BitConverter]::ToInt32($raw,0x3c)
  $offset -ge 0 -and $offset+6 -le $raw.Length -and [BitConverter]::ToUInt16($raw,$offset+4) -eq $machine -and (Hash $_.FullName) -ceq $arch.engineSha256
})
if($engines.Count -ne 1){throw 'Expected one hash-pinned engine of the selected architecture.'}
$engine=$engines[0].FullName
$null=Assert-NativeHash $engine $arch.engineSha256
Assert-NativePe $engine $machine
$exports=(& dumpbin.exe /nologo /exports $engine|Out-String)
if($LASTEXITCODE){throw 'Published engine export inspection failed.'}
$names=@([regex]::Matches($exports,'(?m)^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|$)')|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique)
if($names -cnotcontains 'rime_get_api'){throw 'Published engine C API export is missing.'}
$def=Join-Path $out 'rime.def'
[IO.File]::WriteAllLines($def,(@('LIBRARY rime.dll','EXPORTS')+$names),[Text.Encoding]::ASCII)
$importDirectory=Join-Path $source $arch.libraryDirectory;$null=New-Item -ItemType Directory -Path $importDirectory -Force
Run 'lib.exe' @('/nologo',('/def:'+$def),('/machine:'+$Architecture),('/out:'+(Join-Path $importDirectory 'rime.lib'))) (Join-Path $logs 'import-library.log')
$headerRecords=@()
foreach($header in $inputs.apiHeaders){
  $path=Pinned-Download $header (Join-Path $cache 'api-headers')
  Copy-Item -LiteralPath $path -Destination (Join-Path $source ('include/'+$header.name))
  $headerRecords+=[ordered]@{path=('include/'+$header.name);sha256=$header.sha256;url=$header.url}
}

$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs=(& $vswhere -latest -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath|Out-String).Trim()
if(-not $vs){throw 'VS2022 C++ tools are required.'}
$vc=(Get-Content -LiteralPath (Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
foreach($name in @('atlmfc/include/atlbase.h','atlmfc/include/afxres.h')){if(-not(Test-Path -LiteralPath (Join-Path $vs "VC/Tools/MSVC/$vc/$name"))){throw 'ATL/MFC build input is missing.'}}
$boost=Get-NativeAsset 'boost' $cache
if(-not(Test-Path -LiteralPath (Join-Path $cache 'boost_1_84_0/boost/version.hpp'))){Expand-NativeArchive $boost $cache}
$env:BOOST_ROOT=Join-Path $cache 'boost_1_84_0';$env:boost_version='1.84.0'
$env:RELEASE_BUILD='1';$env:WEASEL_BUILD='61052';$env:FILE_VERSION='0.17.4.61052';$env:PRODUCT_VERSION='0.17.4.61052'
$env:VERSION_MAJOR='0';$env:VERSION_MINOR='17';$env:VERSION_PATCH='4';$env:PLATFORM_TOOLSET='v143'
$env:CL='/DSTELLAE_ENABLE_PROMPT_TRACE=0';Remove-Item Env:_CL_ -ErrorAction SilentlyContinue
$env:LINK='/PDBALTPATH:stellae.pdb';$env:_LINK_='/PDBALTPATH:stellae.pdb'
Copy-Item -LiteralPath (Join-Path $source 'env.vs2022.bat') -Destination (Join-Path $source 'env.bat')
Push-Location $env:BOOST_ROOT
try{
  if(-not(Test-Path -LiteralPath 'b2.exe')){Run $env:ComSpec @('/d','/c','bootstrap.bat') (Join-Path $logs 'boost-bootstrap.log')}
  Run '.\b2.exe' @('-j2','--with-filesystem','--with-json','--with-locale','--with-regex','--with-serialization','--with-system','--with-thread','define=BOOST_USE_WINAPI_VERSION=0x0603','toolset=msvc','architecture=x86',('address-model='+$arch.addressModel),'variant=release','link=static','runtime-link=static','threading=multi','stage') (Join-Path $logs ('boost-'+$Architecture+'.log'))
}finally{Pop-Location}
Push-Location $source
try{
  Run 'cscript.exe' @('//nologo','render.js','weasel.props','BOOST_ROOT','PLATFORM_TOOLSET','VERSION_MAJOR','VERSION_MINOR','VERSION_PATCH','WEASEL_BUILD','PRODUCT_VERSION','FILE_VERSION') (Join-Path $logs 'properties.log')
  Run 'msbuild.exe' @('weasel.sln','/m','/t:WeaselServer:Rebuild','/p:Configuration=Release',('/p:Platform='+$platform),'/v:minimal') (Join-Path $logs ('server-'+$Architecture+'.log'))
}finally{Pop-Location}
$server=Join-Path $source $arch.output
Assert-NativePe $server $machine
if([Diagnostics.FileVersionInfo]::GetVersionInfo($server).FileVersion -cne '0.17.4.61052'){throw 'Unexpected server version.'}
$release=Join-Path $out 'release';$null=New-Item -ItemType Directory -Path $release
Copy-Item -LiteralPath $server -Destination $release
$peInput=Join-Path $out 'pe-input';$null=New-Item -ItemType Directory -Path $peInput
Copy-Item -LiteralPath $server -Destination $peInput
Copy-Item -LiteralPath $engine -Destination (Join-Path $peInput 'rime.dll')
Run 'python' @((Get-NativeRepositoryPath 'scripts/package/verify_pe.py'),'--root',$peInput,'--report',(Join-Path $out 'pe-verification.json')) (Join-Path $logs 'verify-pe.log')
$testResult=Get-Content -LiteralPath (Join-Path $out 'notification-tests/results.json') -Raw|ConvertFrom-Json
$shiftResult=Get-Content -LiteralPath (Join-Path $source ('ci-logs/shift-key-snapshot-'+$platform+'.json')) -Raw|ConvertFrom-Json
$modeIconResult=Get-Content -LiteralPath (Join-Path $out 'mode-icon-tests/results.json') -Raw|ConvertFrom-Json
if(-not $testResult.Passed -or -not $shiftResult.Passed -or -not $modeIconResult.Passed){throw 'A finite regression gate failed.'}
$record=[ordered]@{schema='stellae-notification-server-build/1';passed=$true;sourceVersion='0.17.4.61052';architecture=$Architecture;commit=$env:GITHUB_SHA;run=$env:GITHUB_RUN_ID;toolset=$vc;serverSha256=(Hash $server);baselineCppSha256=$inputs.baselineCppSha256;candidateCppSha256=$inputs.modeIconOverlay.candidateCppSha256;notificationGuardCppSha256=$inputs.candidateCppSha256;candidateHeaderSha256=$inputs.modeIconOverlay.candidateHeaderSha256;overlaySha256=$inputs.overlay.sha256;modeIconOverlaySha256=$inputs.modeIconOverlay.sha256;baselineInstallerSha256=$inputs.baselineInstaller.sha256;engineUsedForImportLibrarySha256=$arch.engineSha256;assembledSourceSha256=$sourceArchive.sha256;completePatchSha256=(Get-NativeManifest).patches[0].sha256;apiHeaders=$headerRecords;notificationChecks=$testResult.PatchedChecks;baselineFailureReproduced=$true;shiftSnapshotChecks=$shiftResult.PassedCases;modeIconChecks=$modeIconResult.PassedCases;statusIconSha256=(Hash (Get-NativeRepositoryPath 'assets/status/smart-english.ico'));engineRebuilt=$false;engineBundled=$false;tsfBuilt=$false;clientsBuilt=$false;profilesIncluded=$false;serverStarted=$false;installed=$false;bitReproducible=$false}
[IO.File]::WriteAllText((Join-Path $release 'validation.json'),($record|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $out 'pe-verification.json') -Destination $release
Copy-Item -LiteralPath (Join-Path $out 'assembled-source.zip'),$patch,$modeIconPatch,(Get-NativeRepositoryPath 'native/notification-inputs.json') -Destination $release
$sdkSource=Join-Path $release 'api-headers';$null=New-Item -ItemType Directory -Path $sdkSource
foreach($header in $inputs.apiHeaders){Copy-Item -LiteralPath (Join-Path $source ('include/'+$header.name)) -Destination $sdkSource}
Copy-NativeSourceNotices $release
$productSource=Join-Path $release 'build-source/RimeWithWeasel';$null=New-Item -ItemType Directory -Path $productSource -Force
Copy-Item -LiteralPath $baselineCpp -Destination (Join-Path $productSource 'RimeWithWeasel.cpp')
$productHeader=Join-Path $release 'build-source/include';$null=New-Item -ItemType Directory -Path $productHeader -Force
Copy-Item -LiteralPath $modeIconHeader -Destination (Join-Path $productHeader 'RimeWithWeasel.h')
$sums=@(Get-ChildItem -LiteralPath $release -File -Recurse|Sort-Object FullName|ForEach-Object{(Hash $_.FullName)+'  '+[IO.Path]::GetRelativePath($release,$_.FullName).Replace('\','/')})
[IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'),$sums,[Text.UTF8Encoding]::new($false))
$record|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $out 'build-result.json') -Encoding utf8
@{Passed=$true;Product='StellaeServer.exe';NotificationChecks=$testResult.PatchedChecks;EngineBundled=$false;Installed=$false}|ConvertTo-Json
