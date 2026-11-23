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
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs')).Replace('__RIME_ENGINE_DLL__',$dll))
$traits=New-Object RimeProbe+Traits
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
$traits.shared_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
$traits.user_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.log_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($evidence)
$traits.app_name=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.official_english_probe')
$traits.min_log_level=2
$script:s=[UIntPtr]::Zero
$checks=New-Object Collections.Generic.List[object]
function Check([string]$id,[bool]$ok,$detail=$null){
 $plain=if($null -ne $detail -and $detail.PSObject.Properties['Candidates']){
  [pscustomobject]@{Preedit=[string]$detail.Preedit;HighlightedIndex=[int]$detail.HighlightedIndex;Candidates=[string[]]$detail.Candidates;Comments=[string[]]$detail.Comments}
 }elseif($detail -is [Array]){[string[]]$detail}else{[string]$detail}
 $checks.Add([pscustomobject]@{Id=$id;Passed=$ok;Detail=$plain});Write-Host ($id+': '+$ok)
}
function Press([int]$key,[int]$mask=0){$a=[RimeProbe]::RimeProcessKey($script:s,$key,$mask);[void][RimeProbe]::RimeProcessKey($script:s,$key,($mask -bor 0x40000000));return $a}
function Type-Word([string]$text){foreach($c in $text.ToCharArray()){[void](Press ([int]$c))}}
function Reset-Draft{[RimeProbe]::RimeClearComposition($script:s);[void][RimeProbe]::ReadCommit($script:s);[RimeProbe]::RimeSetOption($script:s,'ascii_mode',0);[RimeProbe]::RimeSetOption($script:s,'research_english',1)}
function Snap{return [RimeProbe]::Snapshot($script:s,30)}
$result=[ordered]@{Completed=$false;Error=$null;Profile='fresh official-weasel';SyntheticLearningOnly=$true}
try {
 Write-Host 'Initializing official DLL'
 [RimeProbe]::RimeSetup([ref]$traits);[RimeProbe]::RimeInitialize([ref]$traits)
 Write-Host 'Creating isolated session'
 $result.Engine=[RimeProbe]::Version();$script:s=[RimeProbe]::RimeCreateSession()
 if(-not [RimeProbe]::RimeSelectSchema($script:s,'pc_research')){throw 'Cannot select isolated backup schema'}
 Write-Host 'Typing Answer'
 Reset-Draft;Type-Word 'Answer';$snap=Snap
 Check 'Answer-first' ($snap.Candidates[0] -ceq 'Answer') $snap
 [void](Press 49);$text=[RimeProbe]::ReadCommit($script:s)
 Check 'capital-number-select-no-space' ($text -ceq 'Answer' -and -not [RimeProbe]::Input($script:s)) $text
 Reset-Draft;Type-Word 'form';[void](Press 32);$text=[RimeProbe]::ReadCommit($script:s)
 Check 'space-one-trailing-space' ($text -ceq 'form ') $text
 Reset-Draft;Type-Word 'form';[void][RimeProbe]::SelectCandidate($script:s,0);$text=[RimeProbe]::ReadCommit($script:s)
 Check 'mouse-selection-no-space' ($text -ceq 'form') $text
 Reset-Draft;Type-Word 'wheer';[void](Press 0xff0d);$text=[RimeProbe]::ReadCommit($script:s)
 Check 'enter-original-no-space' ($text -ceq 'wheer') $text
 Reset-Draft;Type-Word 'go';$snap=Snap
 Check 'go-exact-before-brand' ($snap.Candidates[0] -ceq 'go') $snap
 Reset-Draft;Type-Word 'WH';$snap=Snap
 Check 'uppercase-completion' ($snap.Candidates -ccontains 'WHERE') $snap
 Reset-Draft;Type-Word 'WHe';$snap=Snap
 Check 'no-invented-mixed-case' (-not ($snap.Candidates -ccontains 'WHere')) $snap
 Reset-Draft;Type-Word 'wheer';$snap=Snap
 Check 'correction-where' ($snap.Candidates -contains 'where') $snap
 Reset-Draft;Type-Word 'well-known'
 Check 'hyphen-before-paging-literal' ([RimeProbe]::Input($script:s) -ceq 'well-known') (Snap)
 Reset-Draft;Type-Word 'wh';[void](Press 61);$snap=Snap
 Check 'equals-next-page-six' ($snap.HighlightedIndex -eq 6) $snap
 [void](Press 45);$snap=Snap
 Check 'minus-back-after-page' ($snap.HighlightedIndex -eq 0 -and [RimeProbe]::Input($script:s) -ceq 'wh') $snap
 [void](Press 46);$snap=Snap
 Check 'period-next-candidate' ($snap.HighlightedIndex -eq 1) $snap
 [void](Press 44);$snap=Snap
 Check 'comma-previous-candidate' ($snap.HighlightedIndex -eq 0) $snap
 Reset-Draft;Type-Word 'where';[void](Press 0xffe1)
 Check 'left-shift-cn-keeps-draft' ([RimeProbe]::RimeGetOption($script:s,'research_english') -eq 0 -and [RimeProbe]::Input($script:s) -ceq 'where' -and -not [RimeProbe]::ReadCommit($script:s)) (Snap)
 [void](Press 0xffe1)
 Check 'left-shift-en-keeps-draft' ([RimeProbe]::RimeGetOption($script:s,'research_english') -eq 1 -and [RimeProbe]::Input($script:s) -ceq 'where' -and -not [RimeProbe]::ReadCommit($script:s)) (Snap)
 Reset-Draft;[void][RimeProbe]::RimeProcessKey($script:s,0xffe1,0);[void](Press 65 1);[void][RimeProbe]::RimeProcessKey($script:s,0xffe1,0x40000000)
 Check 'shift-letter-chord-not-toggle' ([RimeProbe]::RimeGetOption($script:s,'research_english') -eq 1 -and [RimeProbe]::Input($script:s) -ceq 'A') (Snap)
 Reset-Draft;[void](Press 0xffe2)
 Check 'right-shift-native-ascii' ([RimeProbe]::RimeGetOption($script:s,'ascii_mode') -eq 1 -and [RimeProbe]::RimeGetOption($script:s,'research_english') -eq 0)
 [void](Press 0xffe2)
 Check 'right-shift-native-return' ([RimeProbe]::RimeGetOption($script:s,'ascii_mode') -eq 0)
 Reset-Draft;[void](Press 0xffe5)
 Check 'caps-native-ascii' ([RimeProbe]::RimeGetOption($script:s,'ascii_mode') -eq 1 -and [RimeProbe]::RimeGetOption($script:s,'research_english') -eq 0)
 [void](Press 0xffe5 2)
 Check 'caps-native-return' ([RimeProbe]::RimeGetOption($script:s,'ascii_mode') -eq 0)
 Reset-Draft;Type-Word ('h'*65)
 Check 'english-limit-preserves-64' ([RimeProbe]::Input($script:s).Length -eq 64 -and -not [RimeProbe]::ReadCommit($script:s)) ([RimeProbe]::Input($script:s))
 Reset-Draft;Type-Word 'where';[void](Press 0xff51 4)
 Check 'ctrl-left-word-start' ([RimeProbe]::Caret($script:s) -eq 0) (Snap)
 [void](Press 0xff53 4)
 Check 'ctrl-right-word-end' ([RimeProbe]::Caret($script:s) -eq 5) (Snap)
 [void](Press 0xff08 4)
 Check 'ctrl-backspace-pending-word' (-not [RimeProbe]::Input($script:s)) (Snap)
 [RimeProbe]::RimeDestroySession($script:s)|Out-Null;$script:s=[UIntPtr]::Zero
 $export=Join-Path $evidence 'english-learning.tsv'
 [void][RimeProbe]::ExportUserDict('pc_english',$export)
 $learned=Get-Content -LiteralPath $export -Encoding UTF8
 Check 'english-native-learning' ([bool]($learned | Where-Object {$_ -cmatch '^form\t'})) @($learned | Where-Object {$_ -cmatch '^form\t'})
 $script:s=[RimeProbe]::RimeCreateSession()
 if(-not [RimeProbe]::RimeSelectSchema($script:s,'pc_research')){throw 'Cannot reopen backup schema'}
 Reset-Draft;Type-Word 'hello';$snap=Snap
 Check 'english-reopen-after-learning' ($snap.Candidates[0] -ceq 'hello') $snap
 $result.Completed=$true
} catch {$result.Error=$_.Exception.ToString()}
finally {
 if($script:s -ne [UIntPtr]::Zero){[void][RimeProbe]::RimeDestroySession($script:s)}
 Write-Host 'Finalizing official DLL'
 [RimeProbe]::RimeFinalize()
 Write-Host 'Finalized official DLL'
}
$result.Checks=$checks.ToArray();$result.Passed=@($checks|Where-Object Passed).Count;$result.Failed=@($checks|Where-Object {-not $_.Passed}).Count
Write-Host 'Building probe JSON'
$json=$result|ConvertTo-Json -Depth 10
Write-Host 'Writing probe JSON'
[IO.File]::WriteAllText((Join-Path $evidence 'results.json'),$json,(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{Completed=$result.Completed;Passed=$result.Passed;Failed=$result.Failed;Error=$result.Error}|ConvertTo-Json
if(-not $result.Completed -or $result.Failed){exit 1}
