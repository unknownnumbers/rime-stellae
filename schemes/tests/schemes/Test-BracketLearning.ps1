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
$export = Join-Path $dir 'learning.tsv'
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
function Learning {
    [RimeProbe]::ExportUserDict('luna_pinyin', $export) | Out-Null
    return @(Get-Content -LiteralPath $export -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
}
function Count([string]$code, [string]$word) {
    foreach ($line in (Learning)) {
        $parts = $line -split "\t"
        if ($parts[0] -ceq $word -and $parts[1] -ceq $code) { return [int]$parts[2] }
    }
    return 0
}
function Check([string]$name, [bool]$passed, $detail=$null) {
    $rows.Add([pscustomobject]@{Check=$name;Passed=$passed;Detail=$detail})
}

[RimeProbe]::RimeSetup([ref]$traits)
[RimeProbe]::RimeInitialize([ref]$traits)
[RimeProbe]::RimeDeployerInitialize([ref]$traits)
try {
    $s = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($s, 'pc_research')) { throw 'Cannot load pc_research' }
    [RimeProbe]::RimeSetOption($s, 'probe_options_ready', 1)
    foreach ($sc in $false, $true) {
        $label = if ($sc) { 'SC' } else { 'TC' }
        $word = if ($sc) { '侠客' } else { '俠客' }
        $character = if ($sc) { '侠' } else { '俠' }
        Query 'xiake' $sc
        Highlight $word
        Write-Output "Checking $label standalone bracket"
        Stroke 0x5b
        $state = State
        Check "$label-single-output" ($state.Commit -ceq $character -and -not $state.Raw) $state
    }
    foreach ($sc in $false, $true) {
        $label = if ($sc) { 'SC' } else { 'TC' }
        $first = if ($sc) { '黄' } else { '黃' }
        $word = if ($sc) { '侠客' } else { '俠客' }
        $output = if ($sc) { '黄侠' } else { '黃俠' }
        Query 'huangxiake' $sc
        Pick $first
        Highlight $word
        Stroke 0x5b
        $state = State
        Check "$label-prefix-output" ($state.Commit -ceq $output -and -not $state.Raw) $state
    }
    Query 'huangxiakehaoda'
    Pick '黃'
    Highlight '俠客'
    Stroke 0x5b
    $state = State
    Check 'tail-stays-pending' (-not $state.Commit -and $state.Preedit.StartsWith('黃俠') -and $state.Raw -ceq 'huangxiakehaoda') $state
    Pick '好大'
    $state = State
    Check 'tail-final-output' ($state.Commit -ceq '黃俠好大' -and -not $state.Raw) $state

    Query 'huangxiakehaoda'
    Pick '黃'
    Highlight '俠客'
    Stroke 0x5b
    [RimeProbe]::RimeClearComposition($s)
    Check 'cancel-no-commit' (-not [RimeProbe]::ReadCommit($s))

    Query 'xiake'
    Highlight '俠客'
    Stroke 0x5d
    $state = State
    Check 'last-character-output' ($state.Commit -ceq '客') $state

    Query 'huangxiakehaoda'
    Pick '黃'
    Highlight '俠客'
    Stroke 0x5b
    Stroke 0xff08
    Highlight '俠客'
    Check 'reopen-retains-whole-word' $true
    Stroke 0x20
    Pick '好大'
    $state = State
    Check 'reopen-normal-output' ($state.Commit -ceq '黃俠客好大') $state

    Query 'huangxia'
    $list = [RimeProbe]::Snapshot($s, 12)
    Check 'learned-compound-recalled' ($list.Candidates -contains '黃俠') $list.Candidates
    Query 'xia'
    $list = [RimeProbe]::Snapshot($s, 12)
    Check 'learned-single-recalled' ($list.Candidates -contains '俠') $list.Candidates
    [RimeProbe]::RimeClearComposition($s)
    [RimeProbe]::RimeDestroySession($s) | Out-Null
    $s = [UIntPtr]::Zero
    Check 'single-learns-once-per-commit' ((Count 'xia' '俠') -eq 2) (Count 'xia' '俠')
    Check 'prefix-learns-once-per-commit' ((Count 'huang xia' '黃俠') -eq 2) (Count 'huang xia' '黃俠')
    Check 'tail-final-learns-once' ((Count 'huang xia hao da' '黃俠好大') -eq 1) (Count 'huang xia hao da' '黃俠好大')
    Check 'last-character-learns-once' ((Count 'ke' '客') -eq 1) (Count 'ke' '客')
    Check 'reopen-learns-normal-phrase' ((Count 'huang xia ke hao da' '黃俠客好大') -eq 1) (Count 'huang xia ke hao da' '黃俠客好大')
    $wrong = @((Learning) | Where-Object {
        $parts = $_ -split "\t"
        ($parts[0] -ceq '俠' -and $parts[1] -ceq 'xia ke') -or
        ($parts[0] -ceq '黃俠' -and $parts[1] -ceq 'huang xia ke')
    })
    Check 'no-discarded-syllable-learning' ($wrong.Count -eq 0) $wrong
    if (-not $SkipJapanese) {
        $s = [RimeProbe]::RimeCreateSession()
        if (-not [RimeProbe]::RimeSelectSchema($s, 'jp_sela')) { throw 'Cannot load jp_sela' }
        foreach ($case in @(
            @{Raw='qQtaberunabebutahana';First='食べる';Word='鍋蓋';Key=0x5b;Text='食べる鍋';Last='花'},
            @{Raw='qQsakurakoujihana';First='桜';Word='小路';Key=0x5d;Text='桜路';Last='花'},
            @{Raw='vVyinhuaxueV';First='桜';Word='花';Key=0x5d;Text='桜花';Last='雪'},
            @{Raw='vVyinhuaxuev';First='桜';Word='花';Key=0x7d;Mask=1;Text='桜花 (か)';Last='雪'}
        )) {
            Query $case.Raw
            Pick $case.First
            Highlight $case.Word
            Stroke $case.Key ([int]$case.Mask)
            $state = State
            Check ('JP-pending-' + $case.Raw) (-not $state.Commit -and $state.Preedit.StartsWith($case.Text)) $state
            Pick $case.Last
            $state = State
            Check ('JP-final-' + $case.Raw) ($state.Commit -ceq ($case.Text + $case.Last)) $state
        }
        [RimeProbe]::RimeDestroySession($s) | Out-Null
        $s = [UIntPtr]::Zero
        $jpExport = Join-Path $dir 'jp-learning.tsv'
        [RimeProbe]::ExportUserDict('jp_family', $jpExport) | Out-Null
        $jpRows = Get-Content -LiteralPath $jpExport -Encoding UTF8
        Check 'JP-picked-word-learning' ($jpRows -contains ('鍋','鍋','1' -join [char]9) -and $jpRows -contains ('路','路','1' -join [char]9)) $jpRows
        Check 'JP-reading-pick-learning' ($jpRows -contains ('花','花','4' -join [char]9)) $jpRows
    }
} finally {
    if ($s -ne [UIntPtr]::Zero) { [RimeProbe]::RimeDestroySession($s) | Out-Null }
    [RimeProbe]::RimeFinalize()
    $rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'results.json') -Encoding UTF8
}
$failed = @($rows | Where-Object { -not $_.Passed })
[pscustomobject]@{Checks=$rows.Count;Failed=$failed} | ConvertTo-Json -Depth 6
if ($failed.Count) { exit 1 }
