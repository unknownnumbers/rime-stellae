# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory=$true)][string]$EngineDir,
    [Parameter(Mandatory=$true)][string]$SharedDir,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [ValidateSet('pc','official-weasel')][string]$Profile='pc',
    [string]$ModulesDirectory='',
    [string]$PythonExe='python'
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$work = [IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $work) { throw 'Use a fresh synthetic work directory.' }
[IO.Directory]::CreateDirectory($work) | Out-Null
$engine = Join-Path ([IO.Path]::GetFullPath($EngineDir)) 'rime.dll'
if (-not (Test-Path -LiteralPath $engine)) { throw 'Missing engine DLL.' }
$hostExe = (Get-Process -Id $PID).Path
$results = @()
if (-not $ModulesDirectory) { $ModulesDirectory = Join-Path $repo 'out/dlc/modules/rymcp_dlc' }
if (-not (Test-Path -LiteralPath (Join-Path $ModulesDirectory 'poetry/manifest.tsv'))) { throw 'Build the complete public DLC catalogs before runtime validation.' }

function Run-Checks([string]$name, [string]$scriptName, [string[]]$arguments) {
    $out = Join-Path $work $name
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo ('tests/schemes/' + $scriptName)) -EngineDll $engine -OutputDirectory $out @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw ($name + ' process failed.') }
    $resultPath = Join-Path $out 'results.json'
    if (-not (Test-Path -LiteralPath $resultPath)) { throw ($name + ' did not write results.') }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $checks = @($result.Checks)
    $failed = @($checks | Where-Object { -not $_.Passed })
    if (-not $result.Completed -or -not $checks.Count -or $failed.Count) {
        throw ($name + ' checks did not complete successfully.')
    }
    $summary = [ordered]@{ Scenario=$name; Passed=$checks.Count; Failed=$failed.Count }
    if ($result.ActualFull) { $summary['ActualFullChecks'] = $result.ActualFull.Checks }
    if ($result.FixtureLifecycle) { $summary['FixtureLifecycleChecks'] = $result.FixtureLifecycle.Checks }
    return [pscustomobject]$summary
}

$results += Run-Checks 'chinese-synthetic' 'Test-ChineseDlc.ps1' @()
$results += Run-Checks 'english-synthetic' 'Test-EnglishDlc.ps1' @('-Profile', $Profile)
$results += Run-Checks 'sharded-synthetic' 'Test-ShardedDlc.ps1' @()
$results += Run-Checks 'profile-lifecycle' 'Test-DlcProfile.ps1' @(
    '-ProfileRoot', (Join-Path $repo ('config/' + $Profile)),
    '-ModulesDirectory', ([IO.Path]::GetFullPath($ModulesDirectory)),
    '-SharedDirectory', ([IO.Path]::GetFullPath($SharedDir)),
    '-PythonExe', $PythonExe
)
$capacityFiles = @(Get-ChildItem -LiteralPath (Join-Path $work 'profile-lifecycle') -Filter 'capacity-*.json' -File)
if (-not $capacityFiles.Count) { throw 'Real-module table checks did not run.' }
foreach ($path in $capacityFiles) {
    $result = Get-Content -LiteralPath $path.FullName -Raw | ConvertFrom-Json
    if (-not $result.passed -or -not $result.exact_code_text -or -not @($result.tables).Count) { throw 'Real-module table checks failed.' }
}
$summary = [ordered]@{
    Format='dlc-runtime-validation-v2'; Completed=$true; Profile=$Profile;
    EngineSha256=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant();
    Scenarios=$results; CapacityChecks=$capacityFiles.Count
}
$profileResult = Get-Content -LiteralPath (Join-Path $work 'profile-lifecycle/results.json') -Raw | ConvertFrom-Json
$summary['ActualFullChecks'] = $profileResult.ActualFull.Checks
$summary['FixtureLifecycleChecks'] = $profileResult.FixtureLifecycle.Checks
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work 'validation.json') -Encoding UTF8
Write-Output ('DLC runtime checks passed: ' + $Profile)
