# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$EngineDll,
  [Parameter(Mandatory)][string]$SharedData,
  [Parameter(Mandatory)][string]$SchemeSource,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Use a disposable hosted runner'}
$hostExe=(Get-Process -Id $PID).Path
& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SchemeSource 'scripts/schemes/Test-SharedProfile.ps1') -EngineDll $EngineDll -SharedData $SharedData -WorkRoot $OutputDirectory
if($LASTEXITCODE){throw 'Installed shared-only scheme tests failed'}
$report=Get-Content -LiteralPath (Join-Path $OutputDirectory 'validation.json') -Raw|ConvertFrom-Json
if(-not $report.Passed -or $report.SharedChecks -lt 18){throw 'Installed shared-only validation is incomplete'}
$priorityOut=Join-Path $OutputDirectory 'preset-priority'
& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-BundlePresetPriority.ps1') -EngineDll $EngineDll -SharedData $SharedData -SchemeSource $SchemeSource -OutputDirectory $priorityOut -SeedBuildDirectory (Join-Path $OutputDirectory 'empty-user/build')
if($LASTEXITCODE){throw 'Bundle preset and user customization priority failed'}
$priority=Get-Content -LiteralPath (Join-Path $priorityOut 'result.json') -Raw|ConvertFrom-Json
if(-not $priority.passed -or $priority.cases.Count -ne 3){throw 'Bundle preset priority validation is incomplete'}
[ordered]@{passed=$true;sharedOnly=$true;userSourcesCopied=$false;architecture=$(if([Environment]::Is64BitProcess){'x64'}else{'Win32'});sharedChecks=$report.SharedChecks;learning=$report.Learning;presetPriorityChecks=$priority.checks;presetPriorityCases=3}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json') -Encoding UTF8
