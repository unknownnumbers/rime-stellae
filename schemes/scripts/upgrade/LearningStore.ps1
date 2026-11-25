# SPDX-License-Identifier: GPL-3.0-only
param(
  [ValidateSet('Preflight','Prepare','Apply','Finalize','Rollback')][string]$Action,
  [string]$UserDirectory,
  [string]$EngineDirectory,
  [string]$EnginePath,
  [ValidateSet('Stellae','Weasel')][string]$Frontend='Stellae',
  [Alias('TargetCompiledConfig')][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$CompiledAppearanceName='stellae',
  [string]$WorkDirectory,
  [string]$BackupDirectory,
  [string]$ReportFile,
  [switch]$LibraryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:LearningHelperRoot=$PSScriptRoot
$script:LearningMappings=@(
  [pscustomobject]@{oldName='luna_pinyin';newName='cn_stellae'},
  [pscustomobject]@{oldName='pc_english';newName='en_intelligence'},
  [pscustomobject]@{oldName='jp_family';newName='jp_kanji'}
)
function Learning-Hash([string]$Path){
  $algorithm=[Security.Cryptography.SHA256]::Create()
  $stream=$null
  try{$stream=[IO.File]::OpenRead($Path);return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
  finally{if($stream){$stream.Dispose()};$algorithm.Dispose()}
}
function Learning-Json([string]$Path,$Value){
  $null=[IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 14)+"`n",[Text.UTF8Encoding]::new($false))
}
function Learning-Path([string]$Path){
  $full=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
  $current=$full
  while($current){
    if(Test-Path -LiteralPath $current){
      if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Learning migration paths must not be redirected.'}
    }
    $current=Split-Path $current -Parent
  }
  return $full
}
function Learning-Child([string]$Root,[string]$Relative){
  if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Invalid learning migration relative path.'}
  $base=Learning-Path $Root
  $path=Learning-Path (Join-Path $base $Relative)
  if(-not $path.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Learning migration path escapes its directory.'}
  return $path
}
function Learning-UserDirectory([string]$FrontendName){
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
  $registry=if($FrontendName -eq 'Weasel'){'Software\Rime\Weasel'}else{'Software\RimeStellae'}
  try{$key=$base.OpenSubKey($registry);try{$value=if($key){[string]$key.GetValue('RimeUserDir','')}else{''}}finally{if($key){$key.Dispose()}}}finally{$base.Dispose()}
  if(-not $value){$value=Join-Path $env:APPDATA $(if($FrontendName -eq 'Weasel'){'Rime'}else{'RimeStellae'})}
  return Learning-Path $value
}
function Learning-Tree([string]$Root,[string]$CopyTo){
  $rootPath=Learning-Path $Root
  if(-not (Test-Path -LiteralPath $rootPath -PathType Container)){throw 'A learning database directory is missing.'}
  $pending=New-Object 'System.Collections.Generic.Stack[string]'
  $pending.Push($rootPath)
  $rows=@()
  while($pending.Count){
    $directory=$pending.Pop()
    foreach($entry in @(Get-ChildItem -LiteralPath $directory -Force)){
      $path=Learning-Path $entry.FullName
      $relative=$path.Substring($rootPath.Length+1).Replace('\','/')
      if($entry.PSIsContainer){
        if($CopyTo){$null=[IO.Directory]::CreateDirectory((Learning-Child $CopyTo $relative))}
        $pending.Push($path)
      }else{
        $hash=Learning-Hash $path
        if($CopyTo){
          $target=Learning-Child $CopyTo $relative
          $null=[IO.Directory]::CreateDirectory((Split-Path $target -Parent))
          [IO.File]::Copy($path,$target,$false)
          if((Learning-Hash $target) -cne $hash){throw 'A copied learning file differs from its source.'}
        }
        $rows+=@([pscustomobject]@{path=$relative;bytes=$entry.Length;sha256=$hash})
      }
    }
  }
  return @($rows|Sort-Object path)
}
function Learning-SameTree($Left,$Right){
  return (@($Left)|ConvertTo-Json -Depth 5 -Compress) -ceq (@($Right)|ConvertTo-Json -Depth 5 -Compress)
}
function Learning-Unlocked([string]$Database){
  $lock=Learning-Child $Database 'LOCK'
  if(-not (Test-Path -LiteralPath $lock -PathType Leaf)){return}
  $limit=[DateTime]::UtcNow.AddSeconds(20)
  do{
    try{$stream=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$stream.Dispose();return}
    catch [IO.IOException]{if([DateTime]::UtcNow -ge $limit){throw 'A learning store is still in use. Stop its frontend before migrating.'};Start-Sleep -Milliseconds 100}
  }while($true)
}
function Learning-LuaString([string]$Value){
  return '"'+(-join @([Text.Encoding]::UTF8.GetBytes($Value)|ForEach-Object {'\'+$_.ToString('000')}))+'"'
}
function Learning-RunLua([string]$Engine,[string]$Stage){
  $source=Join-Path $script:LearningHelperRoot 'LearningStoreNative.cs'
  $quote={param($value) "'"+$value.Replace("'","''")+"'"}
  $command='Add-Type -LiteralPath '+(& $quote $source)+'; [StellaeLearningStoreNative]::Run('+(& $quote $Engine)+','+(& $quote $Stage)+')'
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=(Get-Process -Id $PID).Path
  $start.WorkingDirectory=$Stage
  $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $process=New-Object Diagnostics.Process
  $process.StartInfo=$start
  try{
    if(-not $process.Start()){throw 'The offline learning helper did not start.'}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw ('The offline learning helper failed: '+$errorText)}
  }finally{$process.Dispose()}
}
function Learning-CloneProof([string]$Engine,[string]$Stage,[string]$Old,[string]$New,[bool]$Rename){
  $stagePath=Learning-Path $Stage
  $scriptPath=Learning-Child $stagePath 'rime.lua'
  if(Test-Path -LiteralPath $scriptPath){throw 'The offline learning clone already has an entry script.'}
  $token=[Guid]::NewGuid().ToString('N')
  $opaque=Learning-Child $stagePath ($token+'.opaque')
  $nativeReport=Learning-Child $stagePath ($token+'.json')
  $template=[IO.File]::ReadAllText((Join-Path $script:LearningHelperRoot 'LearningStore.lua'),[Text.Encoding]::UTF8)
  foreach($replacement in @(
    @('@DATABASE@',(Learning-LuaString $New)),@('@OLD_NAME@',(Learning-LuaString $Old)),
    @('@NEW_NAME@',(Learning-LuaString $New)),@('@RENAME@',$(if($Rename){'true'}else{'false'})),
    @('@OPAQUE_FILE@',(Learning-LuaString ([IO.Path]::GetFileName($opaque)))),@('@REPORT_FILE@',(Learning-LuaString ([IO.Path]::GetFileName($nativeReport))))
  )){$template=$template.Replace($replacement[0],$replacement[1])}
  foreach($name in @('logs','empty','build')){$null=[IO.Directory]::CreateDirectory((Learning-Child $stagePath $name))}
  try{
    [IO.File]::WriteAllText($scriptPath,$template,[Text.UTF8Encoding]::new($false))
    Learning-RunLua $Engine $stagePath
    if(-not (Test-Path -LiteralPath $nativeReport -PathType Leaf) -or -not (Test-Path -LiteralPath $opaque -PathType Leaf)){throw 'The offline learning proof did not complete.'}
    $result=Get-Content -LiteralPath $nativeReport -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $result.passed -or -not $result.allOtherRawRecordsUnchanged -or $result.identityAfter -cne $New){throw 'The offline learning clone did not preserve its raw records.'}
    return [pscustomobject]@{passed=$true;opaqueSha256=(Learning-Hash $opaque);records=$result.records;metadataRecords=$result.metadataRecords;identityBefore=$result.identityBefore;identityAfter=$result.identityAfter}
  }finally{
    foreach($path in @($scriptPath,$opaque,$nativeReport)){if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::Delete($path)}}
  }
}
function Learning-LegacyReferences([string]$User,[string]$Old){
  $files=@(Get-ChildItem -LiteralPath $User -Filter '*.custom.yaml' -File -ErrorAction SilentlyContinue)
  $entry=Join-Path $User 'rime.lua'
  if(Test-Path -LiteralPath $entry -PathType Leaf){$files+=Get-Item -LiteralPath $entry}
  $lua=Join-Path $User 'lua'
  if(Test-Path -LiteralPath $lua -PathType Container){
    # Check each directory before descent, without following junctions.
    $pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push((Learning-Path $lua))
    while($pending.Count){foreach($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)){
      $null=Learning-Path $item.FullName
      if($item.PSIsContainer){$pending.Push($item.FullName)}elseif($item.Extension -eq '.lua'){$files+=$item}
    }}
  }
  $pattern='(?<![A-Za-z0-9_])'+[regex]::Escape($Old)+'(?![A-Za-z0-9_])'
  $found=@()
  foreach($file in $files){if([IO.File]::ReadAllText($file.FullName) -match $pattern){$found+=@($file.FullName)}}
  $defaults=Join-Path $User 'build/default.yaml'
  if(Test-Path -LiteralPath $defaults -PathType Leaf){
    $raw=[IO.File]::ReadAllText($defaults)
    foreach($match in [regex]::Matches($raw,'(?m)^\s*-\s*schema:\s*([A-Za-z0-9_.-]+)\s*$')){
      $path=Learning-Child $User ('build/'+$match.Groups[1].Value+'.schema.yaml')
      if(Test-Path -LiteralPath $path -PathType Leaf){
        $text=[IO.File]::ReadAllText($path)
        if($text -match ('(?m)^\s*user_dict:\s*[''"'']?'+[regex]::Escape($Old)+'(?:[''"'']|\s|$)')){$found+=@($path)}
        $translator=[regex]::Match($text,'(?m)^translator:\r?\n(?<body>(?:^[ \t].*\r?\n|^\r?\n)*)').Groups['body'].Value
        if($translator -and $translator -notmatch '(?m)^\s*user_dict:' -and $translator -match ('(?m)^\s*dictionary:\s*[''"'']?'+[regex]::Escape($Old)+'(?:[''"'']|\s|$)')){$found+=@($path)}
      }
    }
  }
  return @($found|Sort-Object -Unique)
}
if($LibraryOnly){return}
if(-not $Action -or -not $WorkDirectory){throw 'Select a migration action and its private work directory.'}
if($EnginePath){
  if($EngineDirectory){throw 'Specify either EnginePath or EngineDirectory.'}
  if([IO.Path]::GetFileName($EnginePath) -ine 'rime.dll'){throw 'EnginePath must name rime.dll.'}
  $EngineDirectory=Split-Path ([IO.Path]::GetFullPath($EnginePath)) -Parent
}
$user=if($UserDirectory){Learning-Path $UserDirectory}else{Learning-UserDirectory $Frontend}
$work=Learning-Path $WorkDirectory
if($work -ieq $user -or $work.StartsWith($user+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Learning migration work must be outside the user directory.'}
$marker=Learning-Child $work 'required.flag'
$statePath=Learning-Child $work 'migration.json'
$report=[ordered]@{format='stellae-learning-store-upgrade-v1';action=$Action;passed=$false;needsMigration=$false;mappings=@();manualMerge=@();sessionsCreated=0;originalDatabasesOpened=$false}
if($Action -eq 'Preflight'){
  foreach($mapping in $script:LearningMappings){
    $old=Learning-Child $user ($mapping.oldName+'.userdb');$new=Learning-Child $user ($mapping.newName+'.userdb')
    foreach($path in @($old,$new)){if((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Container)){throw 'A learning store path is not a directory.'}}
    if((Test-Path -LiteralPath $old) -and (Test-Path -LiteralPath $new)){throw ('Both '+$mapping.oldName+' and '+$mapping.newName+' learning stores exist. Merge them explicitly before upgrading. No learning data was changed.')}
    if(Test-Path -LiteralPath $old){$report.needsMigration=$true;$report.mappings+=@($mapping)}
  }
  if($report.needsMigration){$null=[IO.Directory]::CreateDirectory($work);[IO.File]::WriteAllText($marker,'required',[Text.UTF8Encoding]::new($false))}
  elseif(Test-Path -LiteralPath $marker -PathType Leaf){[IO.File]::Delete($marker)}
}elseif($Action -eq 'Prepare'){
  if(Test-Path -LiteralPath $statePath){throw 'A prepared learning migration already exists. Resume or review it before preparing again.'}
  if(-not (Test-Path -LiteralPath (Join-Path $EngineDirectory 'rime.dll') -PathType Leaf)){throw 'An installed engine is required for offline learning preparation.'}
  $state=[ordered]@{format='stellae-learning-store-plan-v1';userDirectory=$user;phase='prepared';mappings=@();createdTargets=@();archives=@()}
  foreach($mapping in $script:LearningMappings){
    $old=Learning-Child $user ($mapping.oldName+'.userdb');$new=Learning-Child $user ($mapping.newName+'.userdb')
    if(-not (Test-Path -LiteralPath $old -PathType Container)){continue}
    if(Test-Path -LiteralPath $new){throw 'The target learning store appeared before migration preparation.'}
    Learning-Unlocked $old
    $stage=Learning-Child $work ('clones/'+$mapping.newName)
    $database=Learning-Child $stage ($mapping.newName+'.userdb')
    if(Test-Path -LiteralPath $stage){throw 'A learning clone stage already exists.'}
    $original=@(Learning-Tree $old $database)
    $proof=Learning-CloneProof $EngineDirectory $stage $mapping.oldName $mapping.newName $true
    $reopened=Learning-CloneProof $EngineDirectory $stage $mapping.oldName $mapping.newName $false
    if($proof.opaqueSha256 -cne $reopened.opaqueSha256){throw 'Reopening the renamed clone changed learning record values.'}
    if(-not (Learning-SameTree $original @(Learning-Tree $old ''))){throw 'An original learning store changed while preparing its offline clone.'}
    $state.mappings+=@([ordered]@{oldName=$mapping.oldName;newName=$mapping.newName;originalFiles=$original;cloneFiles=@(Learning-Tree $database '');proof=$proof;reopenedProof=$reopened})
  }
  $report.needsMigration=$state.mappings.Count -gt 0;$report.mappings=$state.mappings
  Learning-Json $statePath $state
}else{
  if(-not (Test-Path -LiteralPath $statePath -PathType Leaf)){throw 'The prepared learning migration is missing.'}
  $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
  if($state.format -cne 'stellae-learning-store-plan-v1' -or $state.userDirectory -ine $user){throw 'The learning migration belongs to another user directory.'}
  $report.needsMigration=@($state.mappings).Count -gt 0
  if($Action -eq 'Apply'){
    if($state.phase -cne 'prepared'){throw 'Learning clones can be applied only once.'}
    try{
      foreach($mapping in $state.mappings){
        $old=Learning-Child $user ($mapping.oldName+'.userdb');$new=Learning-Child $user ($mapping.newName+'.userdb')
        if(Test-Path -LiteralPath $new){throw 'A target learning store appeared before activation.'}
        Learning-Unlocked $old
        if(-not (Learning-SameTree $mapping.originalFiles @(Learning-Tree $old ''))){throw 'An original learning store changed before activation.'}
        $clone=Learning-Child $work ('clones/'+$mapping.newName+'/'+$mapping.newName+'.userdb')
        if(-not (Learning-SameTree $mapping.cloneFiles @(Learning-Tree $clone ''))){throw 'A verified learning clone changed before activation.'}
        $temporary=Learning-Child $user ('.learning-upgrade-'+[Guid]::NewGuid().ToString('N'))
        try{
          $copy=@(Learning-Tree $clone $temporary)
          if(-not (Learning-SameTree $copy $mapping.cloneFiles)){throw 'A staged learning copy differs.'}
          [IO.Directory]::Move($temporary,$new)
        }finally{if(Test-Path -LiteralPath $temporary -PathType Container){Remove-Item -LiteralPath (Learning-Path $temporary) -Recurse -Force}}
        $state.createdTargets+=@($mapping.newName)
        Learning-Json $statePath $state
      }
      $state.phase='applied';Learning-Json $statePath $state
    }catch{
      foreach($name in @($state.createdTargets)){
        $mapping=@($state.mappings|Where-Object {$_.newName -ceq $name})[0]
        $new=Learning-Child $user ($name+'.userdb')
        if(Learning-SameTree $mapping.cloneFiles @(Learning-Tree $new '')){Remove-Item -LiteralPath $new -Recurse -Force}
      }
      $state.createdTargets=@();Learning-Json $statePath $state
      throw
    }
  }elseif($Action -eq 'Rollback'){
    foreach($name in @($state.createdTargets)){
      $mapping=@($state.mappings|Where-Object {$_.newName -ceq $name})[0]
      $old=Learning-Child $user ($mapping.oldName+'.userdb');$new=Learning-Child $user ($name+'.userdb')
      Learning-Unlocked $old;Learning-Unlocked $new
      if(-not (Learning-SameTree $mapping.originalFiles @(Learning-Tree $old '')) -or -not (Learning-SameTree $mapping.cloneFiles @(Learning-Tree $new ''))){throw 'Changed learning data was retained for manual recovery.'}
      Remove-Item -LiteralPath $new -Recurse -Force
    }
    $state.phase='rolled-back';$state.createdTargets=@();Learning-Json $statePath $state
  }elseif($Action -eq 'Finalize'){
    if($state.phase -eq 'finalized'){$report.mappings=$state.mappings}
    elseif($state.phase -cne 'applied'){throw 'Learning migration cannot finalize before verified activation.'}
    else{
      if(-not (Test-Path -LiteralPath (Learning-Child $user ('build/'+$CompiledAppearanceName+'.yaml')) -PathType Leaf)){throw 'Successful frontend configuration deployment is required before retiring old learning stores.'}
      foreach($mapping in $state.mappings){
        $old=Learning-Child $user ($mapping.oldName+'.userdb');$new=Learning-Child $user ($mapping.newName+'.userdb')
        Learning-Unlocked $old;Learning-Unlocked $new
        if(-not (Learning-SameTree $mapping.originalFiles @(Learning-Tree $old '')) -or -not (Learning-SameTree $mapping.cloneFiles @(Learning-Tree $new ''))){throw 'Learning files changed before finalization. Both stores were retained.'}
        $references=@(Learning-LegacyReferences $user $mapping.oldName)
        if($references.Count){$report.manualMerge+=@([ordered]@{oldName=$mapping.oldName;newName=$mapping.newName;references=$references;oldStoreRetained=$true});continue}
        $backupRoot=if($BackupDirectory){Learning-Path $BackupDirectory}else{Join-Path $env:LOCALAPPDATA $(if($Frontend -eq 'Weasel'){'Rime/upgrade-backups/learning-store'}else{'RimeStellae/upgrade-backups/learning-store'})}
        if($backupRoot -ieq $user -or $backupRoot.StartsWith($user+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Learning archives must be outside the user directory.'}
        $archive=Learning-Child $backupRoot ([Guid]::NewGuid().ToString('N')+'/'+$mapping.oldName+'.userdb')
        $saved=@(Learning-Tree $old $archive)
        if(-not (Learning-SameTree $saved $mapping.originalFiles)){throw 'The archived original learning store differs.'}
        $state.archives+=@([ordered]@{oldName=$mapping.oldName;path=$archive;files=$saved})
        Learning-Json $statePath $state
        Remove-Item -LiteralPath $old -Recurse -Force
      }
      $state.phase='finalized';Learning-Json $statePath $state
    }
  }
  $report.mappings=$state.mappings
}
$report.passed=$true
if($ReportFile){Learning-Json ([IO.Path]::GetFullPath($ReportFile)) $report}
Write-Output ($report|ConvertTo-Json -Depth 14)
