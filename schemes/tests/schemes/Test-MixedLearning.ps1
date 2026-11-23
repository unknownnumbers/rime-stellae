# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory=$true)][string]$EngineDll,
    [Parameter(Mandatory=$true)][string]$SharedData,
    [Parameter(Mandatory=$true)][string]$UserData,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$SkipJapanese
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
$traits.app_name = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.scheme_learning_tests')
$traits.min_log_level = 2
$rows = [Collections.Generic.List[object]]::new()
$s = [UIntPtr]::Zero

function Stroke([int]$key, [int]$mask=0) {
    [RimeProbe]::RimeProcessKey($s, $key, $mask) | Out-Null
    [RimeProbe]::RimeProcessKey($s, $key, ($mask -bor 0x40000000)) | Out-Null
}
function State {
    $menu = [RimeProbe]::Snapshot($s, 6)
    return [pscustomobject]@{Raw=[RimeProbe]::Input($s);Preedit=$menu.Preedit;Commit=[RimeProbe]::ReadCommit($s);Candidates=$menu.Candidates}
}
function Highlight([string]$text) {
    $menu = [RimeProbe]::Snapshot($s, 250)
    $index = [Array]::IndexOf($menu.Candidates, $text)
    if ($index -lt 0) { throw "Missing candidate $text" }
    $moves = 0
    while ($menu.HighlightedIndex -ne $index) {
        if (++$moves -gt 300) { throw "Cannot highlight target candidate" }
        Stroke $(if ($menu.HighlightedIndex -lt $index) { 0xff54 } else { 0xff52 })
        $menu = [RimeProbe]::Snapshot($s, 250)
    }
}
function Pick([string]$text) { Highlight $text; Stroke 0x20 }
function Query([string]$raw, [bool]$sc=$false) {
    [RimeProbe]::RimeClearComposition($s)
    [RimeProbe]::ReadCommit($s) | Out-Null
    [RimeProbe]::RimeSetOption($s, 'simplification', [int]$sc)
    foreach ($ch in $raw.ToCharArray()) {
        Stroke ([int]$ch) $(if ([char]::IsUpper($ch)) { 1 } else { 0 })
    }
}
function Check([string]$name, [bool]$passed, $detail=$null) {
    $rows.Add([pscustomobject]@{Check=$name;Passed=$passed;Detail=$detail})
}

$expected = @{}
$cases = @(
    @{Raw='upan';Text='U 盤';Sc='U 盘';First='盤';Last='盤';FirstSc='盘';LastSc='盘';FirstCode='pan';LastCode='pan'},
    @{Raw='asizhi';Text='A4 紙';Sc='A4 纸';First='紙';Last='紙';FirstSc='纸';LastSc='纸';FirstCode='zhi';LastCode='zhi'},
    @{Raw='sanddayin';Text='3D 打印';Sc='3D 打印';First='打';Last='印';FirstSc='打';LastSc='印';FirstCode='da';LastCode='yin'},
    @{Raw='windowsban';Text='Windows 版';Sc='Windows 版';First='版';Last='版';FirstSc='版';LastSc='版';FirstCode='ban';LastCode='ban'},
    @{Raw='wifimima';Text='Wi-Fi 密碼';Sc='Wi-Fi 密码';First='密';Last='碼';FirstSc='密';LastSc='码';FirstCode='mi';LastCode='ma'}
)
function AddExpected([string]$text, [string]$code) {
    $key = $text + [char]9 + $code
    $expected[$key] = 1 + $expected[$key]
}
function Export([string]$name, [string]$file) {
    $path = Join-Path $dir $file
    if ([RimeProbe]::ExportUserDict($name, $path) -lt 0) { throw "Cannot export closed dictionary $name" }
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
}

