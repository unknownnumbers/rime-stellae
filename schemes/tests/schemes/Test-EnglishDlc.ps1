# SPDX-License-Identifier: GPL-3.0-only
# A standalone profile with fixed synthetic catalogs and learning only.
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [ValidateSet('pc','official-weasel')][string]$Profile='pc'
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'Choose a fresh synthetic output directory.'}
$user=Join-Path $out 'user';$shared=Join-Path $out 'shared';$logs=Join-Path $out 'logs'
$utf8=[Text.UTF8Encoding]::new($false)
foreach($directory in @($user,$shared,$logs,(Join-Path $user 'build'),(Join-Path $user 'lua'))){[IO.Directory]::CreateDirectory($directory)|Out-Null}
function Write-Text([string]$path,[string]$text){[IO.Directory]::CreateDirectory((Split-Path $path))|Out-Null;[IO.File]::WriteAllText($path,$text,$utf8)}
Write-Text (Join-Path $user '.synthetic-profile.json') '{"Synthetic":true,"Fixture":"english-dlc"}'
foreach($name in @('en_dlc.lua','en_dlc_format.lua','en_index.lua','en_indexed_translator.lua','rymcp_dlc.lua','scheme_data.lua','pc_probe_greek_proxy.lua','en_distance.lua')){
 $source=Join-Path $repo ('config/'+$Profile+'/lua/'+$name)
 if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination (Join-Path $user ('lua/'+$name))}
}
Write-Text (Join-Path $user 'rime.lua') "en_dlc_test = require('en_dlc_test')`n"
Write-Text (Join-Path $user 'lua/en_dlc_test.lua') @'
local english = require('en_indexed_translator')
local M = {init=english.init, fini=english.fini}
function M.func(input, seg, env)
  english.func(input, seg, env, env.engine.context:get_option('synthetic_cn'))
end
return M
'@
Write-Text (Join-Path $user 'default.yaml') "config_version: '1'`nschema_list:`n  - schema: en_dlc_synthetic`n"
Write-Text (Join-Path $user 'en_dlc_synthetic.schema.yaml') @'
schema:
  schema_id: en_dlc_synthetic
  name: English DLC synthetic
  version: '1'
engine:
  processors: [speller, selector, navigator, express_editor]
  segmentors: [abc_segmentor, fallback_segmentor]
  translators: [lua_translator@en_dlc_test]
speller:
  alphabet: abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'-
  delimiter: " "
translator:
  dictionary: en_dlc_synthetic
english_native:
  dictionary: en_dlc_synthetic
  user_dict: pc_english
  enable_user_dict: true
  enable_encoder: false
  enable_sentence: false
