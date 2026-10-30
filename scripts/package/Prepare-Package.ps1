# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$FrontendOutput,
  [Parameter(Mandatory)][string]$SourcePath,
  [Parameter(Mandatory)][string]$SdkRoot,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [Parameter(Mandatory)][string]$CacheDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or -not $IsWindows){throw 'Use a disposable Windows build runner.'}
$repository=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$FrontendOutput=(Resolve-Path -LiteralPath $FrontendOutput).Path
$SourcePath=(Resolve-Path -LiteralPath $SourcePath).Path
if(Test-Path -LiteralPath $OutputDirectory){throw 'The package directory must be new.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
$payload=Join-Path $OutputDirectory 'stage/output'
$release=Join-Path $OutputDirectory 'release'
$null=New-Item -ItemType Directory -Path $payload,$release,$CacheDirectory -Force
$CacheDirectory=(Resolve-Path -LiteralPath $CacheDirectory).Path
$manifest=Get-Content (Join-Path $repository 'native/source-manifest.json') -Raw|ConvertFrom-Json
$asset=@($manifest.assets|Where-Object {$_.id -eq 'shared-data'})
if($asset.Count -ne 1){throw 'Exactly one fixed shared-data input is required.'}
$official=Join-Path $CacheDirectory 'weasel-0.17.4.0-installer.exe'
if(-not (Test-Path -LiteralPath $official)){Invoke-WebRequest $asset[0].url -OutFile $official}
if((Get-FileHash -LiteralPath $official -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset[0].sha256){throw 'Official shared input hash differs.'}
$officialOutput=Join-Path $OutputDirectory 'official-input'
& 7z.exe x $official "-o$officialOutput" 'data/*' 'rime-install.bat' 'rime-install-config.bat' '7z.exe' '7z.dll' '7-zip-license.txt' 'curl.exe' 'curl-ca-bundle.crt' 'COPYING-curl.txt' -y | Out-File (Join-Path $OutputDirectory 'extract-input.log')
if($LASTEXITCODE){throw 'Fixed official input extraction failed.'}
$products=@('stellae.dll','stellaex64.dll','stellae.ime','stellaex64.ime','StellaeServer.exe','StellaeDeployer.exe','StellaeSetup.exe','rime.dll','Win32/StellaeServer.exe','Win32/StellaeDeployer.exe','Win32/rime.dll')
foreach($name in $products){
  $origin=Join-Path (Join-Path $FrontendOutput 'output') $name
  if(-not (Test-Path -LiteralPath $origin)){throw "Missing clean product: $name"}
  $target=Join-Path $payload $name
  $null=New-Item -ItemType Directory -Path (Split-Path $target) -Force
  Copy-Item -LiteralPath $origin -Destination $target
}
$data=Join-Path $payload 'data'
$null=New-Item -ItemType Directory -Path $data -Force
foreach($name in @('weasel.yaml','key_bindings.yaml','punctuation.yaml','symbols.yaml')){
  Copy-Item -LiteralPath (Join-Path $officialOutput "data/$name") -Destination $data
}
foreach($folder in @('opencc','preview')){
  $target=Join-Path $data $folder
  $null=New-Item -ItemType Directory -Path $target
  $extensions=if($folder -eq 'opencc'){@('.json','.ocd','.ocd2')}else{@('.png')}
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $officialOutput "data/$folder") -File){
    if($file.Extension -in $extensions){Copy-Item -LiteralPath $file.FullName -Destination $target}
  }
}
Copy-Item -LiteralPath (Join-Path $repository 'installer/default.yaml') -Destination $data
foreach($name in @('7z.exe','7z.dll','7-zip-license.txt','curl.exe','curl-ca-bundle.crt','COPYING-curl.txt','rime-install.bat')){
  Copy-Item -LiteralPath (Join-Path $officialOutput $name) -Destination $payload
}
# Product-specific paths are from the pinned source, never a local installation.
foreach($name in @('rime-install-config.bat','start_service.bat','stop_service.bat')){
  Copy-Item -LiteralPath (Join-Path $SourcePath "output/$name") -Destination $payload
}
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination (Join-Path $payload 'LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE-DOCS') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repository 'licenses') -Destination $payload -Recurse
Copy-Item -LiteralPath (Join-Path $repository 'THIRD_PARTY_NOTICES.md') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repository 'docs/SOURCES.md') -Destination (Join-Path $payload 'SOURCES.md')
$manual=@('README.md','README.en.md','README.zh-SC.md')|ForEach-Object{[IO.File]::ReadAllText((Join-Path $repository $_))}
[IO.File]::WriteAllText((Join-Path $payload 'README.txt'),($manual -join "`n`n---`n`n"),[Text.UTF8Encoding]::new($false))
foreach($name in @('install.nsi','InstallProfilePolicy.ps1','NativeProfileSnapshot.ps1','stellae_identity.nsh')){
  Copy-Item -LiteralPath (Join-Path $repository "installer/$name") -Destination $payload
}
$resource=Join-Path $OutputDirectory 'stage/resource'
$null=New-Item -ItemType Directory -Path $resource
Copy-Item -LiteralPath (Join-Path $SourcePath 'resource/weasel.ico') -Destination $resource
$forbidden=@(Get-ChildItem -LiteralPath $data -Recurse -File|Where-Object {$_.Name -match '\.(schema|dict)\.yaml$|\.(txt|gram|lua)$'})
if($forbidden.Count){throw 'Input schemes or dictionaries reached the package stage.'}
$files=@(Get-ChildItem -LiteralPath $payload -Recurse -File|Where-Object {$_.Name -notin @('install.nsi','InstallProfilePolicy.ps1','NativeProfileSnapshot.ps1','stellae_identity.nsh')}|Sort-Object FullName|ForEach-Object{
  [ordered]@{path=[IO.Path]::GetRelativePath($payload,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
[ordered]@{version='0.17.4.61052';commit=$env:GITHUB_SHA;run=$env:GITHUB_RUN_ID;inputSchemesBundled=$false;runtimeX64='N01';runtimeX86='R5';officialInputSha256=$asset[0].sha256;files=$files}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $payload 'package-manifest.json') -Encoding utf8
& python (Join-Path $PSScriptRoot 'verify_pe.py') --root $payload --report (Join-Path $OutputDirectory 'pe-verification.json')
if($LASTEXITCODE){throw 'Product PE verification failed.'}
$null=New-Item -ItemType Directory -Path (Join-Path $payload 'archives')
$makensis=Join-Path ${env:ProgramFiles(x86)} 'NSIS/Bin/makensis.exe'
$nsisVersion=if(Test-Path -LiteralPath $makensis){(& $makensis /VERSION|Out-String).Trim()}else{''}
if($nsisVersion -cne 'v3.11'){
  & choco install nsis --version=3.11 -y --no-progress --force --allow-downgrade
  if($LASTEXITCODE -or -not (Test-Path -LiteralPath $makensis)){throw 'NSIS is not available.'}
  $nsisVersion=(& $makensis /VERSION|Out-String).Trim()
}
if($nsisVersion -cne 'v3.11'){throw 'NSIS 3.11 is required for the pinned runtime notices.'}
$packageManifest=Get-Content -LiteralPath (Join-Path $payload 'package-manifest.json') -Raw|ConvertFrom-Json
$packageManifest|Add-Member -NotePropertyName nsisVersion -NotePropertyValue $nsisVersion
$packageManifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $payload 'package-manifest.json') -Encoding utf8
& python (Join-Path $PSScriptRoot 'index_payload.py') --root $payload --repository $repository --report (Join-Path $payload 'package-license-index.json')
if($LASTEXITCODE){throw 'Payload license mapping is incomplete.'}
Push-Location $payload
try{
  & $makensis /INPUTCHARSET UTF8 /DWEASEL_VERSION=0.17.4 /DWEASEL_BUILD=61052 /DPRODUCT_VERSION=0.17.4.61052 install.nsi 2>&1|Tee-Object (Join-Path $OutputDirectory 'nsis-build.log')
  if($LASTEXITCODE){throw 'NSIS package build failed.'}
}finally{Pop-Location}
$installer=Join-Path $payload 'archives/stellae-0.17.4.61052-installer.exe'
Copy-Item -LiteralPath $installer -Destination $release
Copy-Item -LiteralPath (Join-Path $payload 'package-manifest.json'),(Join-Path $OutputDirectory 'pe-verification.json') -Destination $release
Copy-Item -LiteralPath (Join-Path $payload 'package-license-index.json') -Destination $release
# Extract the actual installer again. Staging alone is not the payload proof.
$actual=Join-Path $OutputDirectory 'payload-verification'
& 7z.exe x $installer "-o$actual" -y | Out-File (Join-Path $OutputDirectory 'extract-package.log')
if($LASTEXITCODE){throw 'Could not inspect the completed installer.'}
$bad=@(Get-ChildItem -LiteralPath $actual -Recurse -File|Where-Object {$_.Name -match '\.(schema|dict)\.yaml$|\.(pdb|gram|lua)$' -or $_.Name -eq 'essay.txt'})
if($bad.Count){throw 'A forbidden file reached the completed installer.'}
foreach($entry in $files|Where-Object {$_.path -like 'licenses/*' -or $_.path -in @('LICENSE.txt','LICENSE-DOCS','data/default.yaml')}){
  $path=Join-Path $actual $entry.path
  if(-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw "Completed payload differs: $($entry.path)"}
}
[ordered]@{passed=$true;noInputSchemes=$true;noSymbols=$true;noticeFilesVerified=@($files|Where-Object {$_.path -like 'licenses/*'}).Count;installerSha256=(Get-FileHash -LiteralPath $installer).Hash.ToLowerInvariant()}|ConvertTo-Json|Set-Content (Join-Path $release 'payload-verification.json') -Encoding utf8
$sourceParts=Join-Path $OutputDirectory 'source-parts'
$null=New-Item -ItemType Directory -Path $sourceParts
$projectArchive=Join-Path $sourceParts 'project-source.zip'
Push-Location $repository
try{
  & git archive --format=zip --output=$projectArchive HEAD
  if($LASTEXITCODE){throw 'Public source archive creation failed.'}
}finally{Pop-Location}
Copy-Item -LiteralPath (Join-Path $FrontendOutput 'assembled-source.zip') -Destination (Join-Path $sourceParts 'frontend-source.zip')
foreach($variant in @('engine-r5-x64','engine-r5-x86','engine-n01-x64')){
  $archive=Join-Path $SdkRoot "$variant/assembled-source.zip"
  if(-not (Test-Path -LiteralPath $archive)){throw "Missing same-run assembled engine source: $variant"}
  Copy-Item -LiteralPath $archive -Destination (Join-Path $sourceParts "$variant-source.zip")
}
Copy-Item -LiteralPath (Join-Path $repository 'docs/SOURCES.md') -Destination $sourceParts
$sourceArchive=Join-Path $release 'stellae-0.17.4.61052-source.zip'
Compress-Archive -Path (Join-Path $sourceParts '*') -DestinationPath $sourceArchive -CompressionLevel Optimal
Get-ChildItem -LiteralPath $release -File|Sort-Object Name|ForEach-Object{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$_.Name}|Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS.txt') -Encoding ascii
Write-Output "PACKAGE_OUTPUT $OutputDirectory"
