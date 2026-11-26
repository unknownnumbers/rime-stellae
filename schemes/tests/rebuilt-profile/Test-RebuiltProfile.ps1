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
foreach($required in @('cn_stellae.schema.yaml','cn_stellae.custom.yaml','jp_stellae.schema.yaml','default.yaml','default.custom.yaml','rime.lua')){
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
function Press([int]$code,[int]$mask=0,[int]$releaseMask=$mask){
  $down=[RimeProbe]::RimeProcessKey($script:session,$code,$mask)
  $up=[RimeProbe]::RimeProcessKey($script:session,$code,($releaseMask -bor 0x40000000))
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
  if(-not $session -or -not [RimeProbe]::RimeSelectSchema($session,'cn_stellae')){throw 'The rebuilt PC schema could not open.'}
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  [RimeProbe]::RimeSetOption($session,'simplification',1)
}
function Read-SyntheticLearning([string]$label){
  [void][RimeProbe]::RimeDestroySession($session)
  $script:session=[UIntPtr]::Zero
  $file=Join-Path $out ('delete-'+$label+'.tsv')
  if([RimeProbe]::ExportUserDict('cn_stellae',$file) -lt 0){throw 'Could not export synthetic deletion records.'}
  Open-PC
  $counts=@{}
  foreach($line in [IO.File]::ReadLines($file)){
    if($line -and -not $line.StartsWith('#')){
      $row=$line.Split("`t")
      $counts[$row[0]]+=[int]$row[2]
    }
  }
  return $counts
}
function Test-CandidateDeletion {
  # Each shortcut gets its own word, so a previous deletion cannot affect it.
  $fixtures=@(@('gongren','工人',4),@('renmin','人民',6),@('anquan','安全',1),@('shanshui','山水',3))
  foreach($f in $fixtures){
    Compose $f[0];Select-Text $f[1]
    if([RimeProbe]::ReadCommit($session) -cne $f[1]){throw 'Could not seed the deletion fixture.'}
  }
  $before=Read-SyntheticLearning 'before'
  $errors=@(foreach($f in $fixtures){
    Compose $f[0]
    if($f[2] -band 2){[void](Press 0xffe5 0 2)}
    $top=[RimeProbe]::Snapshot($session,1).Candidates[0]
    $key=Press 0xffff $f[2]
    if($top -cne $f[1] -or -not $key.Down -or $key.Up -or [RimeProbe]::ReadCommit($session)){
      [pscustomobject]@{Word=$f[1];Top=$top;Delete=$key}
    }
  })
  [RimeProbe]::RimeClearComposition($session)
  $after=Read-SyntheticLearning 'after'
  $errors
  foreach($f in $fixtures){
    $word=$f[1]
    if($before[$word] -le 0 -or $after[$word] -gt 0){
      [pscustomobject]@{Word=$word;Before=$before[$word];After=$after[$word]}
    }
  }
}
function Test-CapsDraft([string]$mode,[string]$text){
  $keys=[ordered]@{Backspace=0xff08;Delete=0xffff;Left=0xff51;Right=0xff53;Home=0xff50;End=0xff57;Space=32;Return=0xff0d;Escape=0xff1b}
  $modifiers=[ordered]@{CtrlReturn=4;ShiftReturn=1;CtrlShiftReturn=5;CtrlDelete=4}
  if($mode -eq 'Chinese'){$modifiers.ShiftDelete=1}
  foreach($name in $modifiers.Keys){$keys[$name]=if($name.EndsWith('Delete')){0xffff}else{0xff0d}}
  $mismatches=@(foreach($entry in $keys.GetEnumerator()){
    $modifier=[int]$modifiers[$entry.Key]
    $lowercaseSample=$modifier -and $entry.Value -eq 0xff0d -and $mode -ne 'En'
    $sample=if(-not $lowercaseSample){$text}elseif($mode -eq 'Chinese'){'nihao'}else{'vwo'}
    $states=@(foreach($mask in 0,2){
      [RimeProbe]::RimeClearComposition($session)
      [void][RimeProbe]::ReadCommit($session)
      if($lowercaseSample){Type-Text $sample}
      if($mask){[void](Press 0xffe5 0 2)}
      if(-not $lowercaseSample){
        $letterMask=if($mask){2}else{1}
        foreach($letter in $sample.ToCharArray()){[void](Press ([int]$letter) $letterMask)}
      }
      $started=[string][RimeProbe]::Input($session)
      if($entry.Key -in 'Delete','Left','Right','Home','End'){[RimeProbe]::SetCaret($session,1)}
      $key=Press $entry.Value ($mask -bor $modifier)
      [pscustomobject]@{Started=$started;Down=$key.Down;Up=$key.Up;Raw=[string][RimeProbe]::Input($session);Caret=[RimeProbe]::Caret($session);Commit=[RimeProbe]::ReadCommit($session)}
    })
    if($states[0].Started -cne $sample -or (-not $modifier -and -not $states[0].Down) -or $states[0].Up -or
        (ConvertTo-Json $states[0] -Compress) -cne (ConvertTo-Json $states[1] -Compress)){
      [pscustomobject]@{Key=$entry.Key;CapsOff=$states[0];CapsOn=$states[1]}
    }
  })
  [RimeProbe]::RimeClearComposition($session)
  [void][RimeProbe]::ReadCommit($session)
  $consumed=@(foreach($entry in $keys.GetEnumerator()){
    $key=Press $entry.Value (2 -bor [int]$modifiers[$entry.Key])
    if($key.Down -or $key.Up -or [RimeProbe]::ReadCommit($session)){$entry.Key}
  })
  $deleteErrors=@(if($mode -eq 'Chinese'){Test-CandidateDeletion})
  Record ('Caps Lock draft editing and empty passthrough in '+$mode) (-not $mismatches.Count -and -not $consumed.Count -and -not $deleteErrors.Count) ([pscustomobject]@{Mismatches=$mismatches;ConsumedWhenEmpty=$consumed;DeleteErrors=$deleteErrors})
  if($mode -in 'Chinese','Japanese'){
    $errors=@(foreach($lock in 0,2){
      Compose 'QQQZ'
      $before=Snapshot
      if($before.Raw -cne 'QQQZ' -or $before.Candidates.Count -or $before.EarlyCommit){'missing draft without candidates'}
      foreach($key in @(@(0xff52,0),@(0xff54,0),@(0xff55,0),@(0xff56,0),@(0xffff,4),@(0xffff,1))){
        $press=Press $key[0] ($lock -bor $key[1])
        $after=Snapshot
        if(-not $press.Down -or $press.Up -or $after.Raw -cne 'QQQZ' -or $after.Caret -ne $before.Caret -or $after.EarlyCommit){
          [pscustomobject]@{Lock=$lock;Key=$key;Press=$press;After=$after}
        }
      }
      [RimeProbe]::RimeClearComposition($session)
    })
    Record ('Unmatched draft keeps navigation and deletion keys in '+$mode) (-not $errors.Count) $errors
  }
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
  if([RimeProbe]::ExportUserDict('cn_stellae',$file) -lt 0){throw 'Synthetic native learning export failed.'}
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
  $compiled=[IO.File]::ReadAllText((Join-Path $build 'cn_stellae.schema.yaml'))
  $defaultCompiled=[IO.File]::ReadAllText((Join-Path $build 'default.yaml'))
  $jpCompiled=[IO.File]::ReadAllText((Join-Path $build 'jp_stellae.schema.yaml'))
  $bindingCount=[regex]::Matches($compiled,'(?m)^    - .*accept: "Control\+space".*$').Count
  $expectedBinding=if($Kind -eq 'pc'){1}else{0}
  Record 'rebuilt Ctrl+Space policy' ($bindingCount -eq $expectedBinding) ([pscustomobject]@{Bindings=$bindingCount;Expected=$expectedBinding})
  foreach($entry in @(@('default',$defaultCompiled),@('pc',$compiled),@('jp',$jpCompiled))){
    $caps=[regex]::Match($entry[1],'(?m)^    Caps_Lock: (\S+)').Groups[1].Value
    Record ('rebuilt Caps Lock '+$entry[0]) ($caps -ceq 'noop') $caps
  }
  Record 'main schema display name' ([regex]::IsMatch($compiled,'(?m)^  name: "?墨芯基底"?\r?$')) '墨芯基底'
  Record 'removed mixed schema dependency and configuration' (-not $compiled.Contains('mixed_full') -and -not $compiled.Contains('mixed_native:')) $null
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
  foreach($english in 0,1){
    [RimeProbe]::RimeSetOption($session,'research_english',$english)
    [RimeProbe]::RimeClearComposition($session)
    foreach($letter in 'ABC'.ToCharArray()){[void](Press ([int]$letter) 2)}
    $draft=[string][RimeProbe]::Input($session)
    $edits=@(foreach($expected in 'AB','A',''){
      $key=Press 0xff08 2
      $actual=[string][RimeProbe]::Input($session)
      [pscustomobject]@{Draft=$actual;Down=$key.Down;Passed=($key.Down -ne 0 -and $actual -ceq $expected)}
    })
    $empty=Press 0xff08 2
    $commit=[RimeProbe]::ReadCommit($session)
    $mode=if($english){'En'}else{'Chinese'}
    $passed=$draft -ceq 'ABC' -and @($edits|Where-Object { -not $_.Passed }).Count -eq 0 -and $empty.Down -eq 0 -and $empty.Up -eq 0 -and -not $commit
    Record ('Caps Lock Backspace in '+$mode) $passed ([pscustomobject]@{Initial=$draft;Edits=$edits;Empty=$empty;Commit=$commit})
  }
  [RimeProbe]::RimeSetOption($session,'research_english',1)
  [RimeProbe]::RimeSetOption($session,'ascii_mode',1)
  [void](Press 0xffe1);[void](Press 0xffe2)
  Record 'red A ignores both Shift taps and remembers En' ([RimeProbe]::RimeGetOption($session,'ascii_mode') -eq 1 -and [RimeProbe]::RimeGetOption($session,'research_english') -eq 1) @([RimeProbe]::RimeGetOption($session,'ascii_mode'),[RimeProbe]::RimeGetOption($session,'research_english'))
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  foreach($mode in 'Chinese','En'){
    [RimeProbe]::RimeSetOption($session,'research_english',[int]($mode -eq 'En'))
    Test-CapsDraft $mode 'ABC'
  }
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  foreach($route in @(@('cn_stellae',0x65,'jp_stellae'),@('jp_stellae',0x65,'cn_stellae'),@('jp_stellae',0x72,'cn_stellae'))){
    $schemas=@(foreach($lock in 0,2){
      [void][RimeProbe]::RimeSelectSchema($session,$route[0]);[RimeProbe]::RimeSetOption($session,'ascii_mode',0)
      $letter=if($lock){[int][char]::ToUpperInvariant([char]$route[1])}else{$route[1]}
      [void](Press $letter (4 -bor $lock))
      Current-Schema
    })
    Record ('hotkey '+$route[0]+' Ctrl+'+[char]$route[1]) ($schemas[0] -ceq $route[2] -and $schemas[1] -ceq $route[2]) $schemas
  }
  [RimeProbe]::RimeSetOption($session,'simplification',0)
  $punctBefore=[RimeProbe]::RimeGetOption($session,'ascii_punct')
  $punctErrors=@(foreach($mask in 4,6){
    $key=Press 0x2e $mask
    if($key.Down -or $key.Up -or [RimeProbe]::RimeGetOption($session,'ascii_punct') -ne $punctBefore -or [RimeProbe]::ReadCommit($session)){$mask}
  })
  $form=Press 0x66 7
  $scOn=[RimeProbe]::RimeGetOption($session,'simplification')
  $menu=Press 0x60 6
  $menuSchema=Current-Schema
  $firstItem=[RimeProbe]::Snapshot($session,1).HighlightedIndex
  $move=Press 0xff54 2
  $nextItem=[RimeProbe]::Snapshot($session,1).HighlightedIndex
  $cancel=Press 0xff1b 2
  $afterCancel=Current-Schema
  $menuPassed=$menu.Down -and $menuSchema -ceq '.default' -and $move.Down -and $nextItem -eq ($firstItem+1) -and $cancel.Down -and $afterCancel -ceq 'cn_stellae'
  Record 'Ctrl+period passes through, Caps Lock TC/SC and menu shortcuts work' (-not $punctErrors.Count -and $form.Down -and $scOn -and $menuPassed) @($punctErrors,$scOn,$menuSchema,$firstItem,$nextItem,$afterCancel)
  [void][RimeProbe]::RimeSelectSchema($session,'cn_stellae')
  [RimeProbe]::RimeSetOption($session,'ascii_punct',0)
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
  [RimeProbe]::RimeSetOption($session,'ascii_mode',0);[RimeProbe]::RimeSetOption($session,'research_english',0);[RimeProbe]::RimeSetOption($session,'simplification',1)
  Compose 'hao';$coldHao=Snapshot
  Record 'whole normal result precedes cold correction' ($coldHao.Candidates[0] -ceq '好') @($coldHao.Candidates|Select-Object -First 6)
  for($i=0;$i -lt 3;$i++){
    Compose 'yao';Select-Text '要'
    $commit=[RimeProbe]::ReadCommit($session)
    Record ('normal word learning '+$i) ($commit -ceq '要') $commit
  }
  Compose 'hao';$learnedHao=Snapshot
  $correctionIndex=[Array]::IndexOf([string[]]$learnedHao.Candidates,'要')
  Record 'whole normal result precedes learned correction' ($learnedHao.Candidates[0] -ceq '好' -and $correctionIndex -gt 0) @($learnedHao.Candidates|Select-Object -First 6)
  foreach($case in @(@('l','了','lambda','λ'),@('z','在','zeta','ζ'))){
    for($i=0;$i -lt 3;$i++){
      Compose $case[0];Select-Text $case[1];[void][RimeProbe]::ReadCommit($session)
    }
    Compose $case[2];Select-Text $case[3];[void][RimeProbe]::ReadCommit($session)
    Compose $case[0];$state=Snapshot
    $normalIndex=[Array]::IndexOf([string[]]$state.Candidates,$case[1])
    $symbolIndex=[Array]::IndexOf([string[]]$state.Candidates,$case[3])
    Record ('Chinese abbreviation and learned symbol share score scale '+$case[0]) ($normalIndex -ge 0 -and $symbolIndex -gt $normalIndex) @($state.Candidates|Select-Object -First 6)
  }
  foreach($case in @(
    @('nihao',@('你好'),@()),@('haode''ba"',@('好的吧'),@()),@('wenti"s',@('问题是'),@()),
    @('xiao;sr',@('笑死人'),@()),@('xian;ren',@('先人'),@('西安人')),@('xian"r',@('先人','西安人'),@()),
    @('jin;zhaoyoujiujin',@('今朝有酒今朝醉'),@()),@('jinzhaoyoujiujin"',@(),@('今朝有酒今朝醉')),
    @('in',@('∈','∞','∫'),@()),@('int',@('∫'),@()),@('alpha',@('α'),@()),
    @('U68B6',@('梶'),@()),@('uUmuwei',@('梶'),@()),@('cC1+1',@('2'),@())
  )){Candidate-Case $case[0] $case[1] $case[2]}
  foreach($case in @(
    @('upan',@('U 盘','U 盤')),@('asizhi',@('A4 纸','A4 紙')),
    @('sanddayin',@('3D 打印')),@('windowsban',@('Windows 版')),
    @('wifimima',@('Wi-Fi 密码','Wi-Fi 密碼'))
  )){Candidate-Case $case[0] @() $case[1]}
  foreach($bracket in @(@(0x5b,'你'),@(0x5d,'好'))){
    Compose 'nihao';[void](Press $bracket[0]);$picked=[RimeProbe]::ReadCommit($session)
    Record ('ordinary Chinese bracket pick '+[char]$bracket[0]) ($picked -ceq $bracket[1]) $picked
  }
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
  Compose 'haodeba';[RimeProbe]::SetCaret($session,0)
  $tab=Press 0xff09 2
  $state=Snapshot
  Record 'Caps Lock Tab moves to the next syllable' ($tab.Down -and -not $tab.Up -and $state.Raw -ceq 'haodeba' -and $state.Caret -eq 3) $state.Caret
  [void][RimeProbe]::RimeSelectSchema($session,'jp_stellae');[RimeProbe]::RimeSetOption($session,'ascii_mode',0)
  Test-CapsDraft 'Japanese' 'KA'
  Compose 'vwo'
  $pageSize=[RebuildProbe]::PageSize($session)
  $down=Press 0xff56 2
  $next=[RimeProbe]::Snapshot($session,1).HighlightedIndex
  $up=Press 0xff55 2
  $back=[RimeProbe]::Snapshot($session,1).HighlightedIndex
  Record 'Caps Lock pages Japanese candidates in both directions' ($pageSize -gt 0 -and $down.Down -and $up.Down -and $next -eq $pageSize -and $back -eq 0) @($next,$back)
  foreach($case in @(@('kana',@('かな')),@('KANA',@('カナ')),@('qnihon',@('日本')),@('vwo',@('我')),@('vwoni',@('我に')))){
    Candidate-Case $case[0] $case[1]
  }
  Compose 'wa';$beforeKana=@((Snapshot).Candidates)
  for($i=0;$i -lt 3;$i++){Compose 'wa';Select-Text 'うぁ';[void][RimeProbe]::ReadCommit($session)}
  Compose 'wa';$afterKana=@((Snapshot).Candidates)
  Record 'romaji alternatives retain fixed order after picks' (($beforeKana -join '|') -ceq ($afterKana -join '|') -and $afterKana[0] -ceq 'わ') $afterKana
  for($i=0;$i -lt 3;$i++){Compose 'vwo';Select-Text '我';[void][RimeProbe]::ReadCommit($session)}
  [RimeProbe]::RimeClearComposition($session)
  [void][RimeProbe]::RimeDestroySession($session);$session=[UIntPtr]::Zero
  $jpLearning=Join-Path $out 'jp-family-learning.tsv'
  $exported=[RimeProbe]::ExportUserDict('jp_kanji',$jpLearning)
  $ownRows=@(if($exported -ge 0){[IO.File]::ReadLines($jpLearning)|Where-Object {$_ -and -not $_.StartsWith('#')} })
  $ownHan=@($ownRows|Where-Object {($_ -split "`t")[0] -ceq '我' -and [int](($_ -split "`t")[2]) -gt 0})
  Record 'Kanji learning remains active' ($ownHan.Count -gt 0) $ownHan
  Record 'removed mixed learning store is not created' (-not (Test-Path -LiteralPath (Join-Path $user 'pc_mixed.userdb'))) $null
  Record 'disabled romaji learning store is not created' (-not (Test-Path -LiteralPath (Join-Path $user 'jp_sela_custom.userdb'))) $null
  Open-PC
  [void][RimeProbe]::RimeSelectSchema($session,'cn_stellae')
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
  $numericErrors=@(foreach($mode in 'Chinese','En','Japanese'){
    foreach($lock in 0,2){
      $schema=if($mode -eq 'Japanese'){'jp_stellae'}else{'cn_stellae'}
      [void][RimeProbe]::RimeSelectSchema($session,$schema)
      [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
      [RimeProbe]::RimeSetOption($session,'research_english',[int]($mode -eq 'En'))
      [RimeProbe]::RimeClearComposition($session)
      [void][RimeProbe]::ReadCommit($session)
      if($lock){[void](Press 0xffe5 0 2)}
      $output=''
      foreach($letter in '1.5'.ToCharArray()){
        $key=Press ([int]$letter) $lock
        if(-not $key.Down){$output+=$letter}
        $output+=[RimeProbe]::ReadCommit($session)
        if($letter -ceq '1' -and ($output -cne '1' -or [RimeProbe]::Input($session))){"$mode/$lock digit did not go directly into the text"}
        if($letter -ceq '.' -and $mode -eq 'Japanese'){
          $point=[RimeProbe]::Snapshot($session,6)
          if($output -cne '1' -or [RimeProbe]::Input($session) -cne '.' -or '．' -cnotin $point.Candidates -or '。' -cnotin $point.Candidates){"$mode/$lock missing ordinary punctuation candidates"}
        }
      }
      if($mode -eq 'Japanese'){
        if($output -cne '1' -or [RimeProbe]::Input($session) -cne '.') {"$mode/$lock period did not stay in the ordinary candidate menu"}
      }elseif($output -cne '1.5' -or [RimeProbe]::Input($session)){"$mode/$lock expected literal 1.5"}
    }
  })
  Record 'Punctuation after a digit follows the current input mode' (-not $numericErrors.Count) $numericErrors
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