'@
Write-Text (Join-Path $user 'en_dlc_synthetic.dict.yaml') "---`nname: en_dlc_synthetic`nversion: '1'`nsort: by_weight`nuse_preset_vocabulary: false`n...`ncatalogbase`tcatalogbase`t50`nhello`thello`t30`nordinary`tordinary`t20`n"
function Delete-Keys([string]$word){
 $prefix=$word.Substring(0,[Math]::Min(7,$word.Length))
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);[void]$seen.Add($prefix);$front=@($prefix)
 for($depth=0;$depth -lt 2;$depth++){$next=@();foreach($value in $front){for($i=0;$i -lt $value.Length;$i++){$key=$value.Remove($i,1);if($seen.Add($key)){$next+=,$key}}};$front=$next}
 return ,$seen
}
function Write-Index([string]$directory,[string[]]$words){
 [IO.Directory]::CreateDirectory($directory)|Out-Null
 Write-Text (Join-Path $directory 'words.txt') (($words -join "`n")+$(if($words.Count){"`n"}else{''}))
 $posting=@{};for($i=0;$i -lt $words.Count;$i++){foreach($key in (Delete-Keys $words[$i])){if(-not $posting.ContainsKey($key)){$posting[$key]=[Collections.Generic.List[int]]::new()};$posting[$key].Add($i+1)}}
 $keys=[IO.BinaryWriter]::new([IO.File]::Create((Join-Path $directory 'keys.bin')))
 $ids=[IO.BinaryWriter]::new([IO.File]::Create((Join-Path $directory 'postings.bin')))
 try{foreach($key in @($posting.Keys|Sort-Object -CaseSensitive)){$bytes=[Text.Encoding]::ASCII.GetBytes($key);$keys.Write($bytes);$keys.Write([byte[]]::new(8-$bytes.Length));$keys.Write([uint32]$ids.BaseStream.Position);$keys.Write([uint32]$posting[$key].Count);foreach($id in $posting[$key]){$ids.Write([uint32]$id)}}}finally{$keys.Dispose();$ids.Dispose()}
}
Write-Index (Join-Path $user 'english_index') @('catalogbase','hello','ordinary')
Write-Text (Join-Path $user 'english_index/vocabulary.tsv') "catalogbase`t50`nhello`t30`nordinary`t20`n"
Write-Index (Join-Path $user 'english_extensions') @()
Write-Text (Join-Path $user 'english_extensions/entries.tsv') ''
Write-Text (Join-Path $user 'english_extensions/case_forms.tsv') ''
function Adler([byte[]]$bytes){[long]$a=1;[long]$b=0;foreach($value in $bytes){$a=($a+$value)%65521;$b=($b+$a)%65521};return ('{0:x8}' -f (($b -shl 16)+$a))}
function Install-Pack([string]$id,[string]$content,[string]$revision='1',[string]$root=$user){
 $dir=Join-Path $root ('rymcp_dlc/'+$id)
 Write-Text (Join-Path $dir 'english.tsv') $content
 $bytes=$utf8.GetBytes($content)
 Write-Text (Join-Path $dir 'manifest.tsv') "format`t1`nid`t$id`nrevision`t$revision`nlanguages`ten`nfile`tenglish.tsv`t$($bytes.Length)`t$(Adler $bytes)`n"
 $aliases=@($content -split "`n"|Where-Object {$_ -match '^(word|alias)\t'}|ForEach-Object {($_ -split "`t")[1]}|Sort-Object -Unique -CaseSensitive)
 Write-Index (Join-Path $dir 'english_index') $aliases
}
function Remove-Pack([string]$id){
 $path=[IO.Path]::GetFullPath((Join-Path $user ('rymcp_dlc/'+$id)))
 if(-not $path.StartsWith(($user+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid synthetic package path.'}
 if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse}
}
$math="format`t1`nword`tcatalogdlc`tcatalogdlc`tcatalogdlc`t-`t10`t1`t-`t-`nword`tcatalogoverlap`tcatalogoverlap`tcatalogoverlap`t-`t100`t1`t-`t-`nword`tcatalogbase`tcatalogbase`tcatalogbase`t-`t10000`t1`t-`t-`nalias`tdlcproper`tdlcproper`tdlcproper`tDlcProper`t80`t0`t-`t-`nalias`tdlpalias`tdlcproper`tdlcproper`tDlcProper`t80`t0`t-`t-`n"
$physics="format`t1`nword`tcatalogoverlap`tcatalogoverlap`tcatalogoverlap`t-`t900`t1`t-`t-`nword`tcatalogrival`tcatalogrival`tcatalogrival`t-`t200`t1`t-`t-`n"
$dll=[IO.Path]::GetFullPath($EngineDll);$env:PATH=(Split-Path $dll)+';'+$env:PATH
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs')).Replace('__RIME_ENGINE_DLL__',$dll))
$traits=[RimeProbe+Traits]::new();$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
foreach($pair in @(@('user_data_dir',$user),@('shared_data_dir',$shared),@('log_dir',$logs),@('prebuilt_data_dir',(Join-Path $user 'build')),@('staging_dir',(Join-Path $user 'build')),@('app_name','rime.english_dlc_synthetic'))){$traits.($pair[0])=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($pair[1])}
$traits.min_log_level=2;$script:session=[UIntPtr]::Zero;$script:initialized=$false
$checks=[Collections.Generic.List[object]]::new();$failure=$null
function Check([string]$id,[bool]$ok){$checks.Add([pscustomobject]@{Id=$id;Passed=$ok});if(-not $ok){throw ('English DLC synthetic check failed: '+$id)}}
function Close-Session{if($script:session -ne [UIntPtr]::Zero){[void][RimeProbe]::RimeDestroySession($script:session);$script:session=[UIntPtr]::Zero}}
function Open-Session{
 Close-Session;$script:session=[RimeProbe]::RimeCreateSession()
 Check 'schema-selected' ([RimeProbe]::RimeSelectSchema($script:session,'en_dlc_synthetic') -ne 0)
}
function Start-Engine{[RimeProbe]::RimeInitialize([ref]$traits);$script:initialized=$true}
function Close-Engine{Close-Session;if($script:initialized){[RimeProbe]::RimeFinalize();$script:initialized=$false}}
function Redeploy{
 Close-Engine;Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits)
 Check 'deploy-api' ([RimeProbe]::RimeDeployWorkspace() -ne 0)
 Close-Engine;Start-Engine;Open-Session
}
function Query([string]$raw,[bool]$cn=$false){
 [RimeProbe]::RimeClearComposition($script:session);[void][RimeProbe]::ReadCommit($script:session)
 [RimeProbe]::RimeSetOption($script:session,'synthetic_cn',[int]$cn)
 foreach($ch in $raw.ToCharArray()){[void][RimeProbe]::RimeProcessKey($script:session,[int]$ch,0);[void][RimeProbe]::RimeProcessKey($script:session,[int]$ch,0x40000000)}
 $snapshot=[RimeProbe]::Snapshot($script:session,100)
 Check 'query-no-commit' ([string]::IsNullOrEmpty([RimeProbe]::ReadCommit($script:session)))
 return $snapshot
}
function Select-Word([string]$raw,[string]$target,[bool]$cn=$false){
 $snapshot=Query $raw $cn;$index=[Array]::IndexOf([string[]]$snapshot.Candidates,$target)
 Check 'synthetic-target-present' ($index -ge 0)
 Check 'synthetic-target-selected' ([RimeProbe]::SelectCandidate($script:session,$index) -ne 0)
 Check 'synthetic-commit' ([RimeProbe]::ReadCommit($script:session) -ceq $target)
}
function Learning-Rows([string]$name){
 Close-Engine;Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits)
 $path=Join-Path $out ($name+'.tsv');Check 'synthetic-learning-export' ([RimeProbe]::ExportUserDict('pc_english',$path) -gt 0)
 $rows=@([IO.File]::ReadAllLines($path,$utf8)|Where-Object {$_ -and -not $_.StartsWith('#')})
 Close-Engine;Start-Engine;Open-Session
 return ,$rows
}
try{
 [RimeProbe]::RimeSetup([ref]$traits);Redeploy
 Check 'neutral-base' (@((Query 'catalog').Candidates) -contains 'catalogbase')
 Check 'neutral-dlc-absent' (@((Query 'dlcp').Candidates) -notcontains 'DlcProper')
 Install-Pack 'math' $math;Install-Pack 'physics' $physics
 Redeploy
 $snapshot=Query 'catalog'
 Check 'all-installed-words' (@($snapshot.Candidates|Where-Object {$_ -cmatch '^catalog(base|dlc|overlap|rival)$'}).Count -eq 4)
 Check 'overlap-one-candidate' (@($snapshot.Candidates|Where-Object {$_ -ceq 'catalogoverlap'}).Count -eq 1)
 Check 'fixed-source-priority' ([Array]::IndexOf([string[]]$snapshot.Candidates,'catalogrival') -lt [Array]::IndexOf([string[]]$snapshot.Candidates,'catalogoverlap'))
 Check 'base-weight-preserved' ([Array]::IndexOf([string[]]$snapshot.Candidates,'catalogbase') -gt [Array]::IndexOf([string[]]$snapshot.Candidates,'catalogoverlap'))
 Check 'new-word-title-case' (@((Query 'Catalogdlc').Candidates) -ccontains 'Catalogdlc')
 Check 'new-word-upper-case' (@((Query 'CATALOGDLC').Candidates) -ccontains 'CATALOGDLC')
 Check 'new-word-correction' (@((Query 'catalogdcl').Candidates) -ccontains 'catalogdlc')
 Remove-Item -LiteralPath (Join-Path $user 'rymcp_dlc/math/english_index/keys.bin')
 Redeploy
 Check 'old-english-module-keeps-exact-match' (@((Query 'catalogdlc').Candidates) -ccontains 'catalogdlc')
 Check 'missing-index-skips-only-english-correction' (@((Query 'catalogdcl').Candidates) -cnotcontains 'catalogdlc')
 Install-Pack 'math' $math;Redeploy
 Check 'prebuilt-index-restores-english-correction' (@((Query 'catalogdcl').Candidates) -ccontains 'catalogdlc')
 Check 'canonical-name' (@((Query 'dlcp').Candidates) -ccontains 'DlcProper')
 Check 'canonical-alias' (@((Query 'dlpalias').Candidates) -ccontains 'DlcProper')
 Check 'cn-short-prefix-gated' (@((Query 'dl' $true).Candidates) -cnotcontains 'DlcProper')
 Check 'cn-prefix-enabled' (@((Query 'dlcp' $true).Candidates) -ccontains 'DlcProper')
 Select-Word 'dlcproper' 'DlcProper';Select-Word 'dlpalias' 'DlcProper'
 Select-Word 'dlcproper' 'DlcProper' $true
 Select-Word 'Catalogdlc' 'Catalogdlc'
 $before=Learning-Rows 'learning-before'
 $proper=@($before|Where-Object {$_ -cmatch '^dlcproper\tdlcproper\t'})
 Check 'one-canonical-learning-record' ($proper.Count -eq 1)
 Check 'learning-count-three-across-modes' ($proper.Count -eq 1 -and ($proper[0] -cmatch '\t3$'))
 Check 'ordinary-case-learning-canonical' (@($before|Where-Object {$_ -cmatch '^catalogdlc\tcatalogdlc\t1$'}).Count -eq 1)
 Remove-Pack 'math';Redeploy
 Check 'uninstalled-static-and-learned-only-gone' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
 Check 'other-module-remains' (@((Query 'catalog').Candidates) -ccontains 'catalogrival')
 Check 'shared-identity-remains' (@((Query 'catalog').Candidates) -ccontains 'catalogoverlap')
 $after=Learning-Rows 'learning-after'
 Check 'learning-preserved' (($before -join "`n") -ceq ($after -join "`n"))
 Install-Pack 'math' $math;Redeploy
 Check 'reinstall-canonical-recalled' (@((Query 'dlcp').Candidates) -ccontains 'DlcProper')
 $restored=Learning-Rows 'learning-restored';Check 'reinstall-keeps-learning' (($before -join "`n") -ceq ($restored -join "`n"))
 $updated=$math.Replace('catalogdlc','catalognew')
 Install-Pack 'math' $updated '2';Redeploy
 Check 'same-path-update-new' (@((Query 'catalog').Candidates) -ccontains 'catalognew')
 Check 'same-path-update-old-gone' (@((Query 'catalog').Candidates) -cnotcontains 'catalogdlc')
 Install-Pack 'math' $math
 Write-Text (Join-Path $user 'rymcp_dlc/math/english.tsv') ($math+'incomplete')
 Redeploy
 Check 'malformed-data-whole-english-module-disabled' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
 Check 'bad-module-base-survives' (@((Query 'catalog').Candidates) -ccontains 'catalogbase')
 Install-Pack 'math' ($math.Replace("`t10`t1", "`t0`t1"));Redeploy
 Check 'bad-row-whole-module-disabled' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
 Install-Pack 'math' $math
 $partial=Join-Path $user 'rymcp_dlc/math/manifest.tsv'
 Remove-Item -LiteralPath $partial
 Redeploy
 Check 'missing-manifest-whole-module-disabled' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
 Install-Pack 'math' $math
 Remove-Item -LiteralPath (Join-Path $user 'rymcp_dlc/math/english.tsv')
 Redeploy
 Check 'missing-data-whole-module-disabled' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
 Remove-Pack 'math';Install-Pack 'math' $math '1' $shared;Redeploy
 Check 'shared-only-not-loaded' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
 Install-Pack 'math' $math;Redeploy
 Check 'redeploy-installs-optional-english-module' (@((Query 'dlcp').Candidates) -ccontains 'DlcProper')
 Remove-Pack 'math';Redeploy
 Check 'redeploy-removes-optional-english-module' (@((Query 'dlcp').Candidates) -cnotcontains 'DlcProper')
}catch{$failure=$_.Exception.Message}finally{Close-Engine}
$result=[ordered]@{Completed=($null -eq $failure);Passed=@($checks|Where-Object Passed).Count;Failed=@($checks|Where-Object {-not $_.Passed}).Count;Error=$failure;SyntheticOnly=$true;Profile=$Profile;Checks=$checks.ToArray()}
[IO.File]::WriteAllText((Join-Path $out 'results.json'),($result|ConvertTo-Json -Depth 6),$utf8)
[pscustomobject]@{Completed=$result.Completed;Passed=$result.Passed;Failed=$result.Failed;Error=$failure}|ConvertTo-Json
if(-not $result.Completed -or $result.Failed){exit 1}
