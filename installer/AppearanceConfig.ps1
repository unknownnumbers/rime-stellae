# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][ValidateSet('Preflight','Migrate','Finalize')][string]$Action,
  [string]$UserDirectory,
  [string]$SharedDirectory,
  [string]$SharedManifest,
  [string]$SourceLayout,
  [string]$PreflightReport,
  [string]$BackupDirectory,
  [string]$ReportFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Child([string]$Root,[string]$Relative){
  if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Invalid appearance migration path'}
  $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
  $path=[IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
  if(-not $path.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Appearance migration path escapes its root'}
  $current=$path
  while($current -and $current.Length -ge $rootPath.Length){
    if(Test-Path -LiteralPath $current){
      if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An appearance migration path is redirected'}
    }
    $current=Split-Path $current -Parent
  }
  return $path
}
function Hash([string]$Path){
  $algorithm=[Security.Cryptography.SHA256]::Create()
  $stream=$null
  try{$stream=[IO.File]::OpenRead($Path);return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
  finally{if($stream){$stream.Dispose()};$algorithm.Dispose()}
}
function File-Present([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){return $false}
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'An appearance configuration path is not a file'}
  return $true
}
if(-not $UserDirectory){
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
  try{$key=$base.OpenSubKey('Software\RimeStellae');try{if($key){$UserDirectory=[string]$key.GetValue('RimeUserDir','')}}finally{if($key){$key.Dispose()}}}finally{$base.Dispose()}
  if(-not $UserDirectory){$UserDirectory=Join-Path $env:APPDATA 'RimeStellae'}
}
$user=[IO.Path]::GetFullPath($UserDirectory).TrimEnd([char[]]'\/')
$old=Child $user 'weasel.custom.yaml'
$new=Child $user 'stellae.custom.yaml'
$oldPresent=File-Present $old
$newPresent=File-Present $new
$oldHash=if($oldPresent){Hash $old}else{$null}
$newHash=if($newPresent){Hash $new}else{$null}
if($oldPresent -and $newPresent -and $oldHash -cne $newHash){
  throw 'weasel.custom.yaml and stellae.custom.yaml differ. Merge their appearance settings into stellae.custom.yaml and move the old file outside the user directory before upgrading. No configuration was changed.'
}
$legacyShared=@()
if($SharedDirectory){
  $shared=[IO.Path]::GetFullPath($SharedDirectory).TrimEnd([char[]]'\/')
  $known=@{}
  if($PreflightReport){
    $prior=Get-Content -LiteralPath $PreflightReport -Raw -Encoding UTF8|ConvertFrom-Json
    if($prior.format -cne 'stellae-appearance-config-migration-v1' -or -not $prior.passed -or
       $prior.userDirectory -ine $user){throw 'Unexpected appearance preflight report'}
    foreach($entry in $prior.legacySharedFiles){
      if($entry.path -cnotin @('weasel.yaml','weasel.custom.yaml','stellae_bundle_weasel.yaml') -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid appearance preflight ownership record'}
      $known[[string]$entry.path]=[string]$entry.sha256
    }
  }
  $ownership=Child $shared 'stellae-managed-files.json'
  if(File-Present $ownership){
    $managed=Get-Content -LiteralPath $ownership -Raw -Encoding UTF8|ConvertFrom-Json
    if($managed.format -cne 'stellae-managed-shared-v1'){throw 'Unexpected shared appearance ownership manifest'}
    foreach($entry in $managed.files){$known[[string]$entry.path]=[string]$entry.sha256}
  }elseif($SharedManifest){
    $incoming=Get-Content -LiteralPath $SharedManifest -Raw -Encoding UTF8|ConvertFrom-Json
    if($incoming.PSObject.Properties['predecessors']){foreach($entry in $incoming.predecessors){$known[[string]$entry.path]=[string]$entry.sha256}}
  }else{
    $package=Join-Path (Split-Path $shared -Parent) 'package-manifest.json'
    if(Test-Path -LiteralPath $package -PathType Leaf){
      $metadata=Get-Content -LiteralPath $package -Raw -Encoding UTF8|ConvertFrom-Json
      foreach($entry in $metadata.files){
        $name=if($entry.PSObject.Properties['installed_path']){[string]$entry.installed_path}else{[string]$entry.path}
        if($name.StartsWith('data/',[StringComparison]::Ordinal)){$known[$name.Substring(5)]=[string]$entry.sha256}
      }
    }
  }
  foreach($relative in @('weasel.yaml','weasel.custom.yaml','stellae_bundle_weasel.yaml')){
    $path=Child $shared $relative
    if(File-Present $path){
      $hash=Hash $path
      if(-not $known.ContainsKey($relative) -or $hash -cne $known[$relative]){
        throw ('An unrecognized or modified shared appearance file needs a manual merge before upgrading: '+$relative)
      }
      $legacyShared+=@([pscustomobject]@{path=$path;relative=$relative;sha256=$hash})
    }
  }
}
if($Action -eq 'Preflight' -and $SourceLayout){
  if(-not $SharedDirectory){throw 'Source layout preflight requires the product shared directory'}
  $layout=Get-Content -LiteralPath $SourceLayout -Raw -Encoding UTF8|ConvertFrom-Json
  if($layout.format -cne 'stellae-source-layout-upgrade-v1'){throw 'Unexpected source layout preflight policy'}
  $former=@{}
  foreach($entry in $layout.files){
    if($entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $entry.group -cnotin @('lua','configuration')){throw 'Invalid source layout preflight record'}
    $former[[string]$entry.path]=[string]$entry.sha256
  }
  $incomingFiles=@{}
  if($SharedManifest){
    $source=Get-Content -LiteralPath $SharedManifest -Raw -Encoding UTF8|ConvertFrom-Json
    foreach($entry in $source.files){$incomingFiles[[string]$entry.path]=[string]$entry.sha256}
  }
  function Known-ProductCopy([string]$Relative,[string]$Checksum){
    $alias=if($Relative -ceq 'default.custom.yaml'){'stellae_bundle_default.yaml'}else{$Relative}
    return ($former.ContainsKey($Relative) -and $former[$Relative] -ceq $Checksum) -or
      ($known.ContainsKey($Relative) -and $known[$Relative] -ceq $Checksum) -or
      ($known.ContainsKey($alias) -and $known[$alias] -ceq $Checksum) -or
      ($Relative -ceq 'default.custom.yaml' -and $known.ContainsKey('rymcp_bundle_default.yaml') -and $known['rymcp_bundle_default.yaml'] -ceq $Checksum) -or
      ($incomingFiles.ContainsKey($Relative) -and $incomingFiles[$Relative] -ceq $Checksum) -or
      ($incomingFiles.ContainsKey($alias) -and $incomingFiles[$alias] -ceq $Checksum)
  }
  $flat=@($layout.files|Where-Object {$_.group -ceq 'lua' -and $_.path -cmatch '^lua/[A-Za-z0-9_]+\.lua$' -and -not $incomingFiles.ContainsKey([string]$_.path)})
  foreach($rootPath in @($user,$shared)){
    foreach($entry in $flat){
      $path=Child $rootPath $entry.path
      if((File-Present $path) -and -not (Known-ProductCopy $entry.path (Hash $path))){
        throw ('A modified obsolete Lua module needs a manual merge before upgrading: '+$entry.path)
      }
    }
    $path=Child $rootPath 'rime.lua'
    if((File-Present $path) -and -not (Known-ProductCopy 'rime.lua' (Hash $path))){
      $entrypoint=[IO.File]::ReadAllText($path)
      foreach($entry in $flat){
        $module=[IO.Path]::GetFileNameWithoutExtension($entry.path)
        if($entrypoint -match ('\brequire\s*\(?\s*[''"]'+[regex]::Escape($module)+'[''"]')){
          throw 'The modified Lua entrypoint still loads an obsolete flat module. Merge it with the current namespaced entrypoint before upgrading.'
        }
      }
    }
  }
  foreach($relative in @('default.custom.yaml','cn_stellae.custom.yaml','jp_stellae.custom.yaml','pc_research.custom.yaml','jp_sela.custom.yaml')){
    $path=Child $user $relative
    if(-not (File-Present $path) -or (Known-ProductCopy $relative (Hash $path))){continue}
    if($relative -cin @('pc_research.custom.yaml','jp_sela.custom.yaml')){
      $target=if($relative -ceq 'pc_research.custom.yaml'){'cn_stellae.custom.yaml'}else{'jp_stellae.custom.yaml'}
      throw ('Merge the personal settings in '+$relative+' into '+$target+' before upgrading. The obsolete schema no longer loads its former custom filename.')
    }
    $text=[IO.File]::ReadAllText($path)
    $meaningful=(@($text -split '\r?\n'|Where-Object {$_ -notmatch '^\s*#'}) -join "`n")
    if($meaningful -match '(?m)(?:^\s*|[,{]\s*)[''"]?(?:[A-Za-z0-9_./-]+/)?user_dict[''"]?\s*:\s*[''"]?(luna_pinyin|pc_english|jp_family)[''"]?(?=\s*(?:[,}#\r\n]|$))'){
      throw ('A personal user_dict override still selects an old learning store. Merge its explicit dictionary setting before upgrading: '+$relative)
    }
    if($relative -cne 'default.custom.yaml'){continue}
    $bodies=@()
    $indent=-1;$body=''
    foreach($line in ($meaningful -split '\r?\n')){
      if($line -match '^([ \t]*)[''"]?(?:patch/)?schema_list[''"]?\s*:(.*)$'){
        if($indent -ge 0){$bodies+=@($body)}
        $indent=$Matches[1].Length;$body=$Matches[2]+"`n";continue
      }
      if($indent -ge 0){
        $width=([regex]::Match($line,'^[ \t]*')).Value.Length
        if($line.Trim() -and $width -le $indent -and $line -notmatch '^\s*-'){$bodies+=@($body);$body='';$indent=-1}
        else{$body+=$line+"`n"}
      }
    }
    if($indent -ge 0){$bodies+=@($body)}
    foreach($match in [regex]::Matches($meaningful,'(?m)(?:^\s*|[,{]\s*)[''"]?schema_list[''"]?\s*:\s*\[([^\r\n\]]*)\]')){$bodies+=@($match.Groups[1].Value)}
    foreach($schemaList in $bodies){
      if($schemaList -match '(?:^|[\s,{\-])[''"]?schema[''"]?\s*:\s*[''"]?(pc_research|jp_sela)[''"]?(?=\s*(?:[,}#\r\n]|$))'){
        throw 'A personal schema_list still selects pc_research or jp_sela. Merge it with the current schema identifiers before upgrading.'
      }
    }
  }
}
$report=[ordered]@{format='stellae-appearance-config-migration-v1';action=$Action;passed=$false;userDirectory=$user;oldPresent=$oldPresent;newPresent=$newPresent;customState='unchanged';backups=@();legacySharedFiles=@($legacyShared|ForEach-Object {[ordered]@{path=$_.relative;sha256=$_.sha256}});retiredSharedFiles=@();compiledLegacyArchived=$false;learningChanged=$false;dlcChanged=$false}
$script:archive=$null
$script:archived=@()
function Backup([string]$Path,[string]$Relative){
  if(-not $script:archive){
    $backupRoot=if($BackupDirectory){[IO.Path]::GetFullPath($BackupDirectory)}else{Join-Path $env:LOCALAPPDATA 'RimeStellae/upgrade-backups/appearance-config'}
    if([IO.Path]::GetFullPath($backupRoot).TrimEnd([char[]]'\/').StartsWith($user+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFullPath($backupRoot).TrimEnd([char[]]'\/') -ieq $user){throw 'Appearance backups must be outside the user directory'}
    $script:archive=Child $backupRoot ([Guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $script:archive -Force
  }
  $target=Child $script:archive $Relative
  $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
  [IO.File]::Copy($Path,$target,$false)
  $hash=Hash $Path
  if((Hash $target) -cne $hash){throw 'Appearance backup differs from its original file'}
  $script:archived+=@([ordered]@{originalPath=$Path;archivePath=$Relative;bytes=(Get-Item -LiteralPath $Path).Length;sha256=$hash})
  [ordered]@{format='stellae-appearance-backup-v1';files=$script:archived}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $script:archive 'manifest.json') -Encoding UTF8
  $report.backups+=@([ordered]@{path=$target;sha256=$hash})
}
if($Action -eq 'Migrate'){
  foreach($entry in $legacyShared){Backup $entry.path ('shared/'+$entry.relative)}
  if($oldPresent){
    if((Hash $old) -cne $oldHash){throw 'The old appearance settings changed during migration; retry after closing the appearance tool'}
    if($newPresent){
      if((Hash $new) -cne $oldHash){throw 'The new appearance settings changed during migration; both files were preserved'}
      $report.customState='identical-copy-staged'
    }else{
      Backup $old 'user/weasel.custom.yaml'
      $stage=Child $user ('.stellae-custom-'+[Guid]::NewGuid().ToString('N')+'.tmp')
      try{
        [IO.File]::Copy($old,$stage,$false)
        if((Hash $stage) -cne $oldHash){throw 'Staged appearance bytes differ from the original'}
        [IO.File]::Move($stage,$new)
      }finally{if(Test-Path -LiteralPath $stage -PathType Leaf){[IO.File]::Delete($stage)}}
      $report.customState='copied-byte-exact'
    }
    if((Hash $new) -cne $oldHash){throw 'Migrated appearance bytes differ from the original'}
  }
}elseif($Action -eq 'Finalize'){
  $compiled=Child $user 'build/stellae.yaml'
  if(-not (File-Present $compiled)){throw 'The Stellae appearance configuration must compile successfully before retiring its old compiled copy'}
  if($oldPresent){
    if(-not $newPresent -or (Hash $new) -cne $oldHash){throw 'The original appearance file cannot be retired until the same bytes exist under the new filename'}
    Backup $old 'user/weasel.custom.yaml'
    if((Hash $old) -cne $oldHash){throw 'The old appearance settings changed during finalization'}
    [IO.File]::Delete($old)
    $report.customState='old-copy-archived'
  }
  foreach($entry in $legacyShared){
    Backup $entry.path ('shared/'+$entry.relative)
    if((Hash $entry.path) -cne $entry.sha256){throw 'A former shared appearance file changed during archival'}
    [IO.File]::Delete($entry.path)
    $report.retiredSharedFiles+=@($entry.relative)
  }
  $legacy=Child $user 'build/weasel.yaml'
  if(File-Present $legacy){
    Backup $legacy 'user/build/weasel.yaml'
    $saved=$report.backups[$report.backups.Count-1].sha256
    if((Hash $legacy) -cne $saved){throw 'The former compiled appearance configuration changed during archival'}
    [IO.File]::Delete($legacy)
    $report.compiledLegacyArchived=$true
  }
}
$report.passed=$true
if($ReportFile){$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportFile -Encoding UTF8}
Write-Output ($report|ConvertTo-Json -Depth 8)
