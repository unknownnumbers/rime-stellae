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
  $files=@(Get-ChildItem -LiteralPath (Join-Path $payload 'data') -Recurse -File|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath((Join-Path $payload 'data'),$_.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}})
  [ordered]@{bundleVersion='synthetic';files=$files}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $payload 'shared-manifest.json') -Encoding UTF8
}
Set-SyntheticFile (Join-Path $payload 'data/rime.lua') 'return {}'
Set-SyntheticFile (Join-Path $payload 'data/lua/test.lua') 'return {version=1}'
Set-SyntheticFile (Join-Path $payload 'data/obsolete.yaml') 'version: 1'
Set-SyntheticFile (Join-Path $user 'rime.lua') '-- synthetic user entry'
Set-SyntheticFile (Join-Path $user 'lua/test.lua') '-- synthetic user override'
Set-SyntheticFile (Join-Path $user 'default.custom.yaml') 'patch: {}'
Set-SyntheticFile (Join-Path $user 'weasel.custom.yaml') 'patch: {}'
Set-SyntheticFile (Join-Path $user 'fixture.userdb/record') 'synthetic learning sentinel'
Manifest
& $helper -Action Install -SharedDirectory $shared -PayloadDirectory $payload -UserDirectory $user -ReportFile (Join-Path $root 'first.json')
$first=Get-Content -LiteralPath (Join-Path $root 'first.json') -Raw|ConvertFrom-Json
Check 'Fresh shared nested files installed' (Test-Path -LiteralPath (Join-Path $shared 'lua/test.lua'))
Check 'User rime.lua override reported' ('rime.lua' -in $first.userOverrides)
Check 'User Lua override reported' ('lua/test.lua' -in $first.userOverrides)
Check 'User default and UI custom paths reported without shared custom files' ('default.custom.yaml' -in $first.userOverrides -and 'weasel.custom.yaml' -in $first.userOverrides)
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
[ordered]@{passed=$true;syntheticFixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS shared installation policy: '+$checks.Count)
