# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory=$true)][string]$EngineDll,
    [Parameter(Mandatory=$true)][string]$SharedData,
    [Parameter(Mandatory=$true)][string]$UserData,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$dir = [IO.Path]::GetFullPath($OutputDirectory)
$user = [IO.Path]::GetFullPath($UserData)
if (-not (Test-Path -LiteralPath (Join-Path $user '.synthetic-profile.json'))) {
    throw 'A freshly compiled synthetic profile is required.'
}
if (Test-Path -LiteralPath $dir) { throw 'Choose a fresh result directory.' }
New-Item -ItemType Directory -Path $dir | Out-Null
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$api = Get-Content -LiteralPath (Join-Path $repo 'tests/RimeProbe.cs') -Raw
Add-Type -TypeDefinition $api.Replace('__RIME_ENGINE_DLL__', [IO.Path]::GetFullPath($EngineDll))
$traits = New-Object RimeProbe+Traits
$traits.data_size = [Runtime.InteropServices.Marshal]::SizeOf($traits) - 4
$traits.shared_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi([IO.Path]::GetFullPath($SharedData))
$traits.user_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.log_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($dir)
$traits.prebuilt_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi((Join-Path $user 'build'))
$traits.staging_dir = $traits.prebuilt_data_dir
$traits.app_name = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.removed_mixed_tests')
$traits.min_log_level = 2
$rows = [Collections.Generic.List[object]]::new()
$s = [UIntPtr]::Zero
function Query([string]$raw) {
    [RimeProbe]::RimeClearComposition($s)
    [void][RimeProbe]::ReadCommit($s)
    foreach ($ch in $raw.ToCharArray()) {
        $mask = if ([char]::IsUpper($ch)) { 1 } else { 0 }
        [void][RimeProbe]::RimeProcessKey($s, [int]$ch, $mask)
        [void][RimeProbe]::RimeProcessKey($s, [int]$ch, ($mask -bor 0x40000000))
    }
    $menu = [RimeProbe]::Snapshot($s, 1000)
    return [pscustomobject]@{Raw=[RimeProbe]::Input($s);Commit=[RimeProbe]::ReadCommit($s);Candidates=@($menu.Candidates)}
}
function Check([string]$name, [bool]$passed, $detail=$null) {
    $rows.Add([pscustomobject]@{Check=$name;Passed=$passed;Detail=$detail})
}
try {
    [RimeProbe]::RimeSetup([ref]$traits)
    [RimeProbe]::RimeInitialize([ref]$traits)
    $s = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($s, 'cn_stellae')) { throw 'Cannot load cn_stellae.' }
    [RimeProbe]::RimeSetOption($s, 'probe_options_ready', 1)
    [RimeProbe]::RimeSetOption($s, 'ascii_mode', 0)
    [RimeProbe]::RimeSetOption($s, 'research_english', 0)
    foreach ($sc in $false, $true) {
        [RimeProbe]::RimeSetOption($s, 'simplification', [int]$sc)
        foreach ($case in @(
            @('upan',@('U 盘','U 盤')),@('asizhi',@('A4 纸','A4 紙')),
            @('sanddayin',@('3D 打印')),@('windowsban',@('Windows 版')),
            @('wifimima',@('Wi-Fi 密码','Wi-Fi 密碼'))
        )) {
            $state = Query $case[0]
            $found = @($case[1] | Where-Object { $_ -cin $state.Candidates })
            Check ('removed-fixed-word-'+$case[0]+'-'+$sc) ($state.Raw -ceq $case[0] -and -not $state.Commit -and $found.Count -eq 0) $found
        }
    }
    $state = Query 'nihao'
    Check 'ordinary-Chinese-preserved' ($state.Candidates -ccontains '你好') @($state.Candidates | Select-Object -First 6)
    $state = Query 'alpha'
    Check 'named-symbol-preserved' ($state.Candidates -ccontains 'α') @($state.Candidates | Select-Object -First 6)
    [RimeProbe]::RimeSetOption($s, 'research_english', 1)
    $state = Query 'hepl'
    Check 'English-correction-preserved' ($state.Candidates -ccontains 'help') @($state.Candidates | Select-Object -First 6)
    [RimeProbe]::RimeClearComposition($s)
    [void][RimeProbe]::RimeDestroySession($s)
    $s = [UIntPtr]::Zero
    Check 'removed-learning-store-not-created' (-not (Test-Path -LiteralPath (Join-Path $user 'pc_mixed.userdb')))
} finally {
    if ($s -ne [UIntPtr]::Zero) { [void][RimeProbe]::RimeDestroySession($s) }
    [RimeProbe]::RimeFinalize()
    foreach ($pointer in @($traits.shared_data_dir,$traits.user_data_dir,$traits.prebuilt_data_dir,$traits.log_dir,$traits.app_name)) {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
    }
    $rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'results.json') -Encoding UTF8
}
$failed = @($rows | Where-Object { -not $_.Passed })
[pscustomobject]@{Checks=$rows.Count;Failed=$failed} | ConvertTo-Json -Depth 6
if ($failed.Count) { exit 1 }