[RimeProbe]::RimeSetup([ref]$traits)
[RimeProbe]::RimeInitialize([ref]$traits)
[RimeProbe]::RimeDeployerInitialize([ref]$traits)
try {
    $s = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($s, 'pc_research')) { throw 'Cannot load pc_research' }
    [RimeProbe]::RimeSetOption($s, 'probe_options_ready', 1)
    foreach ($sc in $false, $true) {
        foreach ($case in $cases) {
            foreach ($key in 0x5b, 0x5d) {
                $word = if ($sc) { $case.Sc } else { $case.Text }
                if ($key -eq 0x5b) {
                    $canonical = $case.First
                    $shown = if ($sc) { $case.FirstSc } else { $canonical }
                    $code = $case.FirstCode
                } else {
                    $canonical = $case.Last
                    $shown = if ($sc) { $case.LastSc } else { $canonical }
                    $code = $case.LastCode
                }
                $id = $case.Raw + '-' + $sc + '-' + $key
                Query $case.Raw $sc
                Highlight $word
                Stroke $key
                $state = State
                Check ($id + '-single') ($state.Commit -ceq $shown -and -not $state.Raw) $state
                AddExpected $canonical $code

                Query ('wode' + $case.Raw) $sc
                Pick '我的'
                Highlight $word
                Stroke $key
                $state = State
                Check ($id + '-prefix') ($state.Commit -ceq ('我的' + $shown) -and -not $state.Raw) $state
                AddExpected ('我的' + $canonical) ('wo de ' + $code)

                $raw = 'wode' + $case.Raw + 'haoda'
                Query $raw $sc
                Pick '我的'
                Highlight $word
                Stroke $key
                $state = State
                Check ($id + '-pending') (-not $state.Commit -and $state.Raw -ceq $raw -and $state.Preedit.StartsWith('我的' + $shown)) $state
                Pick '好大'
                $state = State
                Check ($id + '-tail-commit') ($state.Commit -ceq ('我的' + $shown + '好大') -and -not $state.Raw) $state
                AddExpected ('我的' + $canonical + '好大') ('wo de ' + $code + ' hao da')

                Query $raw $sc
                Pick '我的'
                Highlight $word
                Stroke $key
                [RimeProbe]::RimeClearComposition($s)
                Check ($id + '-cancel') (-not [RimeProbe]::ReadCommit($s))
            }
        }
    }

    Query 'wodewifimimahaoda'
    Pick '我的'
    Highlight 'Wi-Fi 密碼'
    Stroke 0x5d
    Stroke 0xff08
    Highlight 'Wi-Fi 密碼'
    Check 'reopen-original-mixed-choice' $true
    [RimeProbe]::RimeClearComposition($s)

    # Abbreviated Chinese parts use the same existing mixed entry.
    Query 'wifimm'
    Highlight 'Wi-Fi 密碼'
    Stroke 0x5d
    $state = State
    Check 'abbreviation-pick' ($state.Commit -ceq '碼') $state
    AddExpected '碼' 'ma'

    Query 'WINDOWSBAN'
    Highlight 'WINDOWS 版'
    Stroke 0x5b
    $state = State
    Check 'uppercase-prefix-pick' ($state.Commit -ceq '版') $state
    AddExpected '版' 'ban'

    [RimeProbe]::RimeDestroySession($s) | Out-Null
    $s = [UIntPtr]::Zero
    $learning = Export 'luna_pinyin' 'chinese-picks.tsv'
    $actual = @{}
    foreach ($line in $learning) {
        $parts = $line -split "\t"
        if ([int]$parts[2] -gt 0) { $actual[$parts[0] + [char]9 + $parts[1]] = [int]$parts[2] }
    }
    foreach ($item in $expected.GetEnumerator()) {
        Check ('count-' + $item.Key) ($actual[$item.Key] -eq $item.Value) @($item.Value, $actual[$item.Key])
    }
    Check 'no-extra-chinese-learning' ($actual.Count -eq $expected.Count) $learning
    $mixed = Export 'pc_mixed' 'mixed-after-picks.tsv'
    Check 'picks-do-not-increment-whole-mixed-words' (@($mixed | Where-Object { [int](($_ -split "\t")[2]) -gt 0 }).Count -eq 0) $mixed

    $s = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($s, 'pc_research')) { throw 'Cannot reload pc_research' }
    foreach ($case in $cases) {
        Query $case.Raw
        Pick $case.Text
        $state = State
        Check ($case.Raw + '-whole-word') ($state.Commit -ceq $case.Text) $state
    }
    [RimeProbe]::RimeDestroySession($s) | Out-Null
    $s = [UIntPtr]::Zero
    $mixed = Export 'pc_mixed' 'mixed-after-whole-words.tsv'
    foreach ($case in $cases) {
        $entry = @($mixed | Where-Object { ($_ -split "\t")[0] -ceq $case.Text })
        Check ($case.Raw + '-whole-word-count-one') ($entry.Count -eq 1 -and [int](($entry[0] -split "\t")[2]) -eq 1) $entry
    }
} finally {
    if ($s -ne [UIntPtr]::Zero) { [RimeProbe]::RimeDestroySession($s) | Out-Null }
    [RimeProbe]::RimeFinalize()
    $rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'results.json') -Encoding UTF8
}
$failed = @($rows | Where-Object { -not $_.Passed })
[pscustomobject]@{Checks=$rows.Count;Failed=$failed} | ConvertTo-Json -Depth 6
if ($failed.Count) { exit 1 }