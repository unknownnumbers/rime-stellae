# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new synthetic module-upgrade directory'}
$root=[IO.Path]::GetFullPath($OutputDirectory)
$null=New-Item -ItemType Directory -Path $root
$helper=Join-Path $PSScriptRoot '../../../schemes/scripts/upgrade/DlcNamespace.ps1'
$checks=@()
function Check([string]$Name,[bool]$Passed){$script:checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name}}
function Write-Fixture([string]$Path,[string]$Text){$null=New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash}
function Adler([byte[]]$Bytes){[uint32]$a=1;[uint32]$b=0;foreach($value in $Bytes){$a=($a+$value)%65521;$b=($b+$a)%65521};return ('{0:x8}' -f [uint32](($b -shl 16) -bor $a))}
function Case([string]$Name){
  $case=Join-Path $root $Name;$user=Join-Path $case 'user';$null=New-Item -ItemType Directory -Path $user
  Write-Fixture (Join-Path $user 'cn_stellae.userdb/sentinel') 'unmodified synthetic learning'
  Write-Fixture (Join-Path $user 'cn_stellae.custom.yaml') 'patch: {menu/page_size: 7}'
  return @{Action='Preflight';UserDirectory=$user;StateFile=(Join-Path $case 'state.json');BackupDirectory=(Join-Path $case 'archive');RequiredFlag=(Join-Path $case 'required.flag')}
}
function Module($Options,[string]$Id){
  $module=Join-Path $Options.UserDirectory ('rymcp_dlc/'+$Id)
  $body="literal_rymcp_dlc_is_data`tli te ral`t100`r`n"
  Write-Fixture (Join-Path $module 'words.dict.yaml') ("---`r`nname: 'rymcp_dlc/$Id/words'`r`nversion: '1'`r`npatch:`r`n  translator/packs/+: [rymcp_dlc_$Id]`r`n...`r`n"+$body)
  Write-Fixture (Join-Path $module 'NOTICE.txt') 'Synthetic notice retained verbatim.'
  Write-Fixture (Join-Path $module 'english.tsv') "fixture`tFixture`t100`n"
  $index=Join-Path $module 'english_index/keys.bin';$null=New-Item -ItemType Directory -Path (Split-Path $index -Parent) -Force
  [IO.File]::WriteAllBytes($index,[byte[]](0,255,13,10,101))
  $lines=@("format`t1","id`t$Id","revision`t1")
  foreach($name in @('words.dict.yaml','NOTICE.txt','english.tsv','english_index/keys.bin')){
    $raw=[IO.File]::ReadAllBytes((Join-Path $module $name));$lines+=@("file`t$name`t$($raw.Length)`t$(Adler $raw)")
  }
  Write-Fixture (Join-Path $module 'manifest.tsv') (($lines -join "`r`n")+"`r`n")
  return $body
}
$fresh=Case fresh
$null=& $helper @fresh
Check 'fresh profile does not request migration' (-not (Test-Path -LiteralPath $fresh.RequiredFlag))
Check 'fresh profile has no archive side effects' (-not (Test-Path -LiteralPath $fresh.BackupDirectory))
$fresh.Action='Prepare';$null=& $helper @fresh
Check 'fresh profile remains unchanged' ((Get-Content -LiteralPath (Join-Path $fresh.UserDirectory 'cn_stellae.userdb/sentinel') -Raw) -ceq 'unmodified synthetic learning')
$options=Case legacy
$bodies=@{};foreach($id in @('math','poetry')){$bodies[$id]=Module $options $id}
$null=& $helper @options
Check 'legacy modules request one-time migration' (Test-Path -LiteralPath $options.RequiredFlag)
$options.Action='Prepare';$null=& $helper @options
$state=Get-Content -LiteralPath $options.StateFile -Raw|ConvertFrom-Json
Check 'preparation leaves original modules active' ((Test-Path -LiteralPath (Join-Path $options.UserDirectory 'rymcp_dlc/math')) -and -not (Test-Path -LiteralPath (Join-Path $options.UserDirectory 'stellae_dlc/math')))
Check 'preparation records exact original and prepared hashes' ($state.stage -ceq 'prepared' -and $state.files.Count -eq 10)
$options.Action='Apply';$null=& $helper @options
foreach($id in @('math','poetry')){
  $old=Join-Path $options.UserDirectory ('rymcp_dlc/'+$id);$new=Join-Path $options.UserDirectory ('stellae_dlc/'+$id)
  $text=[IO.File]::ReadAllText((Join-Path $new 'words.dict.yaml'))
  Check "$id rewrites only dictionary header references" ($text.Contains("name: 'stellae_dlc/$Id/words'") -and $text.Contains('stellae_dlc_'+$id) -and $text.EndsWith($bodies[$id]))
  foreach($name in @('NOTICE.txt','english.tsv','english_index/keys.bin')){Check "$id preserves $name exactly" ((Hash (Join-Path $old $name)) -ceq (Hash (Join-Path $new $name)))}
  foreach($line in [IO.File]::ReadAllLines((Join-Path $new 'manifest.tsv'))){if($line.StartsWith("file`t")){$parts=$line.Split("`t");$raw=[IO.File]::ReadAllBytes((Join-Path $new $parts[1]));Check "$id updates manifest $($parts[1])" ($raw.Length -eq [long]$parts[2] -and (Adler $raw) -ceq $parts[3])}}
}
$options.Action='Finalize';$failed=$false
try{$null=& $helper @options}catch{$failed=$true}
Check 'old modules remain until new configuration deployment' ($failed -and (Test-Path -LiteralPath (Join-Path $options.UserDirectory 'rymcp_dlc/math')))
Write-Fixture (Join-Path $options.UserDirectory 'build/stellae.yaml') 'config_version: synthetic'
$null=& $helper @options
$state=Get-Content -LiteralPath $options.StateFile -Raw|ConvertFrom-Json
Check 'finalization retires only backed-up old modules' (-not (Test-Path -LiteralPath (Join-Path $options.UserDirectory 'rymcp_dlc')) -and $state.stage -ceq 'finalized')
Check 'original dictionary bytes remain archived' (Test-Path -LiteralPath (Join-Path $state.archive 'original/math/words.dict.yaml'))
Check 'learning and unrelated custom settings remain intact' ((Get-Content -LiteralPath (Join-Path $options.UserDirectory 'cn_stellae.userdb/sentinel') -Raw) -ceq 'unmodified synthetic learning' -and (Get-Content -LiteralPath (Join-Path $options.UserDirectory 'cn_stellae.custom.yaml') -Raw) -ceq 'patch: {menu/page_size: 7}')
$options.Action='Preflight';$options.RequiredFlag=Join-Path (Split-Path $options.StateFile -Parent) 'repeat.flag';$null=& $helper @options
Check 'repeat upgrade has no namespace migration' (-not (Test-Path -LiteralPath $options.RequiredFlag))
$conflict=Case conflict;$null=Module $conflict math
Write-Fixture (Join-Path $conflict.UserDirectory 'stellae_dlc/math/personal.txt') 'existing new module'
$failed=$false;try{$null=& $helper @conflict}catch{$failed=$true}
Check 'old/new directory conflicts fail without changing either module' ($failed -and (Test-Path -LiteralPath (Join-Path $conflict.UserDirectory 'rymcp_dlc/math/words.dict.yaml')) -and (Test-Path -LiteralPath (Join-Path $conflict.UserDirectory 'stellae_dlc/math/personal.txt')) -and -not (Test-Path -LiteralPath $conflict.BackupDirectory))
$changed=Case changed;$null=Module $changed math;$null=& $helper @changed
$changed.Action='Prepare';$null=& $helper @changed
Add-Content -LiteralPath (Join-Path $changed.UserDirectory 'rymcp_dlc/math/english.tsv') -Value 'external edit'
$changed.Action='Apply';$failed=$false;try{$null=& $helper @changed}catch{$failed=$true}
Check 'a concurrent module edit stops activation and keeps the source' ($failed -and -not (Test-Path -LiteralPath (Join-Path $changed.UserDirectory 'stellae_dlc/math')) -and (Get-Content -LiteralPath (Join-Path $changed.UserDirectory 'rymcp_dlc/math/english.tsv') -Raw).Contains('external edit'))
$referenced=Case referenced;$null=Module $referenced math;$null=& $helper @referenced
$referenced.Action='Prepare';$null=& $helper @referenced
$referenced.Action='Apply';$null=& $helper @referenced
Write-Fixture (Join-Path $referenced.UserDirectory 'build/weasel.yaml') 'config_version: synthetic'
Write-Fixture (Join-Path $referenced.UserDirectory 'lua/personal.lua') "return 'rymcp_dlc/math/english.tsv'"
$referenced.Action='Finalize';$referenced.AppearanceConfigId='weasel';$null=& $helper @referenced
$state=Get-Content -LiteralPath $referenced.StateFile -Raw|ConvertFrom-Json
Check 'official frontend works independently and preserves referenced old modules' ((Test-Path -LiteralPath (Join-Path $referenced.UserDirectory 'rymcp_dlc/math')) -and $state.originalModulesRetained.Count -eq 1 -and $state.oldReferences.Count -eq 1)
function Prepared-Case([string]$Name,[string[]]$Ids=@('math','poetry')){
  $value=Case $Name
  foreach($id in $Ids){$null=Module $value $id}
  $null=& $helper @value
  $value.Action='Prepare';$null=& $helper @value
  return $value
}
$later=Prepared-Case 'later-module-edit'
Add-Content -LiteralPath (Join-Path $later.UserDirectory 'rymcp_dlc/poetry/english.tsv') -Value 'later external edit'
$later.Action='Apply';$failed=$false;try{$null=& $helper @later}catch{$failed=$true}
Check 'later original-module validation fails before publishing any earlier module' ($failed -and -not (Test-Path -LiteralPath (Join-Path $later.UserDirectory 'stellae_dlc/math')) -and -not (Test-Path -LiteralPath (Join-Path $later.UserDirectory 'stellae_dlc/poetry')))
$prepared=Prepared-Case 'later-prepared-edit'
$state=Get-Content -LiteralPath $prepared.StateFile -Raw|ConvertFrom-Json
Add-Content -LiteralPath (Join-Path $state.archive 'prepared/poetry/english.tsv') -Value 'altered prepared catalog'
$prepared.Action='Apply';$failed=$false;try{$null=& $helper @prepared}catch{$failed=$true}
Check 'later prepared-module validation fails before publishing an earlier module' ($failed -and -not (Test-Path -LiteralPath (Join-Path $prepared.UserDirectory 'stellae_dlc/math')))
$rollback=Prepared-Case rollback
$rollback.Action='Apply';$null=& $helper @rollback
$rollback.Action='Rollback';$null=& $helper @rollback
Check 'rollback removes only the verified new module copies' (-not (Test-Path -LiteralPath (Join-Path $rollback.UserDirectory 'stellae_dlc/math')) -and -not (Test-Path -LiteralPath (Join-Path $rollback.UserDirectory 'stellae_dlc/poetry')) -and (Test-Path -LiteralPath (Join-Path $rollback.UserDirectory 'rymcp_dlc/math')) -and (Test-Path -LiteralPath (Join-Path $rollback.UserDirectory 'rymcp_dlc/poetry')))
$partial=Prepared-Case 'recorded-partial-apply'
$state=Get-Content -LiteralPath $partial.StateFile -Raw|ConvertFrom-Json
$null=New-Item -ItemType Directory -Path (Join-Path $partial.UserDirectory 'stellae_dlc')
Copy-Item -LiteralPath (Join-Path $state.archive 'prepared/math') -Destination (Join-Path $partial.UserDirectory 'stellae_dlc/math') -Recurse
$state.createdModules=@('math');[IO.File]::WriteAllText($partial.StateFile,($state|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$partial.Action='Rollback';$null=& $helper @partial
Check 'rollback handles a recorded partial multi-module activation' (-not (Test-Path -LiteralPath (Join-Path $partial.UserDirectory 'stellae_dlc/math')) -and (Test-Path -LiteralPath (Join-Path $partial.UserDirectory 'rymcp_dlc/poetry')))
$edited=Prepared-Case 'modified-new-rollback' @('math')
$edited.Action='Apply';$null=& $helper @edited
Add-Content -LiteralPath (Join-Path $edited.UserDirectory 'stellae_dlc/math/english.tsv') -Value 'personal migrated edit'
$edited.Action='Rollback';$failed=$false;try{$null=& $helper @edited}catch{$failed=$true}
Check 'rollback preserves changed new module contents for manual recovery' ($failed -and (Get-Content -LiteralPath (Join-Path $edited.UserDirectory 'stellae_dlc/math/english.tsv') -Raw).Contains('personal migrated edit') -and (Test-Path -LiteralPath (Join-Path $edited.UserDirectory 'rymcp_dlc/math')))
$final=Prepared-Case 'later-finalize-validation'
$final.Action='Apply';$null=& $helper @final
Write-Fixture (Join-Path $final.UserDirectory 'build/stellae.yaml') 'config_version: synthetic'
Add-Content -LiteralPath (Join-Path $final.UserDirectory 'stellae_dlc/poetry/english.tsv') -Value 'new personal edit'
$final.Action='Finalize';$failed=$false;try{$null=& $helper @final}catch{$failed=$true}
Check 'later finalization failure retains every earlier original module' ($failed -and (Test-Path -LiteralPath (Join-Path $final.UserDirectory 'rymcp_dlc/math')) -and (Test-Path -LiteralPath (Join-Path $final.UserDirectory 'rymcp_dlc/poetry')))
$locked=Prepared-Case 'locked-finalize-retry'
$locked.Action='Apply';$null=& $helper @locked
Write-Fixture (Join-Path $locked.UserDirectory 'build/stellae.yaml') 'config_version: synthetic'
$stream=[IO.File]::Open((Join-Path $locked.UserDirectory 'rymcp_dlc/poetry/NOTICE.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{$locked.Action='Finalize';$failed=$false;try{$null=& $helper @locked}catch{$failed=$true}}
finally{$stream.Dispose()}
Check 'locked retirement preserves the new modules and original archive' ($failed -and (Test-Path -LiteralPath (Join-Path $locked.UserDirectory 'stellae_dlc/math/words.dict.yaml')) -and (Test-Path -LiteralPath (Join-Path $locked.UserDirectory 'stellae_dlc/poetry/words.dict.yaml')))
$null=& $helper @locked
Check 'finalization can resume after a partially completed locked retirement' (-not (Test-Path -LiteralPath (Join-Path $locked.UserDirectory 'rymcp_dlc')))
$null=& $helper @locked
Check 'completed finalization is idempotent' ((Get-Content -LiteralPath $locked.StateFile -Raw|ConvertFrom-Json).stage -ceq 'finalized')
$bom=Case 'manifest-bom';$null=Module $bom math
$manifest=Join-Path $bom.UserDirectory 'rymcp_dlc/math/manifest.tsv'
[IO.File]::WriteAllBytes($manifest,([byte[]](239,187,191)+[IO.File]::ReadAllBytes($manifest)))
$null=& $helper @bom;$bom.Action='Prepare';$null=& $helper @bom
$state=Get-Content -LiteralPath $bom.StateFile -Raw|ConvertFrom-Json
$bytes=[IO.File]::ReadAllBytes((Join-Path $state.archive 'prepared/math/manifest.tsv'))
Check 'manifest checksum updates preserve the UTF-8 BOM' ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
Check 'manifest checksum updates preserve original line endings' ([Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n",'').IndexOf("`n") -eq -1)
foreach($kind in @('malformed','missing-header-record')){
  $bad=Case $kind;$null=Module $bad math
  $manifest=Join-Path $bad.UserDirectory 'rymcp_dlc/math/manifest.tsv'
  $text=[IO.File]::ReadAllText($manifest)
  $text=if($kind -eq 'malformed'){$text+"file`tbroken`t100`tbad`r`n"}else{[regex]::Replace($text,'(?m)^file\twords\.dict\.yaml\t[^\r\n]*\r?\n','')}
  [IO.File]::WriteAllText($manifest,$text,[Text.UTF8Encoding]::new($false))
  $null=& $helper @bad;$bad.Action='Prepare';$failed=$false;try{$null=& $helper @bad}catch{$failed=$true}
  Check "$kind manifest is rejected without publishing any module" ($failed -and (Test-Path -LiteralPath (Join-Path $bad.UserDirectory 'rymcp_dlc/math/words.dict.yaml')) -and -not (Test-Path -LiteralPath (Join-Path $bad.UserDirectory 'stellae_dlc/math')))
}
$active=Prepared-Case 'active-compiled-reference' @('math')
$active.Action='Apply';$null=& $helper @active
Write-Fixture (Join-Path $active.UserDirectory 'build/stellae.yaml') 'config_version: synthetic'
Write-Fixture (Join-Path $active.UserDirectory 'build/default.yaml') "schema_list:`n  - schema: cn_stellae`n"
Write-Fixture (Join-Path $active.UserDirectory 'build/cn_stellae.schema.yaml') "translator:`n  packs: [rymcp_dlc_math]`n"
$active.Action='Finalize';$null=& $helper @active
Check 'an active compiled old namespace preserves its original module' ((Test-Path -LiteralPath (Join-Path $active.UserDirectory 'rymcp_dlc/math')) -and (Get-Content -LiteralPath $active.StateFile -Raw|ConvertFrom-Json).oldReferences.Count -eq 1)
[ordered]@{passed=$true;syntheticFixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS module namespace migration: '+$checks.Count)
