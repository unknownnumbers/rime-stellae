# SPDX-License-Identifier: GPL-3.0-only
# Uses only a freshly prepared profile and fixed synthetic input.
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$SharedData,
 [Parameter(Mandatory=$true)][string]$UserData,
 [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$user=[IO.Path]::GetFullPath($UserData)
if(-not(Test-Path -LiteralPath (Join-Path $user '.synthetic-profile.json'))){throw 'A fresh synthetic profile marker is required.'}
$dll=[IO.Path]::GetFullPath($EngineDll)
$shared=[IO.Path]::GetFullPath($SharedData)
$env:PATH=(Split-Path $dll)+';'+$env:PATH
$evidence=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $evidence){throw 'OutputDirectory must be new.'}
[IO.Directory]::CreateDirectory($evidence)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$source = [IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs'), $utf8)
$source = $source.Replace('__RIME_ENGINE_DLL__', $dll)
# Include the page size in each native snapshot, so the fixed page rule is tested.
$source = $source.Replace('int length=0,cursor=0,highlightedIndex=-1;', 'int length=0,cursor=0,highlightedIndex=-1,pageSize=0;')
$source = $source.Replace('length=c.composition.length; cursor=c.composition.cursor_pos;', 'length=c.composition.length; cursor=c.composition.cursor_pos; pageSize=c.menu.page_size;')
$source = $source.Replace('return new {Preedit=preedit,', 'return new {PageSize=pageSize,Preedit=preedit,')
Add-Type -TypeDefinition $source
$traits = [RimeProbe+Traits]::new()
$traits.data_size = [Runtime.InteropServices.Marshal]::SizeOf($traits) - 4
$traits.shared_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
$traits.user_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.log_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($evidence)
$traits.app_name = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.official_backup')
$traits.min_log_level = 1
$session = [UIntPtr]::Zero
$states = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$id, [bool]$passed, $detail = $null) {
    $checks.Add([pscustomobject]@{Id=$id; Passed=$passed; Detail=$detail})
}
function Capture([string]$id, [int]$limit = 150) {
    $state = [pscustomobject]@{Id=$id; Raw=[RimeProbe]::Input($session); Context=[RimeProbe]::Snapshot($session,$limit); Commit=[RimeProbe]::ReadCommit($session)}
    $states.Add($state)
    return $state
}
function Query([string]$raw, [int]$limit = 150) {
    [RimeProbe]::RimeClearComposition($session)
    [RimeProbe]::ReadCommit($session) | Out-Null
    foreach ($ch in $raw.ToCharArray()) { [RimeProbe]::RimeProcessKey($session,[int]$ch,0) | Out-Null }
    return Capture $raw $limit
}
function Pos($state, [string]$text) { return [Array]::IndexOf([string[]]$state.Context.Candidates,$text) }
function Flat([string]$text) { return $text.Replace(' ','').Replace("'",'').Replace('ü','v') }
$result = [ordered]@{Completed=$false; Engine=$null; ProcessBits=([IntPtr]::Size*8); Error=$null; Profile='fresh official-weasel'; Runtime='official-weasel-0.17.4'}
[RimeProbe]::RimeSetup([ref]$traits)
try {
    [RimeProbe]::RimeInitialize([ref]$traits)
    [RimeProbe]::RimeDeployerInitialize([ref]$traits)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $schemas = @(
        (Join-Path $shared 'stroke.schema.yaml')
        (Join-Path $user 'project_radical.schema.yaml')
        (Join-Path $user 'project_radical_parts.schema.yaml')
        (Join-Path $user 'english_full.schema.yaml')
        (Join-Path $user 'pc_research.schema.yaml')
    )
    foreach ($schema in $schemas) {
        if (-not [RimeProbe]::RimeDeploySchema($schema)) {
            throw "Schema deployment failed for $([IO.Path]::GetFileName($schema))."
        }
    }
    $result.DeployMilliseconds = $watch.ElapsedMilliseconds
    $session = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($session,'pc_research')) { throw 'Schema selection failed' }
    $result.Engine = [RimeProbe]::Version()
    Check 'official-engine-version' ($result.Engine -ceq '1.13.1') $result.Engine
    Check 'default-SC' ([RimeProbe]::RimeGetOption($session,'simplification') -eq 1)
    Check 'default-chinese-mode' ([RimeProbe]::RimeGetOption($session,'research_english') -eq 0)
    Check 'default-half-width' ([RimeProbe]::RimeGetOption($session,'full_shape') -eq 0)
    [RimeProbe]::RimeSetOption($session,'research_english',0)
    [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
    [RimeProbe]::RimeSetOption($session,'simplification',1)
    foreach ($case in @(@('nihao','你好'), @('ken','可能'), @('yochu','用处'), @('buuhao','不好'), @('hsun','顺'), @('zhunbzhong','准备中'), @('qijinanhao',''))) {
        $raw,$target = $case
        $limit = if ($raw -eq 'hsun') { 20000 } else { 1200 }
        $state = Query $raw $limit
        Check ('draft-'+$raw) ($state.Raw -ceq $raw -and -not $state.Commit) $state.Context.Preedit
        Check ('page-'+$raw) ($state.Context.PageSize -eq 6) $state.Context.PageSize
        if ($target -ne '') { Check ('candidate-'+$raw) ((Pos $state $target) -ge 0) ([string[]]$state.Context.Candidates | Select-Object -First 12) }
    }
    foreach ($case in @(@('qijinanhao','期间','anhao','安好'), @('womenzaikaolv','我们在','kaolv','考虑'), @('hsagnhaikaolv','上海','kaolv','考虑'))) {
        $raw,$prefix,$tail,$word = $case
        $limit = if ($raw -eq 'hsagnhaikaolv') { 20000 } else { 2000 }
        $state = Query $raw $limit
        $index = Pos $state $prefix
        Check ('partial-present-'+$raw) ($index -ge 0) $index
        if ($index -ge 0) {
            [RimeProbe]::SelectCandidate($session,$index) | Out-Null
            $state = Capture ('selected-'+$raw)
            Check ('partial-retains-'+$raw) ((Flat $state.Context.Preedit) -ceq ($prefix+$tail) -and -not $state.Commit) $state.Context.Preedit
            Check ('partial-tail-'+$raw) ((Pos $state $word) -ge 0) ([string[]]$state.Context.Candidates | Select-Object -First 12)
        }
    }
    foreach ($raw in @('pi','alpha','juhao','partial')) {
        $state = Query $raw 1000
        $forbidden = @($state.Context.Candidates | Where-Object { $_ -cmatch '^[\u0370-\u03ff\u2000-\u2bff\u3000-\u303f]+$' -or $_ -ceq '。' -or $_ -ceq '3.141592653589793' })
        Check ('removed-named-features-'+$raw) ($forbidden.Count -eq 0) $forbidden.Count
    }
    $state = Query 'uUmumuU'
    $index = Pos $state '林'
    Check 'component-lookup-candidate' ($index -ge 0) ([string[]]$state.Context.Candidates | Select-Object -First 12)
    if ($index -ge 0) {
        for ($move = 0; $move -lt $index; $move++) { [RimeProbe]::RimeProcessKey($session,0xff54,0) | Out-Null }
        [RimeProbe]::RimeProcessKey($session,0xff0d,4) | Out-Null
        $state = Capture 'component-lookup-reading-commit'
        Check 'component-lookup-reading-commit' ($state.Commit -ceq '林 (lin2)') $state.Commit
    } else {
        Check 'component-lookup-reading-commit' $false
    }
    # Repeated selection must train the canonical word through native Memory.
    $state = Query 'ken' 500
    $before = Pos $state '可能'
    for ($round = 1; $round -le 3; $round++) {
        $index = Pos $state '可能'
        if ($index -lt 0) { throw 'Learning target absent' }
        [RimeProbe]::SelectCandidate($session,$index) | Out-Null
        $selected = Capture ('learn-ken-'+$round)
        Check ('learning-commit-'+$round) ($selected.Commit -ceq '可能') $selected.Commit
        $state = Query 'ken' 500
    }
    Check 'learning-rank' ((Pos $state '可能') -le $before) @{Before=$before; After=(Pos $state '可能')}
    [RimeProbe]::RimeDestroySession($session) | Out-Null
    $session = [UIntPtr]::Zero
    $export = Join-Path $evidence 'luna_pinyin.userdb.txt'
    $result.LearningExportRows = [RimeProbe]::ExportUserDict('luna_pinyin',$export)
    Check 'learning-export' ((Test-Path -LiteralPath $export) -and [IO.File]::ReadAllText($export,$utf8).Contains('可能'))
    $session = [RimeProbe]::RimeCreateSession()
    if (-not [RimeProbe]::RimeSelectSchema($session,'pc_research')) { throw 'Schema reselection failed' }
    [RimeProbe]::RimeSetOption($session,'research_english',1)
    foreach ($case in @(@('hello','hello'), @('hellp','hello'), @('differential','differential'))) {
        $raw,$target = $case
        $state = Query $raw
        Check ('english-'+$raw) ((Pos $state $target) -ge 0) ([string[]]$state.Context.Candidates | Select-Object -First 6)
        Check ('english-page-'+$raw) ($state.Context.PageSize -eq 6) $state.Context.PageSize
    }
    $result.Completed = $true
} catch {
    $result.Error = $_.Exception.ToString()
} finally {
    if ($session -ne [UIntPtr]::Zero) { [RimeProbe]::RimeDestroySession($session) | Out-Null }
    [RimeProbe]::RimeFinalize()
    foreach ($ptr in @($traits.shared_data_dir,$traits.user_data_dir,$traits.log_dir,$traits.app_name)) { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
    $result.States = @($states | ForEach-Object {
        [pscustomobject]@{Id=$_.Id;Raw=$_.Raw;Commit=$_.Commit;Preedit=[string]$_.Context.Preedit;PageSize=[int]$_.Context.PageSize;Candidates=@($_.Context.Candidates | Select-Object -First 12)}
    })
    $result.Checks = $checks.ToArray()
    $result.Passed = @($checks | Where-Object Passed).Count
    $result.Failed = @($checks | Where-Object { -not $_.Passed }).Count
    [IO.File]::WriteAllText((Join-Path $evidence 'results.json'),($result | ConvertTo-Json -Depth 12),$utf8)
    [pscustomobject]@{Completed=$result.Completed; Engine=$result.Engine; Passed=$result.Passed; Failed=$result.Failed; Error=$result.Error; DeployMilliseconds=$result.DeployMilliseconds; Failures=@($checks | Where-Object { -not $_.Passed })} | ConvertTo-Json -Depth 6
}
if (-not $result.Completed -or $result.Failed) { exit 1 }
