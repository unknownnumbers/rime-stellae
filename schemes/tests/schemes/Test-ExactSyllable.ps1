# SPDX-License-Identifier: GPL-3.0-only
# Public source files and fixed synthetic input, in a fresh isolated profile.
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$ProfileRoot,
 [Parameter(Mandatory=$true)][string]$SharedDirectory,
 [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$profile=[IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if(Test-Path -LiteralPath $output){throw 'Choose a fresh synthetic output directory.'}
if($output.StartsWith(($profile+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Keep synthetic output outside its source profile.'}
if(@(Get-ChildItem -LiteralPath $profile -Directory -Filter '*.userdb').Count){throw 'Use public source files without learning databases.'}
foreach($name in @('user.yaml','installation.yaml')){if(Test-Path -LiteralPath (Join-Path $profile $name)){throw 'Use public source files without installation state.'}}
$dll=[IO.Path]::GetFullPath($EngineDll)
$pe=[IO.File]::ReadAllBytes($dll)
if($pe.Length -lt 64 -or $pe[0] -ne 0x4d -or $pe[1] -ne 0x5a){throw 'EngineDll is not a PE image.'}
$peOffset=[BitConverter]::ToInt32($pe,0x3c)
if($peOffset -lt 0 -or $peOffset+6 -gt $pe.Length){throw 'Invalid PE image header.'}
$machine=[BitConverter]::ToUInt16($pe,$peOffset+4)
$expectedMachine=if([Environment]::Is64BitProcess){0x8664}else{0x14c}
if($machine -ne $expectedMachine){throw 'Run PowerShell with the same architecture as EngineDll.'}
$env:PATH=(Split-Path $dll -Parent)+';'+$env:PATH
$user=Join-Path $output 'user';$shared=Join-Path $output 'shared';$logs=Join-Path $output 'logs'
foreach($directory in @($output,$user,$shared,$logs)){[IO.Directory]::CreateDirectory($directory)|Out-Null}
foreach($entry in Get-ChildItem -LiteralPath $profile -Force){
 if($entry.Name -in @('build','.git')){continue}
 Copy-Item -LiteralPath $entry.FullName -Destination $user -Recurse
}
[IO.Directory]::CreateDirectory((Join-Path $user 'build'))|Out-Null
if(Test-Path -LiteralPath (Join-Path $user 'samples')){foreach($entry in Get-ChildItem -LiteralPath (Join-Path $user 'samples') -File){Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $user $entry.Name)}}
$standard=[IO.Path]::GetFullPath($SharedDirectory)
foreach($name in @('default.yaml','pinyin.yaml','grammar.yaml','key_bindings.yaml','punctuation.yaml','symbols.yaml','stroke.dict.yaml','stroke.schema.yaml')){$path=Join-Path $standard $name;if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination (Join-Path $shared $name)}}
if(Test-Path -LiteralPath (Join-Path $standard 'opencc')){Copy-Item -LiteralPath (Join-Path $standard 'opencc') -Destination (Join-Path $shared 'opencc') -Recurse}
[IO.File]::WriteAllText((Join-Path $user '.synthetic-profile.json'),'{"kind":"fixed-synthetic-exact-profile","format":1}',$utf8)
foreach($pair in @(@('observer.lua','cn_exact_test_observer.lua'),@('unit_runner.lua','cn_exact_unit_runner.lua'),@('processor_unit.lua','cn_exact_processor_unit.lua'))){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('exact_syllable/'+$pair[0])) -Destination (Join-Path $user ('lua/'+$pair[1]))}
[IO.File]::AppendAllText((Join-Path $user 'rime.lua'),"`ncn_exact_test_observer = require('cn_exact_test_observer')`ncn_exact_unit_runner = require('cn_exact_unit_runner')`n",$utf8)
[IO.File]::AppendAllText((Join-Path $user 'pc_research.custom.yaml'),"`n  'engine/processors/@before 0': lua_processor@cn_exact_test_observer`n  'engine/processors/@before 1': lua_processor@cn_exact_unit_runner`n",$utf8)
$realJapanese=Test-Path -LiteralPath (Join-Path $user 'jp_sela.schema.yaml')
$foreignSchema=if($realJapanese){'jp_sela'}else{'exact_foreign'}
$tabWordNavigation=$realJapanese
[IO.File]::AppendAllText((Join-Path $user 'default.custom.yaml'),"`n  'schema_list/=':`n    - schema: pc_research`n    - schema: $foreignSchema`n",$utf8)
if(-not $realJapanese){
 $foreign=@"
schema:
  schema_id: exact_foreign
  name: Foreign schema synthetic
  version: '1'
engine:
  processors: [lua_processor@cn_exact_processor, speller, punctuator, selector, navigator, express_editor]
  segmentors: [abc_segmentor, punct_segmentor, fallback_segmentor]
  translators: [punct_translator, table_translator]
speller:
  alphabet: abcdefghijklmnopqrstuvwxyz
translator:
  dictionary: exact_foreign
  enable_user_dict: false
  enable_sentence: false
punctuator:
  import_preset: default
"@
 [IO.File]::WriteAllText((Join-Path $user 'exact_foreign.schema.yaml'),$foreign+"`n",$utf8)
 $foreignWord=[string][char]0x304b+[char]0x306a
 [IO.File]::WriteAllText((Join-Path $user 'exact_foreign.dict.yaml'),"---`nname: exact_foreign`nversion: '1'`n...`n$foreignWord`tkana`t100`n",$utf8)
}
$sourceHashes=[ordered]@{}
foreach($name in @('pc_research.schema.yaml','pc_research.custom.yaml','lua/cn_match.lua','lua/cn_translator.lua','lua/cn_preedit_spacing.lua','lua/cn_exact_spelling.lua','lua/cn_exact_processor.lua')){$sourceHashes[$name]=(Get-FileHash -LiteralPath (Join-Path $profile $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
$registrationSource=if(Test-Path -LiteralPath (Join-Path $profile 'samples/rime.lua')){'samples/rime.lua'}else{'rime.lua'}
$sourceHashes[$registrationSource]=(Get-FileHash -LiteralPath (Join-Path $profile $registrationSource) -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs'),$utf8).Replace('__RIME_ENGINE_DLL__',$dll))
$traits = New-Object RimeProbe+Traits
$traits.data_size = [Runtime.InteropServices.Marshal]::SizeOf($traits) - 4
$traits.shared_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
$traits.user_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.prebuilt_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi((Join-Path $user 'build'))
$traits.staging_dir = $traits.prebuilt_data_dir
$traits.log_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($logs)
$traits.app_name = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.cn_exact_synthetic')
$traits.min_log_level = 2
$script:s = [UIntPtr]::Zero
$script:commits = [Collections.Generic.List[string]]::new()
$checks = [Collections.Generic.List[object]]::new()
$observations = [Collections.Generic.List[object]]::new()
$skippedChecks = [Collections.Generic.List[string]]::new()
$report = [ordered]@{
    Format='cn-exact-syllable-integration-v1'; Passed=$false; Completed=$false
    SyntheticOnly=$true; PersonalLearningCopied=$false; DailyServiceChanged=$false
    PhysicalKeyDownUp=$true; ProcessBits=([IntPtr]::Size*8)
    ProcessorUnitChecks=56; MatcherUnitChecks=16; ForeignSchemaCase=$foreignSchema
    SyntheticWordNavigation=$false; DefaultTabWordNavigation=$tabWordNavigation; SkippedChecks=@()
    SourceHashes=$sourceHashes; Error=$null; Checks=@(); Observations=@()
}

function Check([string]$id, [bool]$passed, $actual=$null) {
    $checks.Add([pscustomobject]@{Id=$id;Passed=$passed;Actual=$actual})
    if (-not $passed) {
        $observations.Add([pscustomobject]@{Id='failure-state';Input=[RimeProbe]::Input($script:s);Caret=[RimeProbe]::Caret($script:s);Snapshot=[RimeProbe]::Snapshot($script:s,60)})
        throw ('Exact syllable check failed: ' + $id)
    }
}
function Event([int]$key, [int]$mask=0) {
    [void][RimeProbe]::RimeProcessKey($script:s, $key, $mask)
    $text = [RimeProbe]::ReadCommit($script:s)
    if (-not [string]::IsNullOrEmpty($text)) { $script:commits.Add($text) }
}
function Stroke([int]$key, [int]$mask=0) {
    Event $key $mask
    Event $key ($mask -bor 0x40000000)
}
function Quote {
    Event 0xffe1
    Stroke 0x22 1
    Event 0xffe1 0x40000000
}
function Type-Raw([string]$raw) {
    foreach ($character in $raw.ToCharArray()) {
        if ($character -eq [char]0x22) { Quote }
        elseif ([char]::IsUpper($character)) {
            Event 0xffe1
            Stroke ([int]$character) 1
            Event 0xffe1 0x40000000
        } else { Stroke ([int]$character) }
    }
}
function Close-Session {
    if ($script:s -ne [UIntPtr]::Zero) {
        [RimeProbe]::RimeClearComposition($script:s)
        [void][RimeProbe]::RimeDestroySession($script:s)
        $script:s = [UIntPtr]::Zero
    }
}
function New-Session([string]$schema='pc_research', [bool]$english=$false) {
    Close-Session
    $script:s = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($script:s, $schema)) { throw 'Synthetic schema unavailable.' }
    [RimeProbe]::RimeSetOption($script:s, 'probe_options_ready', 1)
    [RimeProbe]::RimeSetOption($script:s, 'ascii_mode', 0)
    [RimeProbe]::RimeSetOption($script:s, 'research_english', [int]$english)
    [RimeProbe]::RimeSetOption($script:s, 'simplification', 0)
    [RimeProbe]::RimeSetOption($script:s, 'ascii_punct', 0)
    $script:commits.Clear()
}
function Query([string]$raw) {
    [RimeProbe]::RimeClearComposition($script:s)
    [void][RimeProbe]::ReadCommit($script:s)
    $script:commits.Clear()
    Type-Raw $raw
    Check ('query-raw-' + $raw) ([RimeProbe]::Input($script:s) -ceq $raw) ([RimeProbe]::Input($script:s))
    Check ('query-held-' + $raw) ($script:commits.Count -eq 0)
    return [RimeProbe]::Snapshot($script:s, 400)
}
function Highlight-Index([int]$index) {
    $menu = [RimeProbe]::Snapshot($script:s, 400)
    $moves = 0
    while ($menu.HighlightedIndex -ne $index) {
        if (++$moves -gt 450) { throw 'Cannot highlight the fixed synthetic candidate.' }
        Stroke $(if ($menu.HighlightedIndex -lt $index) { 0xff54 } else { 0xff52 })
        $menu = [RimeProbe]::Snapshot($script:s, 400)
    }
}
function Highlight([string]$text) {
    $menu = [RimeProbe]::Snapshot($script:s, 400)
    $index = [Array]::IndexOf([string[]]$menu.Candidates, $text)
    if ($index -lt 0) { throw ('Missing fixed synthetic candidate: ' + $text) }
    Highlight-Index $index
}
function Observe {
    Stroke 0xffc9
    $value = [RimeProbe]::Property($script:s, 'cn_exact_test_selection')
    if ([string]::IsNullOrEmpty($value)) { throw 'Register exact_test_observer in the synthetic main schema.' }
    $parts = $value -split "`t", 11
    if ($parts.Count -lt 10) { throw 'Incomplete synthetic candidate metadata.' }
    return [pscustomobject]@{
        Start=[int]$parts[0];End=[int]$parts[1];NativeStart=[int]$parts[2];NativeEnd=[int]$parts[3]
        Code=$parts[4];Type=$parts[5];Text=$parts[6];Spans=$parts[7];MatchingSize=$parts[8];DynamicType=$parts[9]
    }
}
function Pick([string]$text) { Highlight $text; Stroke 0x20 }
function Selected([string]$id, [string]$text, [int]$start, [int]$end, [string]$code) {
    Highlight $text
    $meta = Observe
    $observations.Add([pscustomobject]@{Id=$id;Metadata=$meta})
    Check ($id + '-raw-span') ($meta.Start -eq $start -and $meta.End -eq $end) @($meta.Start,$meta.End)
    Check ($id + '-canonical-code') ($meta.Code -ceq $code) $meta.Code
    return $meta
}
function Commit-Is([string]$id, [string]$expected) {
    Check $id (($script:commits -join '') -ceq $expected -and [RimeProbe]::Input($script:s) -ceq '') ($script:commits -join '')
}
function Seed([string]$raw, [string[]]$pieces, [string]$expected) {
    [void](Query $raw)
    foreach ($piece in $pieces) { Pick $piece }
    Commit-Is ('seed-' + $raw) $expected
}
function Inspect-Lock([string]$raw, [string]$firstCode, [int]$limit=30) {
    $menu = Query $raw
    $count = [Math]::Min($limit, $menu.Candidates.Count)
    $inspected = 0
    for ($index=0; $index -lt $count; $index++) {
        Highlight-Index $index
        $meta = Observe
        if ($meta.Code -and $meta.End -gt 4) {
            $inspected++
            Check ('locked-first-reading-' + $raw + '-' + $index) (($meta.Code -split ' ')[0] -ceq $firstCode) $meta.Code
        }
    }
    Check ('inspected-native-' + $raw) ($inspected -gt 0) $inspected
}

try {
    [RimeProbe]::RimeSetup([ref]$traits)
    [RimeProbe]::RimeInitialize([ref]$traits)
    [RimeProbe]::RimeDeployerInitialize([ref]$traits)
    Check 'native-workspace-deploy' ([RimeProbe]::RimeDeployWorkspace() -ne 0)
    Check 'compiled-main-schema' (Test-Path -LiteralPath (Join-Path $user 'build/pc_research.schema.yaml'))
    if ($realJapanese) { Check 'native-japanese-schema-deploy' ([RimeProbe]::RimeDeploySchema((Join-Path $user 'jp_sela.schema.yaml')) -ne 0) }
    else { Check 'native-foreign-schema-deploy' ([RimeProbe]::RimeDeploySchema((Join-Path $user 'exact_foreign.schema.yaml')) -ne 0) }
    [RimeProbe]::RimeFinalize()
    [RimeProbe]::RimeInitialize([ref]$traits)
    New-Session

    $unitSummary = [RimeProbe]::Property($script:s, 'cn_exact_unit_checks')
    Check 'pure-lua-unit-suites' ($unitSummary -ceq 'PASS processor=56 matcher=16') $unitSummary

    if (Test-Path -LiteralPath (Join-Path $user 'lua/official_translator.lua')) {
        $beforeThreshold = Query ('s' * 7)
        Type-Raw 's'
        Check 'eight-initials-keep-Chinese-candidates' (
            [RimeProbe]::Input($script:s) -ceq ('s' * 8) -and
            [RimeProbe]::Snapshot($script:s,6).Candidates.Count -gt 0 -and $script:commits.Count -eq 0)
        Stroke 0xff08
        $restored = [RimeProbe]::Snapshot($script:s,400)
        Check 'deleting-eighth-initial-restores-menu' (
            [RimeProbe]::Input($script:s) -ceq ('s' * 7) -and
            ($restored.Candidates -join "`n") -ceq ($beforeThreshold.Candidates -join "`n") -and
            $restored.Preedit -ceq $beforeThreshold.Preedit)
        $longMenu = Query ('s' * 24)
        Check 'long-initials-keep-Chinese-candidates' ($longMenu.Candidates.Count -gt 0)

        [void](Query 'uUh')
        Stroke 0xff0d 4
        Commit-Is 'on-demand-character-lookup' '一 (h)'
        [void](Query 'U4e2d')
        Stroke 0xff0d 4
        Commit-Is 'on-demand-Unicode-input' '中 (U+4E2D)'
        [void](Query 'cC(1+2.5)*log(2,8)')
        Stroke 0xff0d
        Commit-Is 'on-demand-calculator' '(1+2.5)*log(2,8)=10.5'
    }

    # All learning below comes from these fixed public examples.
    Seed 'xiaosiren' @('笑','死','人') '笑死人'
    Seed 'xiaoren' @('小','人') '小人'
    Seed "xi'an" @('西','安') '西安'
    Seed "ci'an" @('此','案') '此案'
    Seed "xi'ai" @('喜','愛') '喜愛'
    Seed "xi'ao" @('西','澳') '西澳'

    $menu = Query 'xiao'
    Check 'unmarked-xiao-keeps-correction-and-split' ($menu.Candidates -ccontains '喜愛' -and $menu.Candidates -ccontains '西澳')
    $menu = Query 'xiao"'
    Check 'single-mark-excludes-xi-ai-and-xi-ao' (-not ($menu.Candidates -ccontains '喜愛') -and -not ($menu.Candidates -ccontains '西澳'))
    [void](Selected 'single-mark' '笑' 0 5 'xiao')
    Check 'single-mark-visible' ([RimeProbe]::Snapshot($script:s,6).Preedit.Contains('"'))
    Stroke 0x20
    Commit-Is 'single-mark-commit-has-no-marker' '笑'

    Inspect-Lock 'xiao"' 'xiao'
    Inspect-Lock 'xiao"sr' 'xiao'

    [void](Query 'xiao"sr')
    [void](Selected 'mixed-prefix-phrase' '笑死人' 0 7 'xiao si ren')
    Stroke 0x20
    Commit-Is 'mixed-prefix-phrase-commit' '笑死人'
    [void](Query 'xiao"si"ren"')
    [void](Selected 'all-marked-learned-phrase' '笑死人' 0 12 'xiao si ren')
    Stroke 0x20
    Commit-Is 'all-marked-phrase-commit' '笑死人'

    foreach ($raw in @('xi''an"','xi"an"')) {
        $menu = Query $raw
        if ($raw -ceq 'xi"an"') {
            Check 'both-marked-exclude-ci-an' (-not ($menu.Candidates -ccontains '此案'))
        } else {
            Check 'apostrophe-keeps-unmarked-xi-correction' ($menu.Candidates -ccontains '此案')
        }
        [void](Selected ('apostrophe-compat-' + $raw) '西安' 0 $raw.Length 'xi an')
        Stroke 0x20
        Commit-Is ('apostrophe-commit-' + $raw) '西安'
    }

    [void](Query 'xiao"ren"')
    [void](Selected 'marked-two-syllables' '小人' 0 9 'xiao ren')
    Stroke 0x20
    Commit-Is 'marked-two-syllables-commit' '小人'

    [void](Query 'xiao"ren"ni"hao"')
    $menu = [RimeProbe]::Snapshot($script:s,40)
    $sentenceFound = $false
    $sentenceRows = [Collections.Generic.List[object]]::new()
    for ($index=0; $index -lt $menu.Candidates.Count; $index++) {
        Highlight-Index $index
        $meta = Observe
        $sentenceRows.Add([pscustomobject]@{Index=$index;DynamicType=$meta.DynamicType;Type=$meta.Type;Start=$meta.Start;End=$meta.End;Code=$meta.Code})
        if ($meta.DynamicType -ceq 'Sentence' -and $meta.End -eq 16) {
            Check 'native-sentence-respects-all-locks' ($meta.Code -ceq 'xiao ren ni hao') $meta.Code
            $sentenceFound = $true
            break
        }
    }
    $observations.Add([pscustomobject]@{Id='native-sentence-bounded-metadata';Candidates=$sentenceRows.ToArray()})
    Check 'native-sentence-path-observed' $sentenceFound $sentenceRows.ToArray()

    $menu = Query 'xioa"'
    Check 'invalid-locked-code-no-candidates' ($menu.Candidates.Count -eq 0) $menu.Candidates.Count
    Stroke 0xff08
    Check 'backspace-removes-marker' ([RimeProbe]::Input($script:s) -ceq 'xioa')
    Check 'backspace-unlocks-correction' ([RimeProbe]::Snapshot($script:s,400).Candidates -ccontains '笑')

    [void](Query 'xioa"')
    [RimeProbe]::SetCaret($script:s,4)
    Stroke 0xffff
    Check 'delete-removes-marker' ([RimeProbe]::Input($script:s) -ceq 'xioa')
    Check 'delete-unlocks-correction' ([RimeProbe]::Snapshot($script:s,400).Candidates -ccontains '笑')

    [void](Query 'xi''ao"')
    [RimeProbe]::SetCaret($script:s,2)
    Stroke 0xffff
    $menu = [RimeProbe]::Snapshot($script:s,400)
    Check 'delete-apostrophe-recomputes-whole-locked-block' ([RimeProbe]::Input($script:s) -ceq 'xiao"' -and [RimeProbe]::Caret($script:s) -eq 2 -and $menu.Candidates.Count -eq 0 -and $script:commits.Count -eq 0) $menu.Candidates.Count
    Stroke 0xff57
    $menu = [RimeProbe]::Snapshot($script:s,400)
    Check 'merged-locked-block-valid-at-end' ([RimeProbe]::Caret($script:s) -eq 5 -and $menu.Candidates -ccontains '笑')
    Check 'merged-locked-block-excludes-old-splits' (-not ($menu.Candidates -ccontains '西澳') -and -not ($menu.Candidates -ccontains '喜愛'))

    $menu = Query 'xiaoren"'
    Check 'whole-marked-block-cannot-resplit-into-two-syllables' ($menu.Candidates.Count -eq 0) $menu.Candidates.Count

    [void](Query 'xiao"')
    [RimeProbe]::SetCaret($script:s,3)
    Stroke 0xff08
    Check 'edit-inside-locked-block-recomputes' ([RimeProbe]::Input($script:s) -ceq 'xio"' -and [RimeProbe]::Snapshot($script:s,6).Candidates.Count -eq 0)
    Stroke 0x61
    Check 'edit-restores-raw-without-candidates-past-caret' ([RimeProbe]::Input($script:s) -ceq 'xiao"' -and [RimeProbe]::Caret($script:s) -eq 3 -and [RimeProbe]::Snapshot($script:s,6).Candidates.Count -eq 0)
    Stroke 0xff57
    Check 'edit-restores-valid-locked-block-at-end' ([RimeProbe]::Caret($script:s) -eq 5 -and [RimeProbe]::Snapshot($script:s,400).Candidates -ccontains '笑')

    [void](Query 'xin"g')
    [RimeProbe]::SetCaret($script:s,4)
    Check 'focus-xin-keeps-original-g-tail' ([RimeProbe]::Input($script:s) -ceq 'xin"g' -and [RimeProbe]::Caret($script:s) -eq 4 -and $script:commits.Count -eq 0)
    [void](Selected 'locked-xing-reading-keeps-next-g' '星' 0 4 'xing')
    [void](Selected 'locked-xin-keeps-next-g' '心' 0 4 'xin')
    Stroke 0x20
    Check 'xin-g-partial-selection-keeps-full-raw' ([RimeProbe]::Input($script:s) -ceq 'xin"g' -and $script:commits.Count -eq 0)
    Stroke 0xff0d
    Commit-Is 'xin-g-not-swallowed' '心g'
    $menu = Query 'xin"'
    Check 'xin-lock-keeps-project-normal-readings' ($menu.Candidates -ccontains '心' -and $menu.Candidates -ccontains '星')

    [void](Query 'xiaoren')
    Highlight '小人'
    Stroke 0xff09
    if ($tabWordNavigation) {
        Check 'ordinary-tab-does-not-insert-marker' ([RimeProbe]::Input($script:s) -ceq 'xiaoren' -and [RimeProbe]::Caret($script:s) -eq 4 -and $script:commits.Count -eq 0)
    } else {
        $skippedChecks.Add('ordinary-tab-word-navigation')
        Check 'ordinary-native-tab-keeps-raw-unmarked-input' ([RimeProbe]::Input($script:s) -ceq 'xiaoren' -and $script:commits.Count -eq 0)
    }
    [void](Query 'xiao"ren"')
    Highlight '小人'
    Stroke 0xff09
    if ($tabWordNavigation) {
        Check 'marked-tab-consumes-marker-position' ([RimeProbe]::Input($script:s) -ceq 'xiao"ren"' -and [RimeProbe]::Caret($script:s) -eq 5)
        Stroke 0xff09 1
        Check 'marked-shift-tab-returns-to-start' ([RimeProbe]::Caret($script:s) -eq 0)
    } else {
        $skippedChecks.Add('marked-tab-word-navigation')
        $skippedChecks.Add('marked-shift-tab-word-navigation')
        Check 'marked-native-tab-keeps-raw-locks' ([RimeProbe]::Input($script:s) -ceq 'xiao"ren"' -and $script:commits.Count -eq 0)
        [RimeProbe]::SetCaret($script:s,0)
    }
    Stroke 0xff53
    Stroke 0xff51
    Check 'marked-char-navigation-keeps-raw' ([RimeProbe]::Caret($script:s) -eq 0 -and [RimeProbe]::Input($script:s) -ceq 'xiao"ren"' -and $script:commits.Count -eq 0)

    [void](Query 'xiao"ren"')
    Highlight '小人'
    Event 0xffe3
    Stroke 0xff08 4
    Event 0xffe3 0x40000000
    $menu = [RimeProbe]::Snapshot($script:s,400)
    Check 'Control-Backspace-removes-one-marked-syllable' ([RimeProbe]::Input($script:s) -ceq 'xiao"' -and [RimeProbe]::Caret($script:s) -eq 5 -and $script:commits.Count -eq 0)
    Check 'Control-Backspace-retains-earlier-lock' ($menu.Candidates -ccontains '笑' -and -not ($menu.Candidates -ccontains '西澳') -and -not ($menu.Candidates -ccontains '喜愛'))

    [void](Query 'nixiao')
    [RimeProbe]::SetCaret($script:s,2)
    Pick '你'
    Check 'confirmed-prefix-before-marker-keeps-pending-raw' ([RimeProbe]::Input($script:s) -ceq 'nixiao' -and $script:commits.Count -eq 0)
    Type-Raw '"ren"'
    Check 'marker-appended-after-confirmed-prefix' ([RimeProbe]::Input($script:s) -ceq 'nixiao"ren"' -and $script:commits.Count -eq 0)
    [void](Selected 'nonzero-selected-prefix' '小人' 2 11 'xiao ren')
    Stroke 0x20
    Commit-Is 'nonzero-prefix-single-commit' '你小人'

    [void](Query 'xiao"ren"nihao')
    [RimeProbe]::SetCaret($script:s,9)
    [void](Selected 'middle-caret-marked-prefix' '小人' 0 9 'xiao ren')
    Stroke 0x20
    Check 'middle-caret-retains-raw-tail' ([RimeProbe]::Input($script:s) -ceq 'xiao"ren"nihao' -and $script:commits.Count -eq 0)
    [void](Selected 'middle-caret-tail-offset' '你好' 9 14 'ni hao')
    Stroke 0x20
    Commit-Is 'middle-caret-final-single-commit' '小人你好'

    [void](Query 'xiao"ren"hao')
    Highlight '小人'
    Stroke 0x5b
    Check 'marked-bracket-preserves-pending-raw-tail' ([RimeProbe]::Input($script:s) -ceq 'xiao"ren"hao' -and $script:commits.Count -eq 0 -and [RimeProbe]::Snapshot($script:s,6).Preedit.StartsWith('小'))
    [void](Selected 'marked-bracket-remainder-offset' '好' 9 12 'hao')
    Stroke 0x20
    Commit-Is 'marked-bracket-remainder-single-commit' '小好'

    [void](Query 'xiao"')
    Stroke 0xff0d
    Commit-Is 'raw-return-preserves-marker' 'xiao"'
    [void](Query 'ni''xiao"')
    Pick '你'
    Stroke 0xff0d
    Commit-Is 'selected-prefix-raw-return-preserves-marker' '你xiao"'

    [void](Query 'ni''xiao"ren"')
    Pick '你'
    Stroke 0xff1b
    Check 'escape-cancels-pending-suffix-only' ([RimeProbe]::Input($script:s) -ceq 'ni''' -and $script:commits.Count -eq 0)
    Stroke 0xff1b
    Check 'escape-clears-remaining-prefix' ([RimeProbe]::Input($script:s) -ceq '' -and $script:commits.Count -eq 0)

    [RimeProbe]::RimeClearComposition($script:s)
    $script:commits.Clear()
    Quote
    Check 'empty-Chinese-quote-is-punctuation' ([RimeProbe]::Input($script:s) -ceq '' -and ($script:commits -join '').Length -gt 0 -and [RimeProbe]::RimeGetOption($script:s,'research_english') -eq 0)

    [void](Query 'xiao"')
    Pick '笑'
    Quote
    Check 'quote-after-complete-composition-is-punctuation' ([RimeProbe]::Input($script:s) -ceq '' -and ($script:commits -join '').StartsWith('笑') -and ($script:commits -join '').Length -gt 1)

    New-Session 'pc_research' $true
    [void](Query 'hello')
    Quote
    Commit-Is 'English-quote-keeps-literal-behavior' 'hello"'
    Check 'English-quote-does-not-toggle-mode' ([RimeProbe]::RimeGetOption($script:s,'research_english') -eq 1)

    New-Session $foreignSchema
    [void](Query 'kana')
    Quote
    Check 'foreign-schema-quote-not-a-Chinese-marker' ([RimeProbe]::Input($script:s) -cne 'kana"' -and ($script:commits -join '').Contains('かな')) ($script:commits -join '')

    New-Session
    [void](Query 'xiao')
    Event 0xffe1
    Event 0x22 1
    Event 0xffe1 0x40000000
    Event 0x27 0x40000000
    Check 'quote-release-after-Shift-keeps-mode-and-marker' ([RimeProbe]::Input($script:s) -ceq 'xiao"' -and [RimeProbe]::RimeGetOption($script:s,'research_english') -eq 0 -and $script:commits.Count -eq 0)

    Close-Session
    [RimeProbe]::RimeFinalize()
    [RimeProbe]::RimeDeployerInitialize([ref]$traits)
    $export = Join-Path $output 'synthetic-learning.tsv'
    Check 'offline-synthetic-learning-export' ([RimeProbe]::ExportUserDict('luna_pinyin',$export) -gt 0)
    $learned = @(foreach ($line in [IO.File]::ReadAllLines($export,$utf8)) {
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split "`t"
            [pscustomobject]@{Text=$parts[0];Code=$parts[1].Trim();Count=[int]$parts[2]}
        }
    })
    $targetRows = @($learned | Where-Object { $_.Text -ceq '笑死人' })
    Check 'marked-selection-learns-canonical-phrase' ($targetRows.Count -eq 1 -and $targetRows[0].Code -ceq 'xiao si ren' -and $targetRows[0].Count -eq 3) @($targetRows | Select-Object Code,Count)
    $bracketRows = @($learned | Where-Object { $_.Text -ceq '小好' })
    Check 'marked-bracket-learns-only-selected-character-and-tail' ($bracketRows.Count -eq 1 -and $bracketRows[0].Code -ceq 'xiao hao' -and $bracketRows[0].Count -eq 1) @($bracketRows | Select-Object Code,Count)
    Check 'no-marker-in-any-learned-code' (@($learned | Where-Object { $_.Code.Contains('"') }).Count -eq 0)
    [RimeProbe]::RimeFinalize()
    [RimeProbe]::RimeInitialize([ref]$traits)
    New-Session
    $menu = Query 'xiao"sr'
    Check 'learned-phrase-persists-after-runtime-reopen' ($menu.Candidates -ccontains '笑死人')
    [void](Selected 'persisted-learned-phrase-span' '笑死人' 0 7 'xiao si ren')

    $report.Completed = $true
    $report.Passed = $true
} catch {
    $report.Error = $_.Exception.Message
} finally {
    Close-Session
    [RimeProbe]::RimeFinalize()
    $report.Checks = $checks.ToArray()
    $report.Observations = $observations.ToArray()
    $report.SkippedChecks = $skippedChecks.ToArray()
    [IO.File]::WriteAllText((Join-Path $output 'results.json'), ($report | ConvertTo-Json -Depth 9), $utf8)
}
[pscustomobject]@{Passed=$report.Passed;Completed=$report.Completed;Checks=$checks.Count;Failed=@($checks | Where-Object {-not $_.Passed}).Count;Error=$report.Error} | ConvertTo-Json -Depth 4
if (-not $report.Passed) { exit 1 }
