# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new synthetic appearance policy directory'}
$root=[IO.Path]::GetFullPath($OutputDirectory)
$null=New-Item -ItemType Directory -Path $root
$helper=Join-Path $PSScriptRoot '../../../installer/AppearanceConfig.ps1'
$checks=@()
function Check([string]$Name,[bool]$Passed){$script:checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name}}
function Write-Fixture([string]$Path,[string]$Text){$null=New-Item -ItemType Directory -Path (Split-Path $Path) -Force;[IO.File]::WriteAllText($Path,$Text)}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Case([string]$Name){
  $case=Join-Path $root $Name
  $user=Join-Path $case 'user';$shared=Join-Path $case 'shared'
  $null=New-Item -ItemType Directory -Path $user,$shared
  Write-Fixture (Join-Path $user 'fixture.userdb/record') 'synthetic learning'
  Write-Fixture (Join-Path $user 'stellae_dlc/custom/manifest.tsv') 'synthetic DLC'
  Write-Fixture (Join-Path $user 'cn_stellae.custom.yaml') 'synthetic unrelated configuration'
  return @{Action='Preflight';UserDirectory=$user;SharedDirectory=$shared;BackupDirectory=(Join-Path $case 'backups');ReportFile=(Join-Path $case 'preflight.json')}
}
function Preserved($Options,[string]$Name){
  Check "$Name preserves learning" ((Get-Content -LiteralPath (Join-Path $Options.UserDirectory 'fixture.userdb/record') -Raw) -ceq 'synthetic learning')
  Check "$Name preserves DLC" ((Get-Content -LiteralPath (Join-Path $Options.UserDirectory 'stellae_dlc/custom/manifest.tsv') -Raw) -ceq 'synthetic DLC')
  Check "$Name preserves unrelated custom configuration" ((Get-Content -LiteralPath (Join-Path $Options.UserDirectory 'cn_stellae.custom.yaml') -Raw) -ceq 'synthetic unrelated configuration')
}
foreach($kind in @('fresh','old','empty','new','identical')){
  $options=Case $kind
  $old=Join-Path $options.UserDirectory 'weasel.custom.yaml';$new=Join-Path $options.UserDirectory 'stellae.custom.yaml'
  $raw=[byte[]](0xef,0xbb,0xbf)+[Text.Encoding]::UTF8.GetBytes("# Personal comment retained.`r`npatch:`r`n  style/font_point: 17`r`n")
  if($kind -eq 'empty'){$raw=[byte[]]@()}
  if($kind -in @('old','empty','identical')){[IO.File]::WriteAllBytes($old,$raw)}
  if($kind -in @('new','identical')){[IO.File]::WriteAllBytes($new,$raw)}
  $before=if($kind -ne 'fresh'){if(Test-Path -LiteralPath $old){Hash $old}else{Hash $new}}else{$null}
  $null=& $helper @options
  Check "$kind preflight has no backup side effect" (-not (Test-Path -LiteralPath $options.BackupDirectory))
  $options.Action='Migrate';$options.PreflightReport=$options.ReportFile;$options.ReportFile=Join-Path (Split-Path $options.UserDirectory -Parent) 'migrate.json'
  $null=& $helper @options
  Check "$kind keeps the previous frontend settings until deployment" ((Test-Path -LiteralPath $old) -eq ($kind -in @('old','empty','identical')))
  if($kind -eq 'fresh'){Check 'fresh does not invent a personal custom file' (-not (Test-Path -LiteralPath $new))}
  else{Check "$kind preserves exact comment, encoding and custom bytes" ((Hash $new) -ceq $before)}
  $receipt=Get-Content -LiteralPath $options.ReportFile -Raw|ConvertFrom-Json
  if($kind -in @('old','empty')){Check "$kind archives the original custom bytes before staging" ($receipt.backups.Count -eq 1 -and (Hash $receipt.backups[0].path) -ceq $before)}
  Write-Fixture (Join-Path $options.UserDirectory 'build/stellae.yaml') 'synthetic successfully compiled appearance'
  $options.Action='Finalize';$options.ReportFile=Join-Path (Split-Path $options.UserDirectory -Parent) 'finalize.json'
  $null=& $helper @options
  Check "$kind retires the old filename only after successful deployment" (-not (Test-Path -LiteralPath $old))
  $options.Action='Migrate'
  $options.PreflightReport=$null;$options.ReportFile=Join-Path (Split-Path $options.UserDirectory -Parent) 'repeat.json'
  $null=& $helper @options
  $repeat=Get-Content -LiteralPath $options.ReportFile -Raw|ConvertFrom-Json
  Check "$kind repeated migration creates no redundant backup" ($repeat.backups.Count -eq 0 -and $repeat.customState -ceq 'unchanged')
  Preserved $options $kind
}
foreach($kind in @('different','different-empty')){
  $options=Case $kind
  $old=Join-Path $options.UserDirectory 'weasel.custom.yaml';$new=Join-Path $options.UserDirectory 'stellae.custom.yaml'
  Write-Fixture $old 'patch: {style/font_point: 17}'
  $value=if($kind -eq 'different-empty'){''}else{'patch: {style/font_point: 19}'}
  Write-Fixture $new $value
  $oldHash=Hash $old;$newHash=Hash $new;$failed=$false
  try{$null=& $helper @options}catch{$failed=$true}
  Check "$kind conflicts fail before migration" $failed
  Check "$kind preserves both conflicting originals" ((Hash $old) -ceq $oldHash -and (Hash $new) -ceq $newHash)
  Check "$kind does not create backups or reports" (-not (Test-Path -LiteralPath $options.BackupDirectory) -and -not (Test-Path -LiteralPath $options.ReportFile))
  Preserved $options $kind
}
$options=Case 'backup-failure'
$old=Join-Path $options.UserDirectory 'weasel.custom.yaml';$new=Join-Path $options.UserDirectory 'stellae.custom.yaml'
Write-Fixture $old 'patch: {style/font_point: 17}'
$before=Hash $old
Write-Fixture $options.BackupDirectory 'synthetic blocked backup directory'
$options.Action='Migrate';$failed=$false
try{$null=& $helper @options}catch{$failed=$true}
Check 'backup failure preserves the original before rename' ($failed -and (Hash $old) -ceq $before -and -not (Test-Path -LiteralPath $new))
Preserved $options 'backup failure'
foreach($kind in @('owned','modified','unknown','bare')){
  $options=Case ('shared-'+$kind)
  $legacy=Join-Path $options.SharedDirectory 'weasel.yaml'
  Write-Fixture $legacy 'config_version: synthetic-old'
  $records=@([ordered]@{path='weasel.yaml';sha256=(Hash $legacy)})
  if($kind -ne 'unknown'){
    if($kind -eq 'bare'){
      $options.SharedManifest=Join-Path (Split-Path $options.UserDirectory -Parent) 'incoming.json'
      [ordered]@{predecessors=$records}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $options.SharedManifest -Encoding UTF8
    }else{[ordered]@{format='stellae-managed-shared-v1';files=$records}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $options.SharedDirectory 'stellae-managed-files.json') -Encoding UTF8}
  }
  if($kind -eq 'modified'){Write-Fixture $legacy 'synthetic personal shared modification'}
  $before=Hash $legacy;$failed=$false
  try{$null=& $helper @options}catch{$failed=$true}
  if($kind -in @('modified','unknown')){
    Check "$kind shared file blocks activation in preflight" ($failed -and (Hash $legacy) -ceq $before)
  }else{
    Check "$kind shared predecessor passes preflight" (-not $failed)
    $options.PreflightReport=$options.ReportFile;$options.Action='Migrate';$options.ReportFile=Join-Path (Split-Path $options.UserDirectory -Parent) 'migrate.json'
    $null=& $helper @options
    Check "$kind shared old file stays until deployment" ((Hash $legacy) -ceq $before)
    $report=Get-Content -LiteralPath $options.ReportFile -Raw|ConvertFrom-Json
    Check "$kind shared old bytes backed up before replacement" ($report.backups.Count -eq 1 -and (Hash $report.backups[0].path) -ceq $before)
    $oldBuild=Join-Path $options.UserDirectory 'build/weasel.yaml';Write-Fixture $oldBuild 'synthetic old compiled appearance'
    Write-Fixture (Join-Path $options.UserDirectory 'build/unrelated.table.bin') 'synthetic retained cache'
    $options.Action='Finalize';$failed=$false
    try{$null=& $helper @options}catch{$failed=$true}
    Check "$kind unsuccessful new deploy leaves previous files intact" ($failed -and (Test-Path -LiteralPath $oldBuild) -and (Test-Path -LiteralPath $legacy))
    Write-Fixture (Join-Path $options.UserDirectory 'build/stellae.yaml') 'synthetic successfully compiled Stellae appearance'
    Write-Fixture (Join-Path $options.SharedDirectory 'stellae.yaml') 'synthetic new appearance source'
    $options.ReportFile=Join-Path (Split-Path $options.UserDirectory -Parent) 'finalize.json'
    $null=& $helper @options
    $report=Get-Content -LiteralPath $options.ReportFile -Raw|ConvertFrom-Json
    Check "$kind only successful deploy retires exact legacy targets" ($report.compiledLegacyArchived -and -not (Test-Path -LiteralPath $oldBuild) -and -not (Test-Path -LiteralPath $legacy))
    Check "$kind retains new appearance and unrelated cache" ((Test-Path -LiteralPath (Join-Path $options.SharedDirectory 'stellae.yaml')) -and (Test-Path -LiteralPath (Join-Path $options.UserDirectory 'build/unrelated.table.bin')))
  }
  Preserved $options $kind
}
foreach($kind in @('known-default','modified-default','old-user-dict','nested-old-user-dict','obsolete-page-size-cn','obsolete-page-size-jp','base-dictionary','old-flat-lua','old-flat-shared-lua','old-entrypoint','current-custom')){
  $options=Case ('source-'+$kind)
  $caseRoot=Split-Path $options.UserDirectory -Parent
  $options.SourceLayout=Join-Path $caseRoot 'source-layout.json'
  $options.SharedManifest=Join-Path $caseRoot 'incoming.json'
  $publicDefault='patch: {schema_list: [{schema: pc_research}]}'
  $publicFile=Join-Path $caseRoot 'old-public-default.yaml'
  Write-Fixture $publicFile $publicDefault
  $oldModule=Join-Path $caseRoot 'old-public-module.lua';Write-Fixture $oldModule 'return {old_public=true}'
  $oldEntry=Join-Path $caseRoot 'old-public-entry.lua';Write-Fixture $oldEntry "return require('cn_translator')"
  [ordered]@{format='stellae-source-layout-upgrade-v1';files=@(
    [ordered]@{path='default.custom.yaml';sha256=('a'*64);group='configuration'},
    [ordered]@{path='rime.lua';sha256=(Hash $oldEntry);group='lua'},
    [ordered]@{path='lua/cn_translator.lua';sha256=(Hash $oldModule);group='lua'}
  )}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $options.SourceLayout -Encoding UTF8
  [ordered]@{format='stellae-managed-shared-v1';files=@([ordered]@{path='stellae_bundle_default.yaml';sha256=(Hash $publicFile)})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $options.SharedDirectory 'stellae-managed-files.json') -Encoding UTF8
  [ordered]@{files=@([ordered]@{path='rime.lua';sha256=('b'*64)},[ordered]@{path='lua/cn/cn_translator.lua';sha256=('c'*64)})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $options.SharedManifest -Encoding UTF8
  if($kind -eq 'known-default'){Write-Fixture (Join-Path $options.UserDirectory 'default.custom.yaml') $publicDefault}
  if($kind -eq 'modified-default'){Write-Fixture (Join-Path $options.UserDirectory 'default.custom.yaml') ($publicDefault+"`n# Personal change")}
  if($kind -eq 'old-user-dict'){Write-Fixture (Join-Path $options.UserDirectory 'cn_stellae.custom.yaml') "patch:`n  translator/user_dict: luna_pinyin`n"}
  if($kind -eq 'nested-old-user-dict'){Write-Fixture (Join-Path $options.UserDirectory 'jp_stellae.custom.yaml') "patch:`n  jp_family:`n    user_dict: jp_family`n"}
  if($kind -in @('obsolete-page-size-cn','obsolete-page-size-jp')){
    $relative=if($kind -eq 'obsolete-page-size-cn'){'pc_research.custom.yaml'}else{'jp_sela.custom.yaml'}
    Write-Fixture (Join-Path $options.UserDirectory $relative) 'patch: {menu/page_size: 9}'
  }
  if($kind -eq 'base-dictionary'){Write-Fixture (Join-Path $options.UserDirectory 'cn_stellae.custom.yaml') "patch:`n  translator/dictionary: luna_pinyin`n"}
  if($kind -eq 'old-flat-lua'){Write-Fixture (Join-Path $options.UserDirectory 'lua/cn_translator.lua') 'return {personal_old=true}'}
  if($kind -eq 'old-flat-shared-lua'){Write-Fixture (Join-Path $options.SharedDirectory 'lua/cn_translator.lua') 'return {personal_old=true}'}
  if($kind -eq 'old-entrypoint'){Write-Fixture (Join-Path $options.UserDirectory 'rime.lua') "-- Personal change`nreturn require('cn_translator')"}
  if($kind -eq 'current-custom'){
    Write-Fixture (Join-Path $options.UserDirectory 'rime.lua') '-- Synthetic current user entrypoint'
    Write-Fixture (Join-Path $options.UserDirectory 'lua/cn/cn_translator.lua') 'return {personal_current=true}'
    Write-Fixture (Join-Path $options.UserDirectory 'default.custom.yaml') 'patch: {schema_list: [{schema: cn_stellae}]}'
  }
  $protected=@{}
  foreach($path in Get-ChildItem -LiteralPath $options.UserDirectory -File -Recurse){$protected[$path.FullName]=Hash $path.FullName}
  $failed=$false
  try{$null=& $helper @options}catch{$failed=$true}
  $allowed=$kind -in @('known-default','base-dictionary','current-custom')
  Check "$kind source preflight matches its compatibility boundary" ($failed -ne $allowed)
  foreach($path in $protected.Keys){Check "$kind preflight preserves every original user file" ((Hash $path) -ceq $protected[$path])}
  Check "$kind source preflight has no backup side effect" (-not (Test-Path -LiteralPath $options.BackupDirectory))
}
$installer=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../../installer/install.nsi'))
Check 'formal installer preflights before stopping its old service' ($installer.IndexOf('-Action Preflight') -lt $installer.IndexOf('call_uninstaller:'))
Check 'formal installer preflights before replacing program files' ($installer.IndexOf('-Action Preflight') -lt $installer.IndexOf('program-copy-start'))
Check 'formal installer stages before stopping the previous service' ($installer.IndexOf('-Action Migrate') -lt $installer.IndexOf('call_uninstaller:'))
Check 'formal installer finalizes only after successful configuration deploy' ($installer.IndexOf('-Action Finalize -SharedDirectory') -gt $installer.IndexOf('bundle_deploy_ready:'))
[ordered]@{passed=$true;syntheticFixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS appearance configuration migration: '+$checks.Count)
