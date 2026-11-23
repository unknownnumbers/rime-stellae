# SPDX-License-Identifier: GPL-3.0-only
# Run only with the repository configuration and a fresh synthetic output.
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$SharedData,
 [Parameter(Mandatory=$true)][string]$Output,
 [ValidateSet('Compile','Query','Learning','Edges','Reset','Sequences','SequenceLearning')][string]$Phase='Query',
 [ValidatePattern('^[a-z0-9-]+$')][string]$Revision='r1'
)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$native=[IO.Path]::GetFullPath($Output)
$user=Join-Path $native 'publicuser'
$build=Join-Path $user 'build'

if($Phase -eq 'Compile'){
 if(Test-Path -LiteralPath $user){throw 'Compile requires a fresh output/publicuser directory; keep previous results.'}
 $configuration=Join-Path $workspace 'config/pc'
 [IO.Directory]::CreateDirectory($user)|Out-Null
 foreach($sourceItem in Get-ChildItem -LiteralPath $configuration -Force){
  Copy-Item -LiteralPath $sourceItem.FullName -Destination $user -Recurse
 }
 # OpenCC resources belong to the caller-provided official shared-data tree.
 # Only this isolated copy receives resolved resource paths.
 $openccFile=Join-Path $user 'opencc/mdx_t2s.json'
 if(Test-Path -LiteralPath $openccFile){
  $opencc=[IO.File]::ReadAllText($openccFile,$utf8)|ConvertFrom-Json
  foreach($group in @($opencc.segmentation.dict,$opencc.conversion_chain[0].dict)){
   foreach($dictionary in $group.dicts){
    if($dictionary.type -eq 'ocd2'){
     $dictionary.file=(Join-Path (Join-Path ([IO.Path]::GetFullPath($SharedData)) 'opencc') ([IO.Path]::GetFileName($dictionary.file))).Replace('\','/')
     if(-not(Test-Path -LiteralPath $dictionary.file)){throw ('Missing shared OpenCC resource '+$dictionary.file)}
    }elseif($dictionary.type -eq 'text'){
     $dictionary.file=(Join-Path (Join-Path $user 'opencc') ([IO.Path]::GetFileName($dictionary.file))).Replace('\','/')
    }
   }
  }
  [IO.File]::WriteAllText($openccFile,($opencc|ConvertTo-Json -Depth 12),$utf8)
 }
}

$evidence=Join-Path $native ('results/'+$Revision)
$report=Join-Path $evidence ($Phase.ToLower()+'-results.json')
if(Test-Path -LiteralPath $report){throw 'Preserve previous finite results; choose a new Revision.'}
if(-not(Test-Path -LiteralPath (Join-Path $user 'jp_sela.schema.yaml'))){throw 'Prepare the isolated publicuser profile first.'}
if(-not([IO.Path]::GetFullPath($user).StartsWith(([IO.Path]::GetFullPath($native)+'\'),[StringComparison]::OrdinalIgnoreCase))){throw 'Outside isolated native root.'}
$logs=Join-Path $evidence ('logs-'+$Phase.ToLower())
[IO.Directory]::CreateDirectory($logs)|Out-Null
$dll=[IO.Path]::GetFullPath($EngineDll)
$api=Join-Path $PSScriptRoot 'RimeProbe.cs'
Add-Type -TypeDefinition ([IO.File]::ReadAllText($api,$utf8).Replace('__RIME_ENGINE_DLL__',$dll))
$traits=New-Object RimeProbe+Traits
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
$traits.shared_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi([IO.Path]::GetFullPath($SharedData))
$traits.user_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.prebuilt_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($build)
$traits.staging_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($build)
$traits.log_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($logs)
$traits.app_name=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.jp_j02_finite')
$traits.min_log_level=2
$script:session=[UIntPtr]::Zero
$script:trace=New-Object Collections.Generic.List[object]
$rows=New-Object Collections.Generic.List[object]
$checks=New-Object Collections.Generic.List[object]
$result=[ordered]@{Completed=$false;Finalized=$false;Passed=$false;Phase=$Phase;Revision=$Revision;Error=$null;ContextSetInputUsed=$false;InputMethod='RimeProcessKey physical down/up; uppercase Shift_L chord; mouse path Rime SelectCandidate API';PrivateLearningCopied=$false;LiveModified=$false;WorkingModified=$false;ServiceRestarted=$false}
function Snap{return [pscustomobject]@{Input=[RimeProbe]::Input($script:session);Caret=[RimeProbe]::Caret($script:session);AsciiMode=[bool][RimeProbe]::RimeGetOption($script:session,'ascii_mode');Snapshot=[RimeProbe]::Snapshot($script:session,200)}}
function Event([string]$label,[int]$code,[int]$mask=0){
 $handled=[bool][RimeProbe]::RimeProcessKey($script:session,$code,$mask)
 $script:trace.Add([pscustomobject]@{Label=$label;Code=$code;Mask=$mask;Handled=$handled;Commit=[RimeProbe]::ReadCommit($script:session);State=(Snap)})
}
function Press([string]$label,[int]$code,[int]$mask=0){Event ($label+' down') $code $mask;Event ($label+' up') $code ($mask -bor 0x40000000)}
function Type-Raw([string]$raw){foreach($ch in $raw.ToCharArray()){
 if([char]::IsUpper($ch)){Event 'Shift_L down' 0xffe1;Press ([string]$ch) ([int]$ch) 1;Event 'Shift_L up' 0xffe1 0x40000000}
 else{Press ([string]$ch) ([int]$ch)}
}}
function Commits{return @($script:trace.ToArray()|Where-Object {-not [string]::IsNullOrEmpty($_.Commit)}|ForEach-Object {$_.Commit})}
function Check([string]$id,[bool]$passed,$actual){$checks.Add([pscustomobject]@{Id=$id;Passed=$passed;Actual=$actual})}
function Close-Session{
 if($script:session -ne [UIntPtr]::Zero){[RimeProbe]::RimeClearComposition($script:session);[RimeProbe]::RimeDestroySession($script:session)|Out-Null;$script:session=[UIntPtr]::Zero}
}
function New-Session{
 Close-Session
 $script:session=[RimeProbe]::RimeCreateSession()
 if(-not [RimeProbe]::RimeSelectSchema($script:session,'jp_sela')){throw 'JP schema unavailable'}
 [RimeProbe]::RimeSetOption($script:session,'probe_options_ready',1)
 foreach($name in @('ascii_mode','research_english','simplification')){[RimeProbe]::RimeSetOption($script:session,$name,0)}
 [RimeProbe]::ReadCommit($script:session)|Out-Null
 $script:trace.Clear()
}
function Query([string]$raw){
 New-Session;Type-Raw $raw
 $state=Snap
 Check ('held-typing-raw-'+$raw) ($state.Input -ceq $raw) $state.Input
 Check ('typing-no-commit-'+$raw) ((Commits).Count -eq 0) (Commits)
 Check ('ascii-off-'+$raw) (-not $state.AsciiMode) $state.AsciiMode
 return $state
}
function Highlight([string]$word){
 $state=Snap
 $index=[Array]::IndexOf([string[]]$state.Snapshot.Candidates,$word)
 if($index -lt 0){throw ('Missing target '+$word+' in '+$state.Input)}
 $moves=0
 while($state.Snapshot.HighlightedIndex -ne $index -and $moves -lt 210){
  Press 'Down highlight target' 0xff54;$state=Snap;$moves++
 }
 if($state.Snapshot.HighlightedIndex -ne $index){throw 'Cannot highlight finite target.'}
 return $index
}
function Add-Row([string]$kind,[string]$raw,$before){$rows.Add([pscustomobject]@{Kind=$kind;Raw=$raw;Before=$before;After=(Snap);Commits=@(Commits);Trace=$script:trace.ToArray()})}
function Select-Target([string]$raw,[string]$target,[string]$label='Space'){
 $before=Query $raw
 Check ('target-present-'+$raw) (@($before.Snapshot.Candidates|Where-Object {$_ -ceq $target}).Count -gt 0) $before.Snapshot.Candidates
 [void](Highlight $target);Press $label 0x20
 Check ('selection-body-'+$raw) (((Commits) -join '') -ceq $target -and (Snap).Input -ceq '') @{Commits=(Commits);State=(Snap)}
 Add-Row 'target-selection' $raw $before
}
function Partial-Target([string]$raw,[string]$target,[string]$expected,[ValidateSet('Space','Number','Mouse')][string]$method='Space'){
 $before=Query $raw
 $index=[void]0
 if($method -eq 'Number'){
  Check ('number-first-target-'+$raw) ($before.Snapshot.Candidates[0] -ceq $target) $before.Snapshot.Candidates
  Press '1 native selection' 0x31
 }elseif($method -eq 'Mouse'){
  $index=[Array]::IndexOf([string[]]$before.Snapshot.Candidates,$target)
  if($index -lt 0){throw ('Missing mouse target '+$target)}
  $selected=[bool][RimeProbe]::SelectCandidate($script:session,$index)
  $script:trace.Add([pscustomobject]@{Label='mouse native SelectCandidate';Index=$index;Handled=$selected;Commit=[RimeProbe]::ReadCommit($script:session);State=(Snap)})
 }else{[void](Highlight $target);Press 'Space native partial selection' 0x20}
 $selectedState=Snap
 Check ('partial-selection-pending-'+$method+'-'+$raw) ((Commits).Count -eq 0 -and $selectedState.Input -ceq $raw) @{Commits=(Commits);State=$selectedState}
 Press 'Return raw remainder' 0xff0d
 Check ('partial-Return-'+$method+'-'+$raw) (((Commits)-join '') -ceq $expected -and (Snap).Input -ceq '') @{Expected=$expected;Commits=(Commits);State=(Snap)}
 Add-Row ('partial-'+$method) $raw $before
}
function Return-Raw([string]$raw,[string]$expected){
 $before=Query $raw
 Press 'Return raw body' 0xff0d
 Check ('Return-body-'+$raw) (((Commits)-join '') -ceq $expected -and (Snap).Input -ceq '') @{Commits=(Commits);State=(Snap)}
 Add-Row 'Return-raw' $raw $before
}
function Navigation([string]$raw){
 $before=Query $raw
 Press 'Tab' 0xff09;$tab=Snap
 Press 'Right' 0xff53;$right=Snap
 Press 'Left' 0xff51;$left=Snap
 Check ('navigation-raw-'+$raw) (@($before,$tab,$right,$left|Where-Object {$_.Input -cne $raw}).Count -eq 0) @($before.Input,$tab.Input,$right.Input,$left.Input)
 Check ('navigation-no-commit-'+$raw) ((Commits).Count -eq 0) (Commits)
 if($raw -eq 'qQtaberuhana' -or $raw -eq 'xXSHIYU'){
  Check ('navigation-Tab-moves-'+$raw) ($tab.Caret -ne $before.Caret) @($before.Caret,$tab.Caret)
 }
 Check ('navigation-Right-moves-'+$raw) ($right.Caret -ne $tab.Caret) @($tab.Caret,$right.Caret)
 Check ('navigation-Left-moves-'+$raw) ($left.Caret -ne $right.Caret) @($right.Caret,$left.Caret)
 Add-Row 'navigation' $raw $before
}
function Export-Learning([string]$db,[string]$label){
 Close-Session
 $path=Join-Path $evidence ($Phase.ToLower()+'-'+$label+'-'+$db+'.tsv')
 $count=[RimeProbe]::ExportUserDict($db,$path)
 if($count -lt 0){throw ('Synthetic learning export failed '+$db)}
 $lines=[IO.File]::ReadAllLines($path,$utf8)
 $value=[pscustomobject]@{Db=$db;Label=$label;Count=$count;Lines=$lines;Path=$path}
 $rows.Add([pscustomobject]@{Kind='synthetic-export';Value=$value})
 return $value
}
function Word-Count($export,[string]$word){foreach($line in $export.Lines){$fields=$line.Split("`t");if($fields.Count -ge 3 -and $fields[0] -ceq $word -and ($export.Db -ne 'jp_family' -or $fields[1].TrimEnd() -ceq $word)){return [int]$fields[2]}};return 0}
try{
 [RimeProbe]::RimeSetup([ref]$traits);[RimeProbe]::RimeInitialize([ref]$traits)
 $result.EngineVersion=[RimeProbe]::Version()
 if($Phase -eq 'Compile'){
  [RimeProbe]::RimeDeployerInitialize([ref]$traits)
  foreach($schema in @('stroke','english_full','mixed_full','project_radical','project_radical_parts','jp_small_lookup','jp_q_lookup','jp_v_lookup','jp_v_pc_lookup','jp_sela','pc_research')){
   $ok=[bool][RimeProbe]::RimeDeploySchema((Join-Path $user ($schema+'.schema.yaml')))
   Check ('compile-'+$schema) $ok $ok
   if(-not $ok){throw ('Isolated compilation failed '+$schema)}
   $compiledSchema = Join-Path $build ($schema+'.schema.yaml')
   if(-not(Test-Path -LiteralPath $compiledSchema)){throw ('Missing compiled schema '+$schema)}
   $compiledText = [IO.File]::ReadAllText($compiledSchema,$utf8)
   if($compiledText -notmatch '(?m)^schema:' -or ($schema -in @('stroke','pc_research','jp_sela') -and $compiledText -notmatch '(?m)^engine:')){
    throw ('Incomplete compiled schema '+$schema)
   }
  }
 }elseif($Phase -eq 'Query'){
  foreach($pair in @(@('qtaberu','食べる'),@('qtabeta','食べた'),@('qtabenai','食べない'),@('qomoshiroi','面白い'),@('qQTaBeRu','食べる'),@('qQTABETA','食べた'))){Select-Target $pair[0] $pair[1]}
  foreach($raw in @('qsakura','qQsakura')){
   $before=Query $raw
   $modern=[Array]::IndexOf([string[]]$before.Snapshot.Candidates,'桜')
   $old=[Array]::IndexOf([string[]]$before.Snapshot.Candidates,'櫻')
   Check ('family-variants-contiguous-'+$raw) ($modern -ge 0 -and $old -eq $modern+1) @{Modern=$modern;Old=$old;Candidates=$before.Snapshot.Candidates}
   Add-Row 'family-variants' $raw $before
  }
  foreach($method in @('Space','Number','Mouse')){Partial-Target 'qQtaberuZZ' '食べる' '食べるZZ' $method}
  Return-Raw 'qQTaBeRu' 'TaBeRu'
  Return-Raw 'qQ' ''
  foreach($pair in @(@('xXSHI',[string][char]0x31f1),@('xXA','ァ'),@('xXKO',[char]::ConvertFromUtf32(0x1b155)),@('xXPU',([string][char]0x31f7+[string][char]0x309a)))){Select-Target $pair[0] $pair[1]}
  foreach($raw in @('xXshi','xXkya')){
   $before=Query $raw
   Check ('small-unsupported-no-candidate-'+$raw) ($before.Snapshot.Candidates.Count -eq 0) $before.Snapshot.Candidates
   Press 'Space keeps unsupported draft' 0x20
   Check ('small-unsupported-held-'+$raw) ((Snap).Input -ceq $raw -and (Commits).Count -eq 0) @{State=(Snap);Commits=(Commits)}
   Press 'Return unsupported body' 0xff0d
   Check ('small-unsupported-Return-'+$raw) (((Commits)-join '') -ceq $raw.Substring(2)) (Commits)
   Add-Row 'small-unsupported' $raw $before
  }
  Partial-Target 'xXSHIYU' ([string][char]0x31f1) ([string][char]0x31f1+'YU') 'Space'
  Return-Raw 'xXA' 'A'
  Return-Raw 'xX' ''
  foreach($pair in @(@('qQtaberu',0x5b,'食'),@('qQomoshiroi',0x5d,'白'))){
   $before=Query $pair[0];[void](Highlight $(if($pair[0] -ceq 'qQtaberu'){'食べる'}else{'面白い'}))
   Press 'bracket skips kana' $pair[1]
   Check ('bracket-Han-only-'+$pair[0]) (((Commits)-join '') -ceq $pair[2]) (Commits)
   Add-Row 'bracket' $pair[0] $before
  }
  foreach($raw in @('qtaberu','qQtaberuhana','xXSHIYU','vVshen')){Navigation $raw}
  Select-Target 'ka' 'か'
  $before=Query 'vVshen';Check 'v-query-still-has-shared-sei' ($before.Snapshot.Candidates -contains '生') $before.Snapshot.Candidates;Add-Row 'v-unchanged' 'vVshen' $before
  Return-Raw 'vVshen' 'shen'
 }elseif($Phase -eq 'Sequences'){
  foreach($pair in @(@('qQsakurakouji','桜小路'),@('qQsakurakomichi','桜小路'),@('qQSaKuRaKoUjI','桜小路'),@('qsakurakouji','桜小路'),@('xXaA','ぁァ'),@('xXaAa','ぁァぁ'),@('xXkaKA','ゕヵ'),@('xXSHIPUa',([string][char]0x31f1+[string][char]0x31f7+[string][char]0x309a+'ぁ')),@('xXKOa',([char]::ConvertFromUtf32(0x1b155)+'ぁ')),@('sasasa','さささ'))){Select-Target $pair[0] $pair[1]}
  foreach($method in @('Space','Mouse')){Partial-Target 'qQsakurakoujiZZ' '桜小路' '桜小路ZZ' $method}
  Partial-Target 'xXaAZZ' 'ぁァ' 'ぁァZZ' 'Space'
  foreach($raw in @('qQsakurakouji','xXaA','xXSHIPUa')){Navigation $raw}
  $before=Query 'qQsakurakouji';[void](Highlight '桜小路')
  Press 'Tab preserves composed word boundary' 0xff09
  Check 'q-composed-Tab-boundary' ((Snap).Caret -eq 8) (Snap).Caret
  Add-Row 'composed-Tab' 'qQsakurakouji' $before
  $before=Query 'xXaA';Press 'Tab small kana boundary' 0xff09
  Check 'small-composed-Tab-boundary' ((Snap).Caret -eq 3) (Snap).Caret
  Add-Row 'small-composed-Tab' 'xXaA' $before
 }elseif($Phase -eq 'SequenceLearning'){
  $before=Export-Learning 'jp_family' 'sequence-before'
  if((Word-Count $before '桜小路') -le 0){
   # A preceding reset leaves hidden native history. Revive it once before
   # measuring ordinary +1 selections, rather than assuming erased history.
   Select-Target 'qQsakurakouji' '桜小路'
   $before=Export-Learning 'jp_family' 'sequence-active-before'
  }
  Select-Target 'qQsakurakouji' '桜小路'
  $after=Export-Learning 'jp_family' 'sequence-after-Space'
  Check 'sequence-count-exactly-one-Space' ((Word-Count $after '桜小路') -eq ((Word-Count $before '桜小路')+1)) @{Before=(Word-Count $before '桜小路');After=(Word-Count $after '桜小路')}
  Check 'sequence-reading-zero-count-present' (@($after.Lines|Where-Object {$_ -match '^桜小路\s+@jpq1\|' -and $_ -match '\s0$'}).Count -gt 0) @($after.Lines|Where-Object {$_ -match '^桜小路\s+@jpq1\|'})
  $learned=Query 'qQSAKURAKOUJI'
  Check 'learned-sequence-promoted' ($learned.Snapshot.Candidates[0] -ceq '桜小路') $learned.Snapshot.Candidates
  Press '1 selected learned sequence' 0x31
  Check 'learned-number-commit' (((Commits)-join '') -ceq '桜小路') (Commits)
  $second=Export-Learning 'jp_family' 'sequence-after-number'
  Check 'sequence-count-exactly-one-number' ((Word-Count $second '桜小路') -eq ((Word-Count $after '桜小路')+1)) @{Before=(Word-Count $after '桜小路');After=(Word-Count $second '桜小路')}
  $mouse=Query 'qQsakurakouji'
  $mouseIndex=[Array]::IndexOf([string[]]$mouse.Snapshot.Candidates,'桜小路')
  $mouseSelected=[RimeProbe]::SelectCandidate($script:session,$mouseIndex)
  $mouseCommit=[RimeProbe]::ReadCommit($script:session)
  Check 'sequence-mouse-commit' ($mouseSelected -and $mouseCommit -ceq '桜小路') $mouseCommit
  $mouseAfter=Export-Learning 'jp_family' 'sequence-after-mouse'
  Check 'sequence-count-exactly-one-mouse' ((Word-Count $mouseAfter '桜小路') -eq ((Word-Count $second '桜小路')+1)) @{Before=(Word-Count $second '桜小路');After=(Word-Count $mouseAfter '桜小路')}
  $cross=Query 'qsakurakouji'
  Check 'sequence-shared-single-q' ($cross.Snapshot.Candidates[0] -ceq '桜小路') $cross.Snapshot.Candidates
  $reset=Query 'qQsakurakouji';[void](Highlight '桜小路')
  Press 'Shift Delete resets composed word' 0xffff 1
  $deleted=Export-Learning 'jp_family' 'sequence-after-reset'
  Check 'sequence-reset-no-positive-count' ((Word-Count $deleted '桜小路') -le 0) (Word-Count $deleted '桜小路')
  $static=Query 'qQsakurakouji'
  Check 'sequence-remains-available-after-reset' ($static.Snapshot.Candidates -contains '桜小路') $static.Snapshot.Candidates
 }elseif($Phase -eq 'Reset'){
  $prior=Export-Learning 'jp_family' 'before-reset'
  $before=Query 'qQtaberu';[void](Highlight '食べる')
  Press 'Shift Delete resets only selected JP family' 0xffff 1
  Check 'reset-retains-draft' ((Snap).Input -ceq 'qQtaberu' -and (Commits).Count -eq 0) (Snap)
  $after=Export-Learning 'jp_family' 'after-reset'
  Check 'mixed-reset-clears-positive-learning' ((Word-Count $after '食べる') -le 0) (Word-Count $after '食べる')
  Select-Target 'qQtaberu' '食べる'
  $relearned=Export-Learning 'jp_family' 'after-relearn'
  # Native UserDictionary deletion suppresses a record; it does not erase its
  # stored historical count. Re-selecting revives that count and adds one.
  Check 'mixed-relearn-keeps-native-count-semantics' ((Word-Count $relearned '食べる') -eq ((Word-Count $prior '食べる')+1)) @{Before=(Word-Count $prior '食べる');After=(Word-Count $relearned '食べる')}
 }elseif($Phase -eq 'Edges'){
  Select-Target "qshin'ya" '深夜'
  Select-Target 'qitta' '行った'
  Partial-Target 'vVshenhao' '生' '生hao' 'Space'
  Partial-Target 'xXPUA' ([string][char]0x31f7+[string][char]0x309a) ([string][char]0x31f7+[string][char]0x309a+'A') 'Space'
  foreach($prefix in @('qQ','xX')){
   $raw=$prefix+('z'*48);$before=Query $raw
   Press 'extra spelling at cap' 0x7a
   Check ('48-letter-cap-'+$prefix) ((Snap).Input -ceq $raw) (Snap).Input
   Press 'Backspace reopens capacity' 0xff08
   Press 'replace deleted letter' 0x61
   Check ('48-letter-cap-remains-editable-'+$prefix) ((Snap).Input -ceq ($prefix+('z'*47)+'a')) (Snap).Input
   Press 'Return capped raw body' 0xff0d
   Check ('capped-Return-'+$prefix) (((Commits)-join '') -ceq (('z'*47)+'a')) (Commits)
   Add-Row 'capacity' $raw $before
  }
  $before=Query 'qQtaberuhana';[void](Highlight '食べる')
  Press 'bracket keeps held remainder' 0x5d
  Check 'bracket-partial-tail' (((Commits)-join '') -ceq '食' -and (Snap).Input -ceq 'qQhana') @{Commits=(Commits);State=(Snap)}
  Add-Row 'partial-bracket' 'qQtaberuhana' $before
 }else{
  $familyBefore=Export-Learning 'jp_family' 'before'
  $legacyBefore=Export-Learning 'jp_sela_custom' 'before'
  $cnBefore=Export-Learning 'luna_pinyin' 'before'
  Select-Target 'vVshen' '生'
  $qBefore=Query 'qsei';Check 'v-learning-promotes-qsei' ($qBefore.Snapshot.Candidates[0] -ceq '生') $qBefore.Snapshot.Candidates;Add-Row 'shared-qsei' 'qsei' $qBefore
  Select-Target 'qsei' '生'
  $alternate=Query 'qshou';Check 'q-reading-shares-family-promotion' ($alternate.Snapshot.Candidates[0] -ceq '生') $alternate.Snapshot.Candidates;Add-Row 'shared-qshou' 'qshou' $alternate
  Select-Target 'qshou' '生'
  $vAfter=Query 'vVshen';Check 'q-learning-promotes-v' ($vAfter.Snapshot.Candidates[0] -ceq '生') $vAfter.Snapshot.Candidates;Add-Row 'shared-v' 'vVshen' $vAfter
  Select-Target 'qtaberu' '食べる'
  Select-Target 'qQTaBeRu' '食べる'
  $familyAfter=Export-Learning 'jp_family' 'after-JP'
  $legacyAfter=Export-Learning 'jp_sela_custom' 'after-JP'
  $cnAfter=Export-Learning 'luna_pinyin' 'after-JP'
  Check 'shared-sei-exact-three-native-selections' ((Word-Count $familyAfter '生') -eq ((Word-Count $familyBefore '生')+3)) @{Before=(Word-Count $familyBefore '生');After=(Word-Count $familyAfter '生')}
  Check 'mixed-form-exact-two-native-selections' ((Word-Count $familyAfter '食べる') -eq ((Word-Count $familyBefore '食べる')+2)) @{Before=(Word-Count $familyBefore '食べる');After=(Word-Count $familyAfter '食べる')}
  Check 'mixed-form-one-canonical-family-row' (@($familyAfter.Lines|Where-Object {$_.StartsWith("食べる`t")}).Count -eq 1) @($familyAfter.Lines|Where-Object {$_.StartsWith("食べる`t")})
  Check 'mixed-does-not-double-learn-legacy' ((Word-Count $legacyAfter '食べる') -eq (Word-Count $legacyBefore '食べる') -and (Word-Count $legacyAfter '生') -eq (Word-Count $legacyBefore '生')) $legacyAfter.Lines
  Check 'JP-selections-preserve-CN-export' (($cnBefore.Lines -join "`n") -ceq ($cnAfter.Lines -join "`n")) @{Before=$cnBefore.Lines;After=$cnAfter.Lines}
  Select-Target 'ka' 'か'
  $kanaAfter=Export-Learning 'jp_sela_custom' 'after-kana'
  Check 'ordinary-kana-still-learns-once-in-legacy' ((Word-Count $kanaAfter 'か') -eq ((Word-Count $legacyAfter 'か')+1)) @{Before=(Word-Count $legacyAfter 'か');After=(Word-Count $kanaAfter 'か')}
 }
 $result.Completed=$true
}catch{$result.Error=$_.Exception.ToString()}
finally{
 Close-Session
 [RimeProbe]::RimeFinalize();$result.Finalized=$true
 foreach($pointer in @($traits.shared_data_dir,$traits.user_data_dir,$traits.prebuilt_data_dir,$traits.staging_dir,$traits.log_dir,$traits.app_name)){[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
 $result.Rows=$rows.ToArray();$result.Checks=$checks.ToArray()
 $result.FailedChecks=@($checks|Where-Object {-not $_.Passed}).Count
 $result.Passed=$result.Completed -and $result.Finalized -and $result.FailedChecks -eq 0
 [IO.File]::WriteAllText($report,($result|ConvertTo-Json -Depth 20),$utf8)
 [pscustomobject]@{Completed=$result.Completed;Finalized=$result.Finalized;Passed=$result.Passed;Rows=$rows.Count;Checks=$checks.Count;FailedChecks=$result.FailedChecks;Error=$result.Error;Report=$report}|ConvertTo-Json
}
if(-not $result.Passed){exit 1}
