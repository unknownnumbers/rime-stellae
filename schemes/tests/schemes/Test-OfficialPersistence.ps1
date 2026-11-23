# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory=$true)][string]$EngineDll,
    [Parameter(Mandatory=$true)][string]$SharedData,
    [Parameter(Mandatory=$true)][string]$UserData,
    [Parameter(Mandatory=$true)][string]$ExpectedLearning,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$user = [IO.Path]::GetFullPath($UserData)
if (-not (Test-Path -LiteralPath (Join-Path $user '.synthetic-profile.json'))) { throw 'A synthetic profile marker is required.' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'Choose a fresh persistence output directory.' }
New-Item -ItemType Directory -Path $out | Out-Null
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$api = Get-Content -LiteralPath (Join-Path $repo 'tests/RimeProbe.cs') -Raw -Encoding UTF8
Add-Type -TypeDefinition $api.Replace('__RIME_ENGINE_DLL__', [IO.Path]::GetFullPath($EngineDll))
$traits = New-Object RimeProbe+Traits
$traits.data_size = [Runtime.InteropServices.Marshal]::SizeOf($traits) - 4
$traits.shared_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi([IO.Path]::GetFullPath($SharedData))
$traits.user_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.log_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($out)
$traits.app_name = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.official_persistence_tests')
$traits.min_log_level = 2
$rows = [Collections.Generic.List[object]]::new()
$session = [UIntPtr]::Zero
try {
    [RimeProbe]::RimeSetup([ref]$traits)
    [RimeProbe]::RimeInitialize([ref]$traits)
    $session = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($session, 'pc_research')) { throw 'Cannot reopen official profile.' }
    [RimeProbe]::RimeSetOption($session, 'simplification', 0)
    [RimeProbe]::RimeSetOption($session, 'research_english', 0)
    foreach ($case in @(@{Input='huangxia';Text='黃俠'},@{Input='xia';Text='俠'})) {
        [RimeProbe]::RimeClearComposition($session)
        foreach ($ch in $case.Input.ToCharArray()) { [RimeProbe]::RimeProcessKey($session, [int]$ch, 0) | Out-Null }
        $menu = [RimeProbe]::Snapshot($session, 12)
        $rows.Add([pscustomobject]@{Id=('reopened-'+$case.Input);Passed=($menu.Candidates -contains $case.Text)})
    }
    [RimeProbe]::RimeClearComposition($session)
    [RimeProbe]::RimeDestroySession($session) | Out-Null
    $session = [UIntPtr]::Zero
    $export = Join-Path $out 'reopened-learning.tsv'
    [RimeProbe]::ExportUserDict('luna_pinyin', $export) | Out-Null
    $expected = @(Get-Content -LiteralPath $ExpectedLearning -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object)
    $actual = @(Get-Content -LiteralPath $export -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object)
    $rows.Add([pscustomobject]@{Id='reopened-canonical-learning-counts';Passed=($expected.Count -gt 0 -and ($expected -join "`n") -ceq ($actual -join "`n"));Rows=$actual.Count})
} finally {
    if ($session -ne [UIntPtr]::Zero) { [RimeProbe]::RimeDestroySession($session) | Out-Null }
    [RimeProbe]::RimeFinalize()
    $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if ($rows.Count -ne 3 -or @($rows | Where-Object { -not $_.Passed }).Count) { throw 'Official learning persistence checks failed.' }
Write-Output 'Official learning persistence: 3 checks passed.'
