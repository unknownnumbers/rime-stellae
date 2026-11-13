# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][ValidateSet('Install','Uninstall')][string]$Action,
  [Parameter(Mandatory)][string]$SharedDirectory,
  [string]$PayloadDirectory,
  [string]$UserDirectory,
  [string]$ReportFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
trap {
  if($env:GITHUB_ACTIONS -eq 'true' -and $ReportFile){
    [ordered]@{passed=$false;stage='shared-helper';errorType=$_.Exception.GetType().FullName;hresult=$_.Exception.HResult;sourceLine=$_.InvocationInfo.ScriptLineNumber}|ConvertTo-Json|Set-Content -LiteralPath $ReportFile -Encoding UTF8
  }
  throw
}
$shared=[IO.Path]::GetFullPath($SharedDirectory)
if(-not (Test-Path -LiteralPath $shared)){$null=New-Item -ItemType Directory -Path $shared -Force}
$manifestPath=Join-Path $shared 'stellae-managed-files.json'
$previous=@{}
$hadManagedManifest=Test-Path -LiteralPath $manifestPath
if($hadManagedManifest){
  $old=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  foreach($entry in $old.files){$previous[$entry.path]=$entry}
}
function Resolve-Child([string]$Root,[string]$Relative){
  if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:') {throw 'Invalid managed relative path'}
  $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
  $path=[IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
  if(-not $path.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Managed path escapes its root'}
  $parent=$path
  while($parent -and $parent.Length -ge $rootPath.Length){
    if(Test-Path -LiteralPath $parent){
      $item=Get-Item -LiteralPath $parent -Force
      if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A managed path contains a reparse point'}
    }
    $parent=Split-Path $parent -Parent
  }
  return $path
}
function Hash([string]$Path){
  $algorithm=[Security.Cryptography.SHA256]::Create()
  $stream=$null
  try{
    $stream=[IO.File]::OpenRead($Path)
    return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
  }finally{if($stream){$stream.Dispose()};$algorithm.Dispose()}
}
$report=[ordered]@{format='stellae-shared-update-v1';action=$Action;passed=$false;sharedConflicts=@();userOverrides=@();removed=@();installed=@()}
if($Action -eq 'Uninstall'){
  foreach($entry in $previous.Values){
    $path=Resolve-Child $shared $entry.path
    if(Test-Path -LiteralPath $path -PathType Leaf){
      if((Hash $path) -ceq $entry.sha256){Remove-Item -LiteralPath $path;$report.removed+=@($entry.path)}
      else{$report.sharedConflicts+=@($entry.path)}
    }
  }
  if(Test-Path -LiteralPath $manifestPath){Remove-Item -LiteralPath $manifestPath}
}else{
  if(-not $PayloadDirectory){throw 'A shared payload is required'}
  $payload=[IO.Path]::GetFullPath($PayloadDirectory)
  $spec=Get-Content -LiteralPath (Join-Path $payload 'shared-manifest.json') -Raw|ConvertFrom-Json
  # Adopt only unchanged files from the hash-pinned public bare distribution.
  # Existing bundle ownership always takes precedence over predecessor hints.
  if(-not $hadManagedManifest -and $null -ne $spec.PSObject.Properties['predecessors']){
    foreach($entry in $spec.predecessors){
      $path=Resolve-Child $shared $entry.path
      if((Test-Path -LiteralPath $path -PathType Leaf) -and (Hash $path) -ceq $entry.sha256){$previous[$entry.path]=$entry}
    }
  }
  $retained=@{}
  $declared=@{}
  foreach($entry in $spec.files){
    if($declared.ContainsKey($entry.path)){throw 'Duplicate shared path'}
    $declared[$entry.path]=$true
    $origin=Resolve-Child (Join-Path $payload 'data') $entry.path
    if(-not (Test-Path -LiteralPath $origin -PathType Leaf) -or (Hash $origin) -cne $entry.sha256){throw 'Shared payload bytes differ from the manifest'}
    $target=Resolve-Child $shared $entry.path
    if(Test-Path -LiteralPath $target){
      $current=Hash $target
      $known=$previous.ContainsKey($entry.path) -and $current -ceq $previous[$entry.path].sha256
      if($current -cne $entry.sha256 -and -not $known){
        $report.sharedConflicts+=@($entry.path)
        if($previous.ContainsKey($entry.path)){$retained[$entry.path]=$previous[$entry.path]}
        continue
      }
    }
    $null=New-Item -ItemType Directory -Path (Split-Path $target) -Force
    Copy-Item -LiteralPath $origin -Destination $target -Force
    if((Hash $target) -cne $entry.sha256){throw 'Installed shared bytes differ'}
    $retained[$entry.path]=$entry
    $report.installed+=@($entry.path)
  }
  foreach($entry in $previous.Values){
    if($declared.ContainsKey($entry.path)){continue}
    $path=Resolve-Child $shared $entry.path
    if(Test-Path -LiteralPath $path -PathType Leaf){
      if((Hash $path) -ceq $entry.sha256){Remove-Item -LiteralPath $path;$report.removed+=@($entry.path)}
      else{$report.sharedConflicts+=@($entry.path);$retained[$entry.path]=$entry}
    }
  }
  [ordered]@{format='stellae-managed-shared-v1';bundleVersion=$spec.bundleVersion;files=@($retained.Values|Sort-Object path)}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8
  if(-not $UserDirectory){
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
    try{$key=$base.OpenSubKey('Software\RimeStellae');try{if($key){$UserDirectory=[string]$key.GetValue('RimeUserDir','')}}finally{if($key){$key.Dispose()}}}finally{$base.Dispose()}
    if(-not $UserDirectory){$UserDirectory=Join-Path $env:APPDATA 'RimeStellae'}
  }
  # Only test source/configuration path presence. Never open a learning database.
  $overridePaths=@('default.custom.yaml','weasel.custom.yaml')+@($spec.files|ForEach-Object {$_.path})
  foreach($relative in @($overridePaths|Sort-Object -Unique)){
    $path=Resolve-Child $UserDirectory $relative
    if(Test-Path -LiteralPath $path -PathType Leaf){$report.userOverrides+=@($relative)}
  }
  $report.bundleVersion=$spec.bundleVersion
}
# Visit only parents of declared managed paths, never unknown directory trees.
$parents=@{}
$entries=@($previous.Values)
if($Action -eq 'Install'){$entries+=@($spec.files)}
foreach($entry in $entries){
  $path=Split-Path (Resolve-Child $shared $entry.path) -Parent
  while($path -and $path.Length -gt $shared.Length){$parents[$path]=$true;$path=Split-Path $path -Parent}
}
foreach($directory in @($parents.Keys|Sort-Object Length -Descending)){
  if((Test-Path -LiteralPath $directory -PathType Container) -and -not @(Get-ChildItem -LiteralPath $directory -Force).Count){Remove-Item -LiteralPath $directory}
}
$report.passed=$true
if($ReportFile){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ReportFile -Encoding UTF8}
Write-Output ('Shared update completed; preserved conflicts: '+$report.sharedConflicts.Count+'; user overrides: '+$report.userOverrides.Count)
