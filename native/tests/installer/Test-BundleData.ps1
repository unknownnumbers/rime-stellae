# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new synthetic fixture directory'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$root=(Resolve-Path -LiteralPath $OutputDirectory).Path
$shared=Join-Path $root 'shared'
$user=Join-Path $root 'user'
$payload=Join-Path $root 'payload'
$null=New-Item -ItemType Directory -Path $shared,$user,(Join-Path $payload 'data/lua') -Force
$helper=Join-Path $PSScriptRoot '../../../installer/BundleData.ps1'
$checks=@()
function Check([string]$Name,[bool]$Passed){$script:checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name}}
function Set-SyntheticFile([string]$Path,[string]$Value){$null=New-Item -ItemType Directory -Path (Split-Path $Path) -Force;[IO.File]::WriteAllText($Path,$Value)}
function Manifest {
  $dataRoot=(Join-Path $payload 'data')
  $files=@(Get-ChildItem -LiteralPath $dataRoot -Recurse -File|ForEach-Object{[ordered]@{path=$_.FullName.Substring($dataRoot.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
  [ordered]@{bundleVersion='synthetic';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $payload 'shared-manifest.json') -Encoding UTF8
}
Set-SyntheticFile (Join-Path $payload 'data/rime.lua') 'return {}'
Set-SyntheticFile (Join-Path $payload 'data/lua/test.lua') 'return {version=1}'
Set-SyntheticFile (Join-Path $payload 'data/obsolete.yaml') 'version: 1'
Set-SyntheticFile (Join-Path $user 'rime.lua') '-- synthetic user entry'
Set-SyntheticFile (Join-Path $user 'lua/test.lua') '-- synthetic user override'
Set-SyntheticFile (Join-Path $user 'default.custom.yaml') 'patch: {}'
Set-SyntheticFile (Join-Path $user 'stellae.custom.yaml') 'patch: {}'
Set-SyntheticFile (Join-Path $user 'fixture.userdb/record') 'synthetic learning sentinel'
Manifest
& $helper -Action Install -SharedDirectory $shared -PayloadDirectory $payload -UserDirectory $user -ReportFile (Join-Path $root 'first.json')
$first=Get-Content -LiteralPath (Join-Path $root 'first.json') -Raw|ConvertFrom-Json
Check 'Fresh shared nested files installed' (Test-Path -LiteralPath (Join-Path $shared 'lua/test.lua'))
Check 'User rime.lua override reported' ('rime.lua' -in $first.userOverrides)
Check 'User Lua override reported' ('lua/test.lua' -in $first.userOverrides)
Check 'User default and UI custom paths reported without shared custom files' ('default.custom.yaml' -in $first.userOverrides -and 'stellae.custom.yaml' -in $first.userOverrides)
Check 'User learning sentinel preserved' ((Get-Content -LiteralPath (Join-Path $user 'fixture.userdb/record') -Raw) -eq 'synthetic learning sentinel')
Set-SyntheticFile (Join-Path $shared 'lua/test.lua') '-- locally modified shared source'
Set-SyntheticFile (Join-Path $shared 'custom/unknown.yaml') 'unknown: retained'
Set-SyntheticFile (Join-Path $payload 'data/lua/test.lua') 'return {version=2}'
Set-SyntheticFile (Join-Path $payload 'data/rime.lua') 'return {version=2}'
Remove-Item -LiteralPath (Join-Path $payload 'data/obsolete.yaml')
Manifest
& $helper -Action Install -SharedDirectory $shared -PayloadDirectory $payload -UserDirectory $user -ReportFile (Join-Path $root 'upgrade.json')
$upgrade=Get-Content -LiteralPath (Join-Path $root 'upgrade.json') -Raw|ConvertFrom-Json
Check 'Modified shared file preserved on upgrade' ((Get-Content -LiteralPath (Join-Path $shared 'lua/test.lua') -Raw) -eq '-- locally modified shared source')
Check 'Modified shared conflict reported' ('lua/test.lua' -in $upgrade.sharedConflicts)
Check 'Unmodified managed source upgraded' ((Get-Content -LiteralPath (Join-Path $shared 'rime.lua') -Raw) -eq 'return {version=2}')
Check 'Stale unmodified managed source removed' (-not (Test-Path -LiteralPath (Join-Path $shared 'obsolete.yaml')))
Check 'Unknown nested source preserved' (Test-Path -LiteralPath (Join-Path $shared 'custom/unknown.yaml'))
& $helper -Action Uninstall -SharedDirectory $shared -ReportFile (Join-Path $root 'uninstall.json')
Check 'Uninstall removes unmodified managed source' (-not (Test-Path -LiteralPath (Join-Path $shared 'rime.lua')))
Check 'Uninstall preserves modified shared source' (Test-Path -LiteralPath (Join-Path $shared 'lua/test.lua'))
Check 'Uninstall preserves unknown nested source' (Test-Path -LiteralPath (Join-Path $shared 'custom/unknown.yaml'))
Check 'Uninstall preserves user source' ((Get-Content -LiteralPath (Join-Path $user 'rime.lua') -Raw) -eq '-- synthetic user entry')
Check 'Uninstall preserves synthetic learning' ((Get-Content -LiteralPath (Join-Path $user 'fixture.userdb/record') -Raw) -eq 'synthetic learning sentinel')
$bareShared=Join-Path $root 'bare-shared'
$barePayload=Join-Path $root 'bare-payload'
$null=New-Item -ItemType Directory -Path $bareShared,(Join-Path $barePayload 'data') -Force
Set-SyntheticFile (Join-Path $bareShared 'default.yaml') 'old empty bare default'
$defaultPredecessor=(Get-FileHash -LiteralPath (Join-Path $bareShared 'default.yaml')).Hash.ToLowerInvariant()
Set-SyntheticFile (Join-Path $bareShared 'symbols.yaml') 'original bare symbols'
$symbolsPredecessor=(Get-FileHash -LiteralPath (Join-Path $bareShared 'symbols.yaml')).Hash.ToLowerInvariant()
Set-SyntheticFile (Join-Path $bareShared 'symbols.yaml') 'locally modified bare symbols'
Set-SyntheticFile (Join-Path $bareShared 'unknown.yaml') 'unknown local source'
foreach($name in @('default.yaml','symbols.yaml','unknown.yaml')){Set-SyntheticFile (Join-Path $barePayload ('data/'+$name)) ('new bundled '+$name)}
$bareSpec=[ordered]@{bundleVersion='synthetic';predecessors=@(
  [ordered]@{path='default.yaml';sha256=$defaultPredecessor},
  [ordered]@{path='symbols.yaml';sha256=$symbolsPredecessor}
);files=@(Get-ChildItem -LiteralPath (Join-Path $barePayload 'data') -File|ForEach-Object{[ordered]@{path=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})}
$bareManifest=Join-Path $barePayload 'shared-manifest.json'
$bareSpec|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $bareManifest -Encoding UTF8
& $helper -Action Install -SharedDirectory $bareShared -PayloadDirectory $barePayload -UserDirectory $user -ReportFile (Join-Path $root 'bare-upgrade.json')
$bareResult=Get-Content -LiteralPath (Join-Path $root 'bare-upgrade.json') -Raw|ConvertFrom-Json
Check 'Bare predecessor default is replaced' ((Get-Content -LiteralPath (Join-Path $bareShared 'default.yaml') -Raw) -eq 'new bundled default.yaml')
Check 'Modified bare predecessor is preserved' ((Get-Content -LiteralPath (Join-Path $bareShared 'symbols.yaml') -Raw) -eq 'locally modified bare symbols')
Check 'Unknown bare source is preserved' ((Get-Content -LiteralPath (Join-Path $bareShared 'unknown.yaml') -Raw) -eq 'unknown local source')
Check 'Bare default is not a conflict' ('default.yaml' -notin $bareResult.sharedConflicts)
Check 'Modified and unknown bare conflicts are reported' ('symbols.yaml' -in $bareResult.sharedConflicts -and 'unknown.yaml' -in $bareResult.sharedConflicts)
# A predecessor hint must not override the ownership recorded by a bundle.
$bareSpec.predecessors=@([ordered]@{path='symbols.yaml';sha256=(Get-FileHash -LiteralPath (Join-Path $bareShared 'symbols.yaml')).Hash.ToLowerInvariant()})
$bareSpec|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $bareManifest -Encoding UTF8
& $helper -Action Install -SharedDirectory $bareShared -PayloadDirectory $barePayload -UserDirectory $user
Check 'Existing bundle ownership prevents predecessor reseeding' ((Get-Content -LiteralPath (Join-Path $bareShared 'symbols.yaml') -Raw) -eq 'locally modified bare symbols')
$compat=Join-Path $root 'without-hash-cmdlet.ps1'
@'
param([string]$Helper,[string]$Payload,[string]$Shared,[string]$User,[string]$Report)
$ErrorActionPreference='Stop'
function global:Get-FileHash { throw [System.Management.Automation.CommandNotFoundException]::new('Synthetic unavailable Get-FileHash') }
& $Helper -Action Install -SharedDirectory $Shared -PayloadDirectory $Payload -UserDirectory $User -ReportFile $Report
'@|Set-Content -LiteralPath $compat -Encoding UTF8
$compatReport=Join-Path $root 'without-hash-cmdlet.json'
& "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $compat -Helper $helper -Payload $payload -Shared (Join-Path $root 'without-hash-shared') -User $user -Report $compatReport
$compatExit=$LASTEXITCODE
Check 'Windows PowerShell helper works without Get-FileHash' ($compatExit -eq 0 -and (Get-Content -LiteralPath $compatReport -Raw|ConvertFrom-Json).passed)
function Math-Case([string]$Name,[switch]$ChangedCatalog,[switch]$CurrentIndex,[switch]$ModifiedIndex,[switch]$Defer){
  $case=Join-Path $root ('math-'+$Name);$userRoot=Join-Path $case 'user';$sharedRoot=Join-Path $case 'shared';$inputRoot=Join-Path $case 'payload'
  $null=New-Item -ItemType Directory -Path $sharedRoot,(Join-Path $inputRoot 'data') -Force
  Set-SyntheticFile (Join-Path $inputRoot 'data/default.yaml') 'config_version: synthetic-math'
  $rows=@([ordered]@{path='default.yaml';sha256=(Get-FileHash -LiteralPath (Join-Path $inputRoot 'data/default.yaml')).Hash.ToLowerInvariant()})
  [ordered]@{bundleVersion='synthetic-math';files=$rows}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $inputRoot 'shared-manifest.json') -Encoding UTF8
  $math=Join-Path $userRoot 'stellae_dlc/math';Set-SyntheticFile (Join-Path $math 'english.tsv') 'fixed synthetic English catalog'
  $catalogHash=(Get-FileHash -LiteralPath (Join-Path $math 'english.tsv')).Hash.ToLowerInvariant()
  $oldManifest=Join-Path $case 'original-manifest.tsv';Set-SyntheticFile $oldManifest 'previous Chinese header namespace'
  $oldManifestHash=(Get-FileHash -LiteralPath $oldManifest).Hash.ToLowerInvariant()
  Set-SyntheticFile (Join-Path $math 'manifest.tsv') 'new Chinese header namespace'
  if($ChangedCatalog){Set-SyntheticFile (Join-Path $math 'english.tsv') 'personal changed English catalog'}
  $indexes=@()
  foreach($name in @('keys.bin','postings.bin','words.txt')){
    $file=Join-Path $inputRoot ('migrations/math/english_index/'+$name);Set-SyntheticFile $file ('prepared fixed '+$name)
    $indexes+=@([ordered]@{name=$name;sha256=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()})
    if($CurrentIndex){Set-SyntheticFile (Join-Path $math ('english_index/'+$name)) ('prepared fixed '+$name)}
  }
  if($ModifiedIndex){Set-SyntheticFile (Join-Path $math 'english_index/keys.bin') 'personal existing index'}
  [ordered]@{format='stellae-bundle-user-upgrade-v1';previousLua=@();math=[ordered]@{catalogSha256=$catalogHash;manifestSha256=$oldManifestHash;index=$indexes}}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $inputRoot 'migrations/upgrade.json') -Encoding UTF8
  $report=Join-Path $case 'install.json'
  & $helper -Action Install -SharedDirectory $sharedRoot -PayloadDirectory $inputRoot -UserDirectory $userRoot -DeferMathIndex:$Defer -ReportFile $report
  $result=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
  if($Defer){
    Check 'formal install can defer the prepared index until namespace finalization' ($result.mathIndex -ceq 'deferred' -and -not (Test-Path -LiteralPath (Join-Path $math 'english_index')))
    $ownershipHash=(Get-FileHash -LiteralPath (Join-Path $sharedRoot 'stellae-managed-files.json')).Hash
    $report=Join-Path $case 'ensure.json'
    & $helper -Action EnsureMathIndex -SharedDirectory $sharedRoot -PayloadDirectory $inputRoot -UserDirectory $userRoot -ReportFile $report
    $result=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
    Check 'index-only completion does not reinstall or alter shared ownership' ((Get-FileHash -LiteralPath (Join-Path $sharedRoot 'stellae-managed-files.json')).Hash -ceq $ownershipHash -and $result.installed.Count -eq 0)
  }
  $expected=if($ChangedCatalog){'preserved-catalog'}elseif($ModifiedIndex){'preserved-index'}elseif($CurrentIndex){'current'}else{'installed'}
  Check ($Name+' uses the prepared index only for its exact English catalog') ($result.mathIndex -ceq $expected)
  if($ChangedCatalog){Check 'different English catalog creates no prepared index files' (-not (Test-Path -LiteralPath (Join-Path $math 'english_index')))}
  elseif($ModifiedIndex){Check 'unknown existing index is retained byte-exactly' ((Get-Content -LiteralPath (Join-Path $math 'english_index/keys.bin') -Raw) -ceq 'personal existing index' -and -not (Test-Path -LiteralPath (Join-Path $math 'english_index/postings.bin')))}
  else{foreach($entry in $indexes){Check ($Name+' retains prepared bytes '+$entry.name) ((Get-FileHash -LiteralPath (Join-Path $math ('english_index/'+$entry.name))).Hash.ToLowerInvariant() -ceq $entry.sha256)}}
}
Math-Case namespace-only-manifest-change
Math-Case changed-catalog -ChangedCatalog
Math-Case existing-prepared-index -CurrentIndex
Math-Case personal-index -ModifiedIndex
Math-Case deferred-index -Defer
[ordered]@{passed=$true;syntheticFixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS shared installation policy: '+$checks.Count)
