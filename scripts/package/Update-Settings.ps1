# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$PayloadDirectory,
  [string]$ProgramDirectory=(Join-Path $env:ProgramFiles 'RimeStellae'),
  [string]$ReportFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$program=[IO.Path]::GetFullPath($ProgramDirectory).TrimEnd([char[]]'\/')
$payload=[IO.Path]::GetFullPath($PayloadDirectory).TrimEnd([char[]]'\/')
$baselineDeployer='d5d9330446fa233b04e143e53a6d2a0d9499adfc107544915d6dd1a58cb026f6'
$themeIds=@('reference_gray','stellae_sakura','stellae_lavender','stellae_night','stellae_crimson','stellae_mono')
$allowed=@('StellaeDeployer.exe','data/stellae_bundle_weasel.yaml')+
 @($themeIds|ForEach-Object {'data/preview/color_scheme_'+$_.ToString()+'.png'})+
 @('candidate_font','candidate_font_default','candidate_font_sc','candidate_font_tc','candidate_font_hk'|ForEach-Object {'data/preview/'+$_.ToString()+'.png'})
$retired=@('default','sc','tc','hk'|ForEach-Object {'data/preview/color_scheme_reference_gray_'+$_.ToString()+'.png'})
function Child([string]$Root,[string]$Relative){
 if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Invalid relative settings path.'}
 $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $path.StartsWith($Root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'A settings path escapes its root.'}
 $current=$path
 while($current -and $current.Length -ge $Root.Length){
  if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A settings path is redirected.'}}
  $current=Split-Path $current -Parent
 }
 return $path
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-X64([string]$Path){
 $stream=[IO.File]::OpenRead($Path)
 $reader=[IO.BinaryReader]::new($stream)
 try{
  if($reader.ReadUInt16() -ne 0x5a4d){throw 'Expected a Windows image.'}
  $stream.Position=0x3c;$pe=$reader.ReadUInt32();$stream.Position=$pe
  if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw 'The settings update requires an installed x64 frontend.'}
 }finally{$reader.Dispose();$stream.Dispose()}
}
function Write-Atomic([string]$Path,[byte[]]$Bytes){
 $parent=Split-Path $Path -Parent
 $null=New-Item -ItemType Directory -Path $parent -Force
 $temporary=Join-Path $parent ('.'+(Split-Path $Path -Leaf)+'.settings-'+[guid]::NewGuid().ToString('N')+'.tmp')
 [IO.File]::WriteAllBytes($temporary,$Bytes)
 if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,$null)}else{[IO.File]::Move($temporary,$Path)}
}
if(-not [Environment]::Is64BitOperatingSystem -or -not (Test-Path -LiteralPath $program -PathType Container)){throw 'An installed x64 frontend is required.'}
Require-X64 (Child $program 'StellaeServer.exe')
Require-X64 (Child $program 'StellaeDeployer.exe')
if(@(Get-Process StellaeDeployer -ErrorAction SilentlyContinue).Count){throw 'Close the appearance/settings tool before updating it.'}
$spec=Get-Content -LiteralPath (Child $payload 'settings-update-inputs.json') -Raw|ConvertFrom-Json
if($spec.format -cne 'stellae-settings-update-v1' -or $spec.sourceRef -cnotmatch '^[0-9a-f]{40}$' -or
 $spec.componentVersion -cnotmatch '^[0-9]+(\.[0-9]+){2,3}$'){throw 'Invalid settings component manifest.'}
$names=@($spec.files|ForEach-Object {[string]$_.path})
if($names.Count -ne 13 -or @($names|Select-Object -Unique).Count -ne 13 -or
 (Compare-Object ($allowed|Sort-Object) ($names|Sort-Object))){throw 'The settings payload must contain exactly the thirteen supported files.'}
$retiredNames=@($spec.retiredPreviewFiles|ForEach-Object {[string]$_.path})
if($retiredNames.Count -ne 4 -or @($retiredNames|Select-Object -Unique).Count -ne 4 -or
 (Compare-Object ($retired|Sort-Object) ($retiredNames|Sort-Object))){throw 'Invalid retired settings preview list.'}
