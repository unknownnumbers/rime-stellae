# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new synthetic fixture directory'}
$root=[IO.Path]::GetFullPath($OutputDirectory)
$null=New-Item -ItemType Directory -Path $root
$helper=Join-Path $PSScriptRoot '../../../installer/BundleData.ps1'
$checks=@()
function Check([string]$Name,[bool]$Passed){$script:checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name}}
function Write-Fixture([string]$Path,[string]$Text){$null=New-Item -ItemType Directory -Path (Split-Path $Path) -Force;[IO.File]::WriteAllText($Path,$Text)}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
function Run-Case([string]$Name,[switch]$ModifyLua,[switch]$ModifyCustom,[switch]$ModifySharedLua,[switch]$PreviousManagedRevision,[switch]$LegacyDefaultAlias){
  $case=Join-Path $root $Name
  $shared=Join-Path $case 'shared'
  $user=Join-Path $case 'user'
  $payload=Join-Path $case 'payload'
  $old=@{'rime.lua'="return require('cn_translator')";'lua/cn_translator.lua'='return {old=true}';'cn_stellae.custom.yaml'='patch: {menu/page_size: 6}';'weasel.custom.yaml'='patch: {style/font_point: 14}';'default.custom.yaml'='patch: {schema_list: [{schema: previous_public}]}'}
  $records=@()
  foreach($path in $old.Keys){
    Write-Fixture (Join-Path $shared $path) $old[$path]
    Write-Fixture (Join-Path $user $path) $old[$path]
    $records+=@([ordered]@{path=$path;sha256=(Hash (Join-Path $shared $path));group=$(if($path.EndsWith('.lua')){'lua'}else{'configuration'})})
  }
  if($PreviousManagedRevision){
    Write-Fixture (Join-Path $shared 'lua/cn_translator.lua') 'return {another_public_revision=true}'
    Write-Fixture (Join-Path $user 'lua/cn_translator.lua') 'return {another_public_revision=true}'
    Write-Fixture (Join-Path $shared 'default.custom.yaml') 'patch: {schema_list: [{schema: another_public_revision}]}'
    Write-Fixture (Join-Path $user 'default.custom.yaml') 'patch: {schema_list: [{schema: another_public_revision}]}'
  }
  $defaultAlias=if($LegacyDefaultAlias){'rymcp_bundle_default.yaml'}else{'stellae_bundle_default.yaml'}
  $owned=@(foreach($entry in $records){[ordered]@{path=$(if($entry.path -ceq 'default.custom.yaml'){$defaultAlias}else{$entry.path});sha256=(Hash (Join-Path $shared $entry.path));group=$entry.group}})
  [IO.File]::Move((Join-Path $shared 'default.custom.yaml'),(Join-Path $shared $defaultAlias))
  [ordered]@{format='stellae-managed-shared-v1';bundleVersion='previous';files=$owned}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $shared 'stellae-managed-files.json') -Encoding UTF8
  Write-Fixture (Join-Path $user 'fixture.userdb/record') 'synthetic learning'
  Write-Fixture (Join-Path $user 'stellae_dlc/custom/manifest.tsv') 'synthetic DLC'
  Write-Fixture (Join-Path $user 'unknown.lua') 'return {personal=true}'
  if($ModifyLua){Write-Fixture (Join-Path $user 'lua/cn_translator.lua') 'return {personal=true}'}
  if($ModifySharedLua){Write-Fixture (Join-Path $shared 'lua/cn_translator.lua') 'return {shared_personal=true}'}
  if($ModifyCustom){Write-Fixture (Join-Path $user 'cn_stellae.custom.yaml') 'patch: {menu/page_size: 9}'}
  Write-Fixture (Join-Path $payload 'data/rime.lua') "return require('cn.cn_translator')"
  Write-Fixture (Join-Path $payload 'data/lua/cn/cn_translator.lua') 'return {current=true}'
  Write-Fixture (Join-Path $payload 'data/cn_stellae.custom.yaml') "patch:`n"
  Write-Fixture (Join-Path $payload 'data/stellae.yaml') 'config_version: current'
  Write-Fixture (Join-Path $payload 'data/stellae_bundle_default.yaml') 'patch: {schema_list: [{schema: current_public}]}'
  Write-Fixture (Join-Path $payload 'migrations/source-layout.json') ([ordered]@{format='stellae-source-layout-upgrade-v1';previousSourceRef=('a'*40);files=$records}|ConvertTo-Json -Depth 6)
  $dataRoot=(Join-Path $payload 'data')
  $current=@(Get-ChildItem -LiteralPath $dataRoot -Recurse -File|ForEach-Object{[ordered]@{path=$_.FullName.Substring($dataRoot.Length+1).Replace('\','/');sha256=(Hash $_.FullName)}})
  [ordered]@{bundleVersion='current';files=$current}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $payload 'shared-manifest.json') -Encoding UTF8
  $report=Join-Path $case 'upgrade.json'
  & $helper -Action Install -SharedDirectory $shared -PayloadDirectory $payload -UserDirectory $user -ReportFile $report
  $proof=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
  Check "$Name leaves the old appearance custom for post-deploy finalization" ((Get-Content -LiteralPath (Join-Path $user 'weasel.custom.yaml') -Raw) -ceq $old['weasel.custom.yaml'])
  Check "$Name retires an exact former shared preset copied into user defaults" (-not (Test-Path -LiteralPath (Join-Path $user 'default.custom.yaml')))
  if($ModifyLua -or $ModifySharedLua){
    Check "$Name retains the old entrypoint with its modified module" ((Get-Content -LiteralPath (Join-Path $user 'rime.lua') -Raw) -ceq $old['rime.lua'])
    if($ModifyLua){Check "$Name retains modified Lua bytes" ((Get-Content -LiteralPath (Join-Path $user 'lua/cn_translator.lua') -Raw) -ceq 'return {personal=true}')}
    if($ModifySharedLua){Check "$Name retains modified shared Lua bytes" ((Get-Content -LiteralPath (Join-Path $shared 'lua/cn_translator.lua') -Raw) -ceq 'return {shared_personal=true}')}
    Check "$Name keeps owned flat shared dependencies" (Test-Path -LiteralPath (Join-Path $shared 'lua/cn_translator.lua'))
    Check "$Name reports the source merge" ($proof.manualMergeRequired -and ('lua/cn_translator.lua' -in $proof.userSourceConflicts -or 'lua/cn_translator.lua' -in $proof.sharedConflicts))
  }else{
    Check "$Name retires the known old user entrypoint" (-not (Test-Path -LiteralPath (Join-Path $user 'rime.lua')))
    Check "$Name retires the known old flat user module" (-not (Test-Path -LiteralPath (Join-Path $user 'lua/cn_translator.lua')))
    Check "$Name removes the old managed shared module" (-not (Test-Path -LiteralPath (Join-Path $shared 'lua/cn_translator.lua')))
    Check "$Name installs the grouped shared module" (Test-Path -LiteralPath (Join-Path $shared 'lua/cn/cn_translator.lua'))
  }
  if($ModifyCustom){
    Check "$Name retains the personal custom patch" ((Get-Content -LiteralPath (Join-Path $user 'cn_stellae.custom.yaml') -Raw) -ceq 'patch: {menu/page_size: 9}')
    Check "$Name reports the custom merge" ('cn_stellae.custom.yaml' -in $proof.userSourceConflicts)
  }else{
    Check "$Name retires unchanged former product defaults" (-not (Test-Path -LiteralPath (Join-Path $user 'cn_stellae.custom.yaml')))
  }
  & $helper -Action Install -SharedDirectory $shared -PayloadDirectory $payload -UserDirectory $user
  & $helper -Action Uninstall -SharedDirectory $shared
  Check "$Name preserves learning through repeat upgrade and uninstall" ((Get-Content -LiteralPath (Join-Path $user 'fixture.userdb/record') -Raw) -ceq 'synthetic learning')
  Check "$Name preserves DLC through repeat upgrade and uninstall" ((Get-Content -LiteralPath (Join-Path $user 'stellae_dlc/custom/manifest.tsv') -Raw) -ceq 'synthetic DLC')
  Check "$Name preserves unknown user code" ((Get-Content -LiteralPath (Join-Path $user 'unknown.lua') -Raw) -ceq 'return {personal=true}')
}
Run-Case clean
Run-Case custom -ModifyCustom
Run-Case lua -ModifyLua
Run-Case shared-lua -ModifySharedLua
Run-Case prior-public-revision -PreviousManagedRevision
Run-Case prior-public-legacy-default -PreviousManagedRevision -LegacyDefaultAlias
Run-Case modified-prior-public-revision -PreviousManagedRevision -ModifySharedLua
[ordered]@{passed=$true;syntheticFixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS source layout installation policy: '+$checks.Count)
