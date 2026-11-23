# SPDX-License-Identifier: GPL-3.0-only
# Run in a separate PowerShell process against a fresh generated profile.
param(
  [Parameter(Mandatory)][ValidateSet('pc','official-weasel')][string]$Kind,
  [Parameter(Mandatory)][string]$GeneratedProfile,
  [Parameter(Mandatory)][string]$EnginePath,
  [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference='Stop'
function Write-Utf8([string]$path,[string]$text){
  [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
}
$user=(Resolve-Path -LiteralPath $GeneratedProfile).ProviderPath
$out=[IO.Path]::GetFullPath($OutputPath)
$dll=(Resolve-Path -LiteralPath $EnginePath).ProviderPath
function Contains-Path([string]$root,[string]$path){
  $boundary=$root.TrimEnd([IO.Path]::DirectorySeparatorChar)
  return $path.Equals($boundary,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($boundary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
foreach($privateRoot in @($env:APPDATA,$env:LOCALAPPDATA)|Where-Object {$_}){
  if((Contains-Path $privateRoot $user) -or (Contains-Path $privateRoot $out)){
    throw 'The native rebuild probe must not read or write an AppData profile.'
  }
}
if((Contains-Path $user $out) -or (Contains-Path $out $user)){
  throw 'The generated profile and report directory must be separate trees.'
}
foreach($required in @('pc_research.schema.yaml','pc_research.custom.yaml','jp_sela.schema.yaml','default.yaml','default.custom.yaml','rime.lua')){
  if(-not (Test-Path -LiteralPath (Join-Path $user $required) -PathType Leaf)){
    throw ('The fresh generated profile is missing '+$required)
  }
}
if((Split-Path $dll -Leaf) -ine 'rime.dll' -or -not (Test-Path -LiteralPath $dll -PathType Leaf)){
  throw 'EnginePath must identify the target rime.dll.'
}
if(Test-Path -LiteralPath (Join-Path $user 'build')){throw 'A fresh rebuild must start without a build directory.'}
if(@(Get-ChildItem -LiteralPath $user -Recurse -Force | Where-Object { $_.Name -match '\.userdb($|\.)|^(installation|user)\.yaml$|^sync$' }).Count){
  throw 'A fresh rebuild must not contain user metadata or learned data.'
}
if(@(Get-ChildItem -LiteralPath $user -Recurse -File | Where-Object { $_.Name -match '\.(prism|table|reverse)\.bin$' }).Count){
  throw 'A fresh rebuild must not contain prepared native dictionary binaries.'
}
if((Test-Path -LiteralPath $out) -and @(Get-ChildItem -LiteralPath $out -Force).Count){throw 'The report directory must be empty.'}
$emptyPrebuilt=Join-Path $out 'empty-prebuilt'
New-Item -ItemType Directory -Force -Path $out,$emptyPrebuilt|Out-Null
if(@(Get-ChildItem -LiteralPath $emptyPrebuilt -Force).Count){throw 'The explicitly empty prebuilt directory is not empty.'}
$program=Split-Path $dll -Parent
$env:PATH=$program+';'+$env:PATH
$sourceRows=@(Get-ChildItem -LiteralPath $user -Recurse -File | Sort-Object FullName | ForEach-Object {
  [pscustomobject]@{Path=$_.FullName.Substring($user.TrimEnd('\').Length+1).Replace('\','/');Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
})
Write-Utf8 (Join-Path $out 'sources.json') ($sourceRows|ConvertTo-Json -Depth 4)
$probe=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'RimeProbe.cs'))
$extra=@'
public static class RebuildProbe {
  public static int PageSize(UIntPtr session) {
    var c = new RimeProbe.Context { data_size = Marshal.SizeOf(typeof(RimeProbe.Context))-4 };
    if (RimeProbe.RimeGetContext(session, ref c)==0) return -1;
    int value=c.menu.page_size;
    RimeProbe.RimeFreeContext(ref c);
    return value;
  }
}
'@
Add-Type -TypeDefinition ($probe.Replace('__RIME_ENGINE_DLL__',$dll)+"`n"+$extra)
$traits=[RimeProbe+Traits]::new()
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
$traits.min_log_level=1
# All resource lookups use this source-generated profile. Installed data and
# existing native indexes are deliberately absent from the traits paths.
$values=@{shared_data_dir=$user;user_data_dir=$user;log_dir=$out;prebuilt_data_dir=$emptyPrebuilt;app_name='rime.synthetic_maintained_rebuild'}
foreach($item in $values.GetEnumerator()){$traits.($item.Key)=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($item.Value)}
$checks=[Collections.Generic.List[object]]::new()
$session=[UIntPtr]::Zero
$initialized=$false
$report=[ordered]@{Kind=$Kind;Passed=$false;SourcePath=$user;EngineSha256=(Get-FileHash -LiteralPath $dll).Hash.ToLowerInvariant();SourceFiles=$sourceRows.Count;InitialBuildAbsent=$true;InitialUserDataAbsent=$true;PrebuiltEmpty=$true;SharedDataIsGeneratedSource=$true;DeployPassed=$false;Checks=$checks}
function Record([string]$name,[bool]$passed,$evidence){
  $checks.Add([pscustomobject]@{Case=$name;Passed=$passed;Evidence=$evidence})
}
function Press([int]$code,[int]$mask=0){
  $down=[RimeProbe]::RimeProcessKey($script:session,$code,$mask)
  $up=[RimeProbe]::RimeProcessKey($script:session,$code,($mask -bor 0x40000000))
  return [pscustomobject]@{Down=$down;Up=$up}
}
function Type-Text([string]$raw){
  foreach($char in $raw.ToCharArray()){
    [void](Press ([int]$char) $(if([char]::IsUpper($char) -or $char -ceq '"'){1}else{0}))
  }
}
function Compose([string]$raw){
  [RimeProbe]::RimeClearComposition($script:session)
  [void][RimeProbe]::ReadCommit($script:session)
  Type-Text $raw
}
function Snapshot {
  $s=[RimeProbe]::Snapshot($script:session,1000)
  [pscustomobject]@{Raw=[RimeProbe]::Input($session);Caret=[RimeProbe]::Caret($session);Preedit=$s.Preedit;Candidates=@($s.Candidates);EarlyCommit=[RimeProbe]::ReadCommit($session)}
}
function Select-Text([string]$text){
  $choices=@([RimeProbe]::Snapshot($script:session,1500).Candidates)
  $index=[Array]::IndexOf($choices,$text)
  if($index -lt 0 -or -not [RimeProbe]::SelectCandidate($session,$index)){throw "Missing synthetic selection: $text"}
}
function Current-Schema {
  $bytes=[byte[]]::new(512)
  [void][RimeProbe]::RimeGetCurrentSchema($session,$bytes,[UIntPtr]::new([uint32]512))
  [Text.Encoding]::UTF8.GetString($bytes).Trim([char]0)
}
function Open-PC {
  $script:session=[RimeProbe]::RimeCreateSession()
  if(-not $session -or -not [RimeProbe]::RimeSelectSchema($session,'pc_research')){throw 'The rebuilt PC schema could not open.'}
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  [RimeProbe]::RimeSetOption($session,'simplification',1)
}
function Candidate-Case([string]$raw,[string[]]$want,[string[]]$exclude=@()){
  Compose $raw
  $state=Snapshot
  $missing=@($want|Where-Object {$_ -cnotin $state.Candidates})
  $forbidden=@($exclude|Where-Object {$_ -cin $state.Candidates})
  Record ('candidate '+$raw) ($state.Raw -ceq $raw -and -not $state.EarlyCommit -and -not $missing.Count -and -not $forbidden.Count) ([pscustomobject]@{Raw=$state.Raw;Required=$want;Missing=$missing;Forbidden=$forbidden;Top=@($state.Candidates|Select-Object -First 6)})
}
function Learn-Symbol([string]$glyph,[int]$times){
  for($i=0;$i -lt $times;$i++){
    Compose 'in';Select-Text $glyph
    $commit=[RimeProbe]::ReadCommit($session)
    Record ('symbol commit '+$glyph+' '+$i) ($commit -ceq $glyph) $commit
  }
}
function Symbol-Rank([string]$label,[string]$first,[string]$second){
  Compose 'in';$state=Snapshot
  $a=[Array]::IndexOf(@($state.Candidates),$first)
  $b=[Array]::IndexOf(@($state.Candidates),$second)
  Record $label ($a -ge 0 -and $b -ge 0 -and $a -lt $b) ([pscustomobject]@{Order=@($state.Candidates|Where-Object {$_ -cin @('∈','∞','∫')});FirstIndex=$a;SecondIndex=$b})
}
function Export-Poem([string]$label){
  [RimeProbe]::RimeClearComposition($session)
  [void][RimeProbe]::RimeDestroySession($session)
  $script:session=[UIntPtr]::Zero
  $file=Join-Path $out ($label+'.tsv')
  if([RimeProbe]::ExportUserDict('luna_pinyin',$file) -lt 0){throw 'Synthetic native learning export failed.'}
  $rows=@(foreach($line in [IO.File]::ReadLines($file)){
    if($line -and -not $line.StartsWith('#')){
      $pieces=$line.Split("`t")
      if($pieces[0] -ceq '今朝有酒今朝醉'){
        [pscustomobject]@{Text=$pieces[0];Code=$pieces[1];Count=[int]$pieces[2]}
      }
    }
  })
  Open-PC
  return $rows
}
try{
  [RimeProbe]::RimeSetup([ref]$traits)
  [RimeProbe]::RimeInitialize([ref]$traits);$initialized=$true
  $report.EngineVersion=[RimeProbe]::Version()
  [RimeProbe]::RimeDeployerInitialize([ref]$traits)
  Write-Host ('Starting fresh '+$Kind+' native workspace deployment from source.')
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $report.DeployPassed=[bool][RimeProbe]::RimeDeployWorkspace()
  $timer.Stop();$report.DeployMs=$timer.ElapsedMilliseconds
  Write-Host ('Fresh native deployment completed in '+$report.DeployMs+' ms. Running behavioral checks.')
  [RimeProbe]::RimeFinalize();$initialized=$false
  if(-not $report.DeployPassed){throw 'Fresh native workspace deployment failed. Inspect its saved logs.'}
  $build=Join-Path $user 'build'
  $binaryRows=@(Get-ChildItem -LiteralPath $build -File -Filter '*.bin'|Sort-Object Name|ForEach-Object{
    [pscustomobject]@{Path='build/'+$_.Name;Bytes=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
  })
  Write-Utf8 (Join-Path $out 'rebuilt-binaries.json') ($binaryRows|ConvertTo-Json -Depth 4)
  $report.RebuiltBinaryCount=$binaryRows.Count
  Record 'native dictionaries built from empty workspace' ($binaryRows.Count -gt 0) $binaryRows.Count
  $compiled=[IO.File]::ReadAllText((Join-Path $build 'pc_research.schema.yaml'))
  $defaultCompiled=[IO.File]::ReadAllText((Join-Path $build 'default.yaml'))
  $jpCompiled=[IO.File]::ReadAllText((Join-Path $build 'jp_sela.schema.yaml'))
  $bindingCount=[regex]::Matches($compiled,'(?m)^    - .*accept: "Control\+space".*$').Count
  $expectedBinding=if($Kind -eq 'pc'){1}else{0}
  Record 'rebuilt Ctrl+Space policy' ($bindingCount -eq $expectedBinding) ([pscustomobject]@{Bindings=$bindingCount;Expected=$expectedBinding})
  foreach($entry in @(@('default',$defaultCompiled),@('pc',$compiled),@('jp',$jpCompiled))){
    $caps=[regex]::Match($entry[1],'(?m)^    Caps_Lock: (\S+)').Groups[1].Value
    Record ('rebuilt Caps Lock '+$entry[0]) ($caps -ceq 'noop') $caps
  }
  [RimeProbe]::RimeInitialize([ref]$traits);$initialized=$true
  Open-PC
  [RimeProbe]::RimeClearComposition($session)
  $reply=Press 0x20 4
  $ascii=[RimeProbe]::RimeGetOption($session,'ascii_mode')
  Record 'Ctrl+Space native engine action' ($ascii -eq $(if($Kind -eq 'pc'){1}else{0})) ([pscustomobject]@{Ascii=$ascii;Reply=$reply;Scope=if($Kind -eq 'pc'){'Frontend clears composition after the schema toggle'}else{'Official frontend owns the key; engine is expected not to toggle'}})
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  $modeStates=@(foreach($key in @(0xffe1,0xffe2,0xffe2,0xffe1)){
    [void](Press $key)
    [pscustomobject]@{Key=$key;English=[RimeProbe]::RimeGetOption($session,'research_english');Ascii=[RimeProbe]::RimeGetOption($session,'ascii_mode')}
  })
  Record 'both Shift taps use En including quick repeated taps' ((@($modeStates.English)-join ',') -ceq '1,0,1,0' -and @($modeStates|Where-Object Ascii -ne 0).Count -eq 0) $modeStates
  [RimeProbe]::RimeSetOption($session,'research_english',1)
  [RimeProbe]::RimeSetOption($session,'ascii_mode',1)
  [void](Press 0xffe1);[void](Press 0xffe2)
  Record 'red A ignores both Shift taps and remembers En' ([RimeProbe]::RimeGetOption($session,'ascii_mode') -eq 1 -and [RimeProbe]::RimeGetOption($session,'research_english') -eq 1) @([RimeProbe]::RimeGetOption($session,'ascii_mode'),[RimeProbe]::RimeGetOption($session,'research_english'))
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  foreach($route in @(@('pc_research',0x65,'jp_sela'),@('jp_sela',0x65,'pc_research'),@('jp_sela',0x72,'pc_research'))){
    [void][RimeProbe]::RimeSelectSchema($session,$route[0]);[RimeProbe]::RimeSetOption($session,'ascii_mode',0)
    [void](Press $route[1] 4)
    $actual=Current-Schema
    Record ('hotkey '+$route[0]+' Ctrl+'+[char]$route[1]) ($actual -ceq $route[2]) $actual
  }
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0);[RimeProbe]::RimeSetOption($session,'research_english',0);[RimeProbe]::RimeSetOption($session,'simplification',1)
  foreach($case in @(
    @('nihao',@('你好'),@()),@('haode''ba"',@('好的吧'),@()),@('wenti"s',@('问题是'),@()),
    @('xiao;sr',@('笑死人'),@()),@('xian;ren',@('先人'),@('西安人')),@('xian"r',@('先人','西安人'),@()),
    @('jin;zhaoyoujiujin',@('今朝有酒今朝醉'),@()),@('jinzhaoyoujiujin"',@(),@('今朝有酒今朝醉')),
    @('in',@('∈','∞','∫'),@()),@('int',@('∫'),@()),@('alpha',@('α'),@()),
    @('U68B6',@('梶'),@()),@('uUmuwei',@('梶'),@()),@('cC1+1',@('2'),@())
  )){Candidate-Case $case[0] $case[1] $case[2]}
  Compose 'nihao';$chinesePage=[RebuildProbe]::PageSize($session)
  [RimeProbe]::RimeSetOption($session,'research_english',1)
  Candidate-Case 'hepl' @('help')
  $englishPage=[RebuildProbe]::PageSize($session)
  Record 'profile page-size capability' ($chinesePage -eq $(if($Kind -eq 'pc'){5}else{6}) -and $englishPage -eq 6) ([pscustomobject]@{Chinese=$chinesePage;English=$englishPage})
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  Compose 'haodeHello';[RimeProbe]::SetCaret($session,5);Select-Text '好的';[void](Press 0xff08)
  $state=Snapshot
  Record 'uppercase pending deletion preserves selection' ($state.Raw -ceq 'haodeHell' -and $state.Preedit -ceq '好的Hell' -and -not $state.EarlyCommit) $state
  Compose 'haodeba';Select-Text '好的';[void](Press 0xff09)
  $state=Snapshot
  Record 'selected prefix Tab boundary' ($state.Caret -eq 5 -and $state.Preedit -ceq '好的ba' -and -not $state.EarlyCommit) $state
  [void][RimeProbe]::RimeSelectSchema($session,'jp_sela');[RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  foreach($case in @(@('kana',@('かな')),@('KANA',@('カナ')),@('qnihon',@('日本')),@('vwo',@('我')),@('vwoni',@('我に')))){
    Candidate-Case $case[0] $case[1]
  }
  [void][RimeProbe]::RimeSelectSchema($session,'pc_research')
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1);[RimeProbe]::RimeSetOption($session,'ascii_mode',0);[RimeProbe]::RimeSetOption($session,'research_english',0);[RimeProbe]::RimeSetOption($session,'simplification',1)
  $before=@(Export-Poem 'learning-before');$old=@($before|Measure-Object Count -Sum).Sum;if(-not $old){$old=0}
  foreach($code in 'jin;zhaoyoujiujin','jinzhaoyoujiujinzhaozui'){
    Compose $code;Select-Text '今朝有酒今朝醉';$commit=[RimeProbe]::ReadCommit($session)
    $entries=@(Export-Poem ('learning-'+$checks.Count));$count=@($entries|Measure-Object Count -Sum).Sum
    Record ('canonical learning '+$code) ($commit -ceq '今朝有酒今朝醉' -and $entries.Count -eq 1 -and $entries[0].Code -ceq 'jin zhao you jiu jin zhao zui' -and $count -eq $old+1) $entries
    $old=$count
  }
  Symbol-Rank 'unlearned exact symbol precedes prefix' '∈' '∞'
  Learn-Symbol '∞' 1
  Symbol-Rank 'learned prefix can exceed unlearned exact symbol' '∞' '∈'
  Learn-Symbol '∈' 1
  Learn-Symbol '∫' 12
  Symbol-Rank 'learned prefix can exceed learned exact symbol' '∫' '∈'
  Symbol-Rank 'native learning reorders symbol prefixes' '∫' '∞'
  $sourceChanged=@($sourceRows|Where-Object { $_.Sha256 -cne (Get-FileHash -LiteralPath (Join-Path $user $_.Path)).Hash.ToLowerInvariant() })
  Record 'source files unchanged by native deployment and tests' ($sourceChanged.Count -eq 0) @($sourceChanged.Path)
  $luaErrors=@(Get-ChildItem -LiteralPath $out -File -Filter '*.log*'|Select-String -Pattern 'stack traceback|Lua(?:Processor|Translator|Segmentor|Filter)::.*(?:error|failed)' -CaseSensitive:$false|Select-Object -First 12|ForEach-Object Line)
  Record 'no native Lua error traces' ($luaErrors.Count -eq 0) $luaErrors
  $report.Passed=$report.DeployPassed -and @($checks|Where-Object {-not $_.Passed}).Count -eq 0
}catch{
  $report.Fatal=$_.Exception.Message
  throw
}finally{
  if($session -ne [UIntPtr]::Zero){[void][RimeProbe]::RimeDestroySession($session)}
  if($initialized){[RimeProbe]::RimeFinalize()}
  foreach($name in $values.Keys){[Runtime.InteropServices.Marshal]::FreeHGlobal($traits.$name)}
  Write-Utf8 (Join-Path $out 'proof.json') ($report|ConvertTo-Json -Depth 10)
  [pscustomobject]@{Kind=$Kind;Passed=$report.Passed;DeployPassed=$report.DeployPassed;DeployMs=$report.DeployMs;RebuiltBinaries=$report.RebuiltBinaryCount;Checks=$checks.Count;Failed=@($checks|Where-Object{-not $_.Passed}|ForEach-Object Case);Fatal=$report.Fatal}|ConvertTo-Json -Depth 5
}
if(-not $report.Passed){throw 'The source-built profile did not pass native verification.'}