$ownershipPath=Child $program 'data/stellae-managed-files.json'
$ownership=Get-Content -LiteralPath $ownershipPath -Raw|ConvertFrom-Json
if($ownership.format -cne 'stellae-managed-shared-v1'){throw 'The installed ownership manifest is unsupported.'}
$owned=@{}
foreach($entry in $ownership.files){
 if($owned.ContainsKey([string]$entry.path)){throw 'The installed ownership manifest has duplicate paths.'}
 $owned[[string]$entry.path]=$entry
}
$markerPath=Child $program 'settings-component.json'
if(Test-Path -LiteralPath $markerPath){
 $oldMarker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
 if($oldMarker.format -cne 'stellae-settings-component-v1'){throw 'An unrelated component marker is preserved; resolve its conflict first.'}
}
foreach($entry in $spec.files){
 if($entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$entry.bytes -le 0){throw 'Invalid settings file record.'}
 $origin=Child $payload $entry.path
 if((Hash $origin) -cne $entry.sha256 -or (Get-Item -LiteralPath $origin).Length -ne [long]$entry.bytes){throw 'A settings payload file differs from its manifest.'}
 $target=Child $program $entry.path
 if(Test-Path -LiteralPath $target){
  $current=Hash $target
  $previous=if($entry.PSObject.Properties['previousSha256']){@($entry.previousSha256)}else{@()}
  $known=if($entry.path -ceq 'StellaeDeployer.exe'){@($baselineDeployer,$entry.sha256)}else{@($entry.sha256)+$previous}
  if($current -cnotin $known){throw ('An unknown installed file is preserved; resolve its conflict first: '+$entry.path)}
 }
 if($entry.path -ceq 'StellaeDeployer.exe'){Require-X64 $origin}
}
foreach($entry in $spec.retiredPreviewFiles){
 if($entry.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid retired preview checksum.'}
 $null=Child $program $entry.path
}
# All checks above are read-only. No engine, service, registry, or user profile is changed.
$installed=@();$removed=@();$preserved=@()
foreach($entry in $spec.files){
 $target=Child $program $entry.path
 if(-not (Test-Path -LiteralPath $target) -or (Hash $target) -cne $entry.sha256){
  Write-Atomic $target ([IO.File]::ReadAllBytes((Child $payload $entry.path)))
 }
 if((Hash $target) -cne $entry.sha256){throw 'A settings file did not install correctly.'}
 $installed+=@([string]$entry.path)
 if($entry.path.StartsWith('data/',[StringComparison]::Ordinal)){
  $relative=$entry.path.Substring(5)
  $record=[ordered]@{}
  if($owned.ContainsKey($relative)){foreach($property in $owned[$relative].PSObject.Properties){$record[$property.Name]=$property.Value}}
  $record['path']=$relative;$record['bytes']=[long]$entry.bytes;$record['sha256']=[string]$entry.sha256
  $owned[$relative]=[pscustomobject]$record
 }
}
foreach($entry in $spec.retiredPreviewFiles){
 $target=Child $program $entry.path
 if(Test-Path -LiteralPath $target){
  if((Hash $target) -ceq $entry.sha256){Remove-Item -LiteralPath $target;$removed+=@([string]$entry.path);$owned.Remove($entry.path.Substring(5))}
  else{$preserved+=@([string]$entry.path)}
 }
}
$ownership.files=@($owned.Values|Sort-Object path)
$encoding=[Text.UTF8Encoding]::new($false)
Write-Atomic $ownershipPath ($encoding.GetBytes(($ownership|ConvertTo-Json -Depth 20)+[Environment]::NewLine))
$deployer=@($spec.files|Where-Object path -CEQ 'StellaeDeployer.exe')[0]
$marker=[ordered]@{format='stellae-settings-component-v1';componentVersion=$spec.componentVersion;sourceRef=$spec.sourceRef;deployerSha256=$deployer.sha256;files=$spec.files;baseBundleVersion=$ownership.bundleVersion}
Write-Atomic $markerPath ($encoding.GetBytes(($marker|ConvertTo-Json -Depth 20)+[Environment]::NewLine))
$report=[ordered]@{passed=$true;componentVersion=$spec.componentVersion;sourceRef=$spec.sourceRef;installed=$installed;removedOwnedPreviews=$removed;preservedCustomPreviews=$preserved;ownedSharedFilesAfter=@($ownership.files).Count;engineChanged=$false;servicesChanged=$false;userProfileChanged=$false;registryChanged=$false;fullPackageVersionChanged=$false}
if($ReportFile){
 $reportPath=[IO.Path]::GetFullPath($ReportFile)
 $null=New-Item -ItemType Directory -Path (Split-Path $reportPath) -Force
 [IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 20)+[Environment]::NewLine,$encoding)
}
$report|ConvertTo-Json -Depth 20
