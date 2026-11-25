# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][ValidateSet('Install','Uninstall','InstallNotices','UninstallNotices','EnsureMathIndex')][string]$Action,
  [Parameter(Mandatory)][string]$SharedDirectory,
  [string]$PayloadDirectory,
  [string]$UserDirectory,
  [switch]$DeferMathIndex,
  [string]$ReportFile,
  [string]$CurrentPackageManifest,
  [string]$PreviousPackageManifest
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
$notices=$Action -in @('InstallNotices','UninstallNotices')
$operation=if($Action -in @('Uninstall','UninstallNotices')){'Uninstall'}else{'Install'}
$manifestPath=Join-Path $shared 'stellae-managed-files.json'
$previous=@{}
$hadManagedManifest=(-not $notices) -and (Test-Path -LiteralPath $manifestPath)
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
function Read-NoticesPackage([string]$Path){
  if(-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  $package=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
  $bundled=$package.PSObject.Properties['inputSchemesBundled']
  # The bare frontend declares no scheme ownership and has no format field.
  if($bundled -and $bundled.Value -is [bool] -and -not $bundled.Value){return $null}
  $format=$package.PSObject.Properties['format']
  if(-not $format -or $format.Value -cnotin @('stellae-package-v2','stellae-rymcp-package-v1') -or
     -not $bundled -or $bundled.Value -isnot [bool] -or -not $bundled.Value){throw 'Unexpected installed package ownership manifest'}
  $records=@()
  $names=@{}
  foreach($entry in $package.files){
    $name=if($entry.PSObject.Properties['installed_path']){[string]$entry.installed_path}else{[string]$entry.path}
    if(-not $name.StartsWith('scheme-notices/',[StringComparison]::Ordinal)){continue}
    $relative=$name.Substring('scheme-notices/'.Length)
    $null=Resolve-Child $shared $relative
    if($names.ContainsKey($relative) -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid notice ownership record'}
    $names[$relative]=$true
    $records+=@([pscustomobject]@{path=$relative;sha256=[string]$entry.sha256})
  }
  return [pscustomobject]@{bundleVersion=$package.bundleVersion;files=$records}
}
if($notices -and $PreviousPackageManifest){
  $priorNotices=Read-NoticesPackage $PreviousPackageManifest
  if($priorNotices){foreach($entry in $priorNotices.files){$previous[$entry.path]=$entry}}
}
function Add-LegacyMathIndex($Migration,$MigrationDirectory,[string]$UserRoot){
  $math=Resolve-Child $UserRoot 'stellae_dlc/math'
  $catalog=Resolve-Child $math 'english.tsv'
  $manifest=Resolve-Child $math 'manifest.tsv'
  if(-not (Test-Path -LiteralPath $catalog -PathType Leaf) -or
     -not (Test-Path -LiteralPath $manifest -PathType Leaf)){return 'not-present'}
  # The prepared English index depends on this exact catalog; Chinese header
  # namespace changes may legitimately alter the module's file manifest.
  if((Hash $catalog) -cne $Migration.catalogSha256){return 'preserved-catalog'}

  $index=Resolve-Child $math 'english_index'
  if((Test-Path -LiteralPath $index) -and -not (Test-Path -LiteralPath $index -PathType Container)){
    return 'preserved-index'
  }
  $names=@($Migration.index | ForEach-Object {$_.name} | Sort-Object)
  if(($names -join ',') -cne 'keys.bin,postings.bin,words.txt'){throw 'Unexpected math index migration files'}
  $pending=@()
  foreach($entry in $Migration.index){
    $origin=Resolve-Child $MigrationDirectory ('math/english_index/'+$entry.name)
    if((Hash $origin) -cne $entry.sha256){throw 'Prepared math index differs from the migration manifest'}
    $target=Resolve-Child $index $entry.name
    if(Test-Path -LiteralPath $target){
      if(-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Hash $target) -cne $entry.sha256){
        return 'preserved-index'
      }
    }else{
      $pending+=@([pscustomobject]@{name=$entry.name;origin=$origin;target=$target;sha256=$entry.sha256})
    }
  }
  if($pending.Count -eq 0){return 'current'}

  $stage=Resolve-Child $math ('.english-index-'+[Guid]::NewGuid().ToString('N'))
  $null=New-Item -ItemType Directory -Path $stage
  $added=@()
  try{
    foreach($entry in $pending){
      $file=Join-Path $stage $entry.name
      [IO.File]::Copy($entry.origin,$file,$false)
      if((Hash $file) -cne $entry.sha256){throw 'Staged math index differs from the migration manifest'}
    }
    if(-not (Test-Path -LiteralPath $index)){
      [IO.Directory]::Move($stage,$index)
    }else{
      foreach($entry in $pending){
        [IO.File]::Move((Join-Path $stage $entry.name),$entry.target)
        $added+=@($entry)
      }
    }
  }catch{
    foreach($entry in $added){
      if((Test-Path -LiteralPath $entry.target -PathType Leaf) -and (Hash $entry.target) -ceq $entry.sha256){
        [IO.File]::Delete($entry.target)
      }
    }
    throw
  }finally{
    if(Test-Path -LiteralPath $stage -PathType Container){
      foreach($entry in $pending){[IO.File]::Delete((Join-Path $stage $entry.name))}
      [IO.Directory]::Delete($stage)
    }
  }
  return 'installed'
}
$report=[ordered]@{format=$(if($notices){'stellae-notices-update-v1'}else{'stellae-shared-update-v1'});action=$Action;passed=$false;sharedConflicts=@();userOverrides=@();removed=@();installed=@();upgradedUserLua=@();mathIndex='not-requested';retiredUserSources=@();userSourceConflicts=@();compatibilitySourcesRetained=@();manualMergeRequired=$false}
if($Action -in @('Install','EnsureMathIndex') -and -not $UserDirectory){
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
  try{$key=$base.OpenSubKey('Software\RimeStellae');try{if($key){$UserDirectory=[string]$key.GetValue('RimeUserDir','')}}finally{if($key){$key.Dispose()}}}finally{$base.Dispose()}
  if(-not $UserDirectory){$UserDirectory=Join-Path $env:APPDATA 'RimeStellae'}
}
if($Action -eq 'EnsureMathIndex'){
  if(-not $PayloadDirectory){throw 'A prepared index payload is required'}
  $migrationDirectory=Resolve-Child ([IO.Path]::GetFullPath($PayloadDirectory)) 'migrations'
  $migrationPath=Resolve-Child $migrationDirectory 'upgrade.json'
  if(Test-Path -LiteralPath $migrationPath -PathType Leaf){
    $migration=Get-Content -LiteralPath $migrationPath -Raw|ConvertFrom-Json
    if($migration.format -cne 'stellae-bundle-user-upgrade-v1'){throw 'Unexpected user upgrade format'}
    $report.mathIndex=Add-LegacyMathIndex $migration.math $migrationDirectory $UserDirectory
  }
  $report.format='stellae-math-index-update-v1';$report.passed=$true
  if($ReportFile){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ReportFile -Encoding UTF8}
  Write-Output ('Prepared math index: '+$report.mathIndex)
  return
}
if($operation -eq 'Uninstall'){
  foreach($entry in $previous.Values){
    $path=Resolve-Child $shared $entry.path
    if(Test-Path -LiteralPath $path -PathType Leaf){
      if((Hash $path) -ceq $entry.sha256){Remove-Item -LiteralPath $path;$report.removed+=@($entry.path)}
      else{$report.sharedConflicts+=@($entry.path)}
    }
  }
  if(-not $notices -and (Test-Path -LiteralPath $manifestPath)){Remove-Item -LiteralPath $manifestPath}
}else{
  if(-not $PayloadDirectory){throw 'A shared payload is required'}
  $payload=[IO.Path]::GetFullPath($PayloadDirectory)
  $sourceRoot=if($notices){$payload}else{Join-Path $payload 'data'}
  if($notices){
    $spec=Read-NoticesPackage $CurrentPackageManifest
    if(-not $spec -or -not @($spec.files).Count){throw 'The new package has no notices ownership records'}
  }else{$spec=Get-Content -LiteralPath (Join-Path $payload 'shared-manifest.json') -Raw|ConvertFrom-Json}
  $layoutFiles=@{}
  $retireUserSources=@()
  $retainLegacyLua=$false
  if(-not $notices){
    $migrationDirectory=Resolve-Child $payload 'migrations'
    $layoutPath=Resolve-Child $migrationDirectory 'source-layout.json'
    if(Test-Path -LiteralPath $layoutPath -PathType Leaf){
      $layout=Get-Content -LiteralPath $layoutPath -Raw|ConvertFrom-Json
      if($layout.format -cne 'stellae-source-layout-upgrade-v1' -or $layout.previousSourceRef -cnotmatch '^[0-9a-f]{40}$'){throw 'Unexpected source layout migration'}
      $incoming=@{}
      foreach($entry in $spec.files){$incoming[$entry.path]=$entry.sha256}
      foreach($entry in $layout.files){
        $null=Resolve-Child $UserDirectory $entry.path
        if($layoutFiles.ContainsKey($entry.path) -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
           $entry.group -cnotin @('lua','configuration') -or
           ($entry.group -ceq 'lua' -and $entry.path -cne 'rime.lua' -and $entry.path -cnotmatch '^lua/[A-Za-z0-9_]+\.lua$') -or
           ($entry.group -ceq 'configuration' -and $entry.path -cnotmatch '\.yaml$')){throw 'Invalid source layout record'}
        $layoutFiles[$entry.path]=$entry
        # AppearanceConfig retains the old custom file until the new frontend
        # configuration has compiled, including unchanged former presets.
        if($entry.path -ceq 'weasel.custom.yaml' -and $incoming.ContainsKey('stellae.yaml')){continue}
        $target=Resolve-Child $UserDirectory $entry.path
        if(Test-Path -LiteralPath $target -PathType Leaf){
          $current=Hash $target
          $previousPath=if($entry.path -ceq 'default.custom.yaml'){'stellae_bundle_default.yaml'}else{$entry.path}
          $knownPrevious=($previous.ContainsKey($entry.path) -and $current -ceq $previous[$entry.path].sha256) -or
            ($previous.ContainsKey($previousPath) -and $current -ceq $previous[$previousPath].sha256)
          if($current -ceq $entry.sha256 -or $knownPrevious){
            $retireUserSources+=@([pscustomobject]@{path=$entry.path;sha256=$current;group=$entry.group})
          }
          elseif(-not $incoming.ContainsKey($entry.path) -or $current -cne $incoming[$entry.path]){
            $report.userSourceConflicts+=@($entry.path)
            if($entry.group -ceq 'lua'){$retainLegacyLua=$true}
          }
        }
        # Keep the entire previous Lua group when a modified old shared source
        # still needs its flat dependencies. Current-layout files are ignored.
        if($entry.group -ceq 'lua'){
          $legacy=Resolve-Child $shared $entry.path
          if(Test-Path -LiteralPath $legacy -PathType Leaf){
            $current=Hash $legacy
            $knownPrevious=$previous.ContainsKey($entry.path) -and $current -ceq $previous[$entry.path].sha256
            if($current -cne $entry.sha256 -and -not $knownPrevious -and (-not $incoming.ContainsKey($entry.path) -or $current -cne $incoming[$entry.path])){
              $retainLegacyLua=$true
              $report.sharedConflicts+=@($entry.path)
            }
          }
        }
      }
      $report.manualMergeRequired=$retainLegacyLua -or $report.userSourceConflicts.Count -gt 0
      $report.sourceLayoutPreviousRef=$layout.previousSourceRef
    }
  }
  # Adopt only unchanged files from the hash-pinned public bare distribution.
  # Existing bundle ownership always takes precedence over predecessor hints.
  if(-not $notices -and -not $hadManagedManifest -and $null -ne $spec.PSObject.Properties['predecessors']){
    foreach($entry in $spec.predecessors){
      $path=Resolve-Child $shared $entry.path
      if((Test-Path -LiteralPath $path -PathType Leaf) -and (Hash $path) -ceq $entry.sha256){$previous[$entry.path]=$entry}
    }
  }
  $retained=@{}
  $declared=@{}
  foreach($entry in $spec.files){
    if($declared.ContainsKey($entry.path)){throw 'Duplicate shared path'}
    $declared[$entry.path]=$entry
    $origin=Resolve-Child $sourceRoot $entry.path
    if(-not (Test-Path -LiteralPath $origin -PathType Leaf) -or (Hash $origin) -cne $entry.sha256){throw 'Shared payload bytes differ from the manifest'}
    $target=Resolve-Child $shared $entry.path
    if($retainLegacyLua -and $entry.path -ceq 'rime.lua' -and (Test-Path -LiteralPath $target -PathType Leaf)){
      $report.compatibilitySourcesRetained+=@($entry.path)
      if($previous.ContainsKey($entry.path)){$retained[$entry.path]=$previous[$entry.path]}
      continue
    }
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
      if($retainLegacyLua -and $layoutFiles.ContainsKey($entry.path) -and $layoutFiles[$entry.path].group -ceq 'lua'){
        $retained[$entry.path]=$entry
        $report.compatibilitySourcesRetained+=@($entry.path)
        continue
      }
      if((Hash $path) -ceq $entry.sha256){Remove-Item -LiteralPath $path;$report.removed+=@($entry.path)}
      else{$report.sharedConflicts+=@($entry.path);$retained[$entry.path]=$entry}
    }
  }
  if(-not $notices){
  [ordered]@{format='stellae-managed-shared-v1';bundleVersion=$spec.bundleVersion;files=@($retained.Values|Sort-Object path)}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8
  foreach($entry in $retireUserSources){
    if($retainLegacyLua -and $entry.group -ceq 'lua'){continue}
    $target=Resolve-Child $UserDirectory $entry.path
    if((Test-Path -LiteralPath $target -PathType Leaf) -and (Hash $target) -ceq $entry.sha256){
      Remove-Item -LiteralPath $target
      $report.retiredUserSources+=@($entry.path)
    }
  }
  $migrationDirectory=Resolve-Child $payload 'migrations'
  $migrationPath=Resolve-Child $migrationDirectory 'upgrade.json'
  if(Test-Path -LiteralPath $migrationPath -PathType Leaf){
    $migration=Get-Content -LiteralPath $migrationPath -Raw|ConvertFrom-Json
    if($migration.format -cne 'stellae-bundle-user-upgrade-v1'){throw 'Unexpected user upgrade format'}
    foreach($entry in $migration.previousLua){
      if($entry.path -cnotin @('lua/cn_translator.lua','lua/en_dlc.lua')){
        throw 'Unexpected prior Lua migration path'
      }
      # The versioned source-layout policy retires old paths after the move.
      if(-not $declared.ContainsKey($entry.path) -or $retainLegacyLua){continue}
      $target=Resolve-Child $UserDirectory $entry.path
      if(-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Hash $target) -cne $entry.sha256){continue}
      $origin=Resolve-Child (Join-Path $payload 'data') $entry.path
      $stage=Join-Path (Split-Path $target -Parent) ('.bundle-'+[Guid]::NewGuid().ToString('N'))
      try{
        [IO.File]::Copy($origin,$stage,$false)
        if((Hash $stage) -cne $declared[$entry.path].sha256){throw 'Staged Lua differs from the shared manifest'}
        $backup=$stage+'.backup'
        [IO.File]::Replace($stage,$target,$backup)
        [IO.File]::Delete($backup)
        $report.upgradedUserLua+=@($entry.path)
      }finally{[IO.File]::Delete($stage)}
    }
    $report.mathIndex=if($DeferMathIndex){'deferred'}else{Add-LegacyMathIndex $migration.math $migrationDirectory $UserDirectory}
  }
  # Only test source/configuration path presence. Never open a learning database.
  $overridePaths=@('default.custom.yaml','stellae.custom.yaml')+@($spec.files|ForEach-Object {$_.path})
  foreach($relative in @($overridePaths|Sort-Object -Unique)){
    $path=Resolve-Child $UserDirectory $relative
    if(Test-Path -LiteralPath $path -PathType Leaf){$report.userOverrides+=@($relative)}
  }
  }
  $report.bundleVersion=$spec.bundleVersion
}
# Visit only parents of declared managed paths, never unknown directory trees.
$parents=@{}
$entries=@($previous.Values)
if($operation -eq 'Install'){$entries+=@($spec.files)}
foreach($entry in $entries){
  $path=Split-Path (Resolve-Child $shared $entry.path) -Parent
  while($path -and $path.Length -gt $shared.Length){$parents[$path]=$true;$path=Split-Path $path -Parent}
}
foreach($directory in @($parents.Keys|Sort-Object Length -Descending)){
  if((Test-Path -LiteralPath $directory -PathType Container) -and -not @(Get-ChildItem -LiteralPath $directory -Force).Count){Remove-Item -LiteralPath $directory}
}
$report.passed=$true
if($ReportFile){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ReportFile -Encoding UTF8}
$scope=if($notices){'Scheme notices'}else{'Shared'}
Write-Output ($scope+' update completed; preserved conflicts: '+$report.sharedConflicts.Count+'; user overrides: '+$report.userOverrides.Count)
