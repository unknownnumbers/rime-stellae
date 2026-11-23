# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory=$true)][string]$EngineDir,
    [Parameter(Mandatory=$true)][string]$SharedDir,
    [Parameter(Mandatory=$true)][string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work = [IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $work) { throw 'Use a fresh synthetic work directory.' }
New-Item -ItemType Directory -Path $work | Out-Null
$engine = Join-Path ([IO.Path]::GetFullPath($EngineDir)) 'rime.dll'
if (-not (Test-Path -LiteralPath $engine)) { throw 'Missing official engine DLL.' }
$env:PATH = ([IO.Path]::GetFullPath($EngineDir)) + ';' + $env:PATH
$hostExe = (Get-Process -Id $PID).Path
$user = Join-Path $work 'chinese-user'
$version = (Get-Content -LiteralPath (Join-Path $repo 'config/official-weasel/profile-manifest.json') -Raw | ConvertFrom-Json).version
python (Join-Path $repo 'scripts/build_scheme_packages.py') --version $version --prepare-official-dir $user
if ($LASTEXITCODE -ne 0) { throw 'Official scheme preparation failed.' }
$cnOutput = Join-Path $work 'chinese-results'
& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests/schemes/Test-OfficialChinese.ps1') -EngineDll $engine -SharedData $SharedDir -UserData $user -OutputDirectory $cnOutput
if ($LASTEXITCODE -ne 0) { throw 'Official Chinese checks failed.' }
$cn = Get-Content -LiteralPath (Join-Path $cnOutput 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cn.Completed -or $cn.Failed -ne 0 -or $cn.Engine -ne '1.13.1') { throw 'Official Chinese validation is incomplete.' }

# The deploy API can succeed while an imported configuration is incomplete.
$compiledSchema = Join-Path $user 'build/pc_research.schema.yaml'
if (-not (Test-Path -LiteralPath $compiledSchema)) { throw 'Compiled official schema is missing.' }
$schemaText = [IO.File]::ReadAllText($compiledSchema)
if ($schemaText -notmatch '(?m)^speller:' -or $schemaText -notmatch '(?m)^engine:') { throw 'Compiled official schema is incomplete.' }
$results = @([pscustomobject]@{Scenario='Chinese';Checks=[int]$cn.Passed;Passed=$true})
$exactOutput = Join-Path $work 'exact-results'
& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests/schemes/Test-ExactSyllable.ps1') -EngineDll $engine -ProfileRoot (Join-Path $repo 'config/official-weasel') -SharedDirectory $SharedDir -OutputDirectory $exactOutput
if ($LASTEXITCODE -ne 0) { throw 'Official exact syllable checks failed.' }
$exact = Get-Content -LiteralPath (Join-Path $exactOutput 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $exact.Completed -or -not $exact.Passed -or -not @($exact.Checks).Count -or @($exact.Checks | Where-Object { -not $_.Passed }).Count) { throw 'Official exact syllable validation is incomplete.' }
$results += [pscustomobject]@{Scenario='Exact';Checks=@($exact.Checks).Count;Passed=$true}
foreach ($scenario in @('English','Bracket')) {
    $testUser = Join-Path $work ($scenario.ToLowerInvariant() + '-user')
    New-Item -ItemType Directory -Path $testUser | Out-Null
    # Only fixed source/build files from this freshly created profile are copied.
    $manifest = Get-Content -LiteralPath (Join-Path $repo 'config/official-weasel/profile-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        if ($relative.StartsWith('samples/')) { $relative = $relative.Substring(8) }
        $target = Join-Path $testUser $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $user $relative) -Destination $target
    }
    Copy-Item -LiteralPath (Join-Path $user 'build') -Destination (Join-Path $testUser 'build') -Recurse
    '{"kind":"fixed-synthetic-profile","format":1}' | Set-Content -LiteralPath (Join-Path $testUser '.synthetic-profile.json') -Encoding UTF8
    $out = Join-Path $work ($scenario.ToLowerInvariant() + '-results')
    if ($scenario -eq 'English') {
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests/schemes/Test-OfficialEnglish.ps1') -EngineDll $engine -SharedData $SharedDir -UserData $testUser -OutputDirectory $out
        if ($LASTEXITCODE -ne 0) { throw 'Official English checks failed.' }
        $en = Get-Content -LiteralPath (Join-Path $out 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $en.Completed -or $en.Failed -ne 0) { throw 'Official English validation is incomplete.' }
        $results += [pscustomobject]@{Scenario='English';Checks=[int]$en.Passed;Passed=$true}
    } else {
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests/schemes/Test-BracketLearning.ps1') -EngineDll $engine -SharedData $SharedDir -UserData $testUser -OutputDirectory $out -SkipJapanese
        if ($LASTEXITCODE -ne 0) { throw 'Official bracket learning checks failed.' }
        $rows = Get-Content -LiteralPath (Join-Path $out 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $rows.Count -or @($rows | Where-Object { -not $_.Passed }).Count) { throw 'Missing or failed official bracket assertions.' }
        $results += [pscustomobject]@{Scenario='Bracket';Checks=$rows.Count;Passed=$true}
    }
}
$persistenceOutput = Join-Path $work 'persistence-results'
& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests/schemes/Test-OfficialPersistence.ps1') -EngineDll $engine -SharedData $SharedDir -UserData (Join-Path $work 'bracket-user') -ExpectedLearning (Join-Path $work 'bracket-results/learning.tsv') -OutputDirectory $persistenceOutput
if ($LASTEXITCODE -ne 0) { throw 'Official persistence checks failed.' }
$results += [pscustomobject]@{Scenario='Persistence';Checks=3;Passed=$true}
$summary = [pscustomobject]@{Format='rymcp-official-scheme-validation-v1';Version=$version;Engine='1.13.1';Passed=$true;Results=$results}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'validation.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
