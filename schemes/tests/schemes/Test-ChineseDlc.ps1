# SPDX-License-Identifier: GPL-3.0-only
# Fixed synthetic dictionaries and learning only, in a fresh output directory.
param(
  [Parameter(Mandatory=$true)][string]$EngineDll,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [switch]$Guarded=$true,
  [switch]$BadPatchFirst
)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'Use a fresh output directory.'}
$user=Join-Path $out 'user';$shared=Join-Path $out 'shared';$logs=Join-Path $out 'logs'
foreach($dir in @($user,$shared,$logs,(Join-Path $user 'build'))){[IO.Directory]::CreateDirectory($dir)|Out-Null}
function Write-Text([string]$path,[string]$value){[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllText($path,$value,$utf8)}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$dll=[IO.Path]::GetFullPath($EngineDll)
$env:PATH=(Split-Path $dll -Parent)+';'+$env:PATH
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs'),$utf8).Replace('__RIME_ENGINE_DLL__',$dll))
$ids=@('math','physics','computer','poetry')
$codes=@('a ba','a ca','a da','a fa')
$words=@();foreach($cp in @(0x7532,0x4e59,0x4e19,0x4e01)){$words+=(([string][char]$cp)*2)}
$overlapWord=([string][char]0x91cd)*2
Write-Text (Join-Path $user 'rime.lua') ''
if($Guarded){
 foreach($name in @('rymcp_dlc.lua','cn_dlc.lua','en_dlc_format.lua')){Write-Text (Join-Path $user ('lua/'+$name)) ([IO.File]::ReadAllText((Join-Path $repo ('config/pc/lua/'+$name)),$utf8))}
 Write-Text (Join-Path $user 'rime.lua') @'
dlc_synthetic = {
  init = function(env)
    require('cn_dlc').configure(env.engine.schema.config)
    env.native = assert(Component.Translator(env.engine, '', 'script_translator@translator'))
  end,
  func = function(input, seg, env)
    local translation = env.native:query(input, seg)
    if translation then for candidate in translation:iter() do yield(candidate) end end
  end,
  fini = function(env) env.native = nil end,
}
'@
}
Write-Text (Join-Path $user 'default.yaml') "config_version: '1'`nschema_list:`n  - schema: dlc_synthetic`n"
$schema=@'
schema:
  schema_id: dlc_synthetic
  name: DLC synthetic
  version: '1'
engine:
  processors: [speller, selector, navigator, express_editor]
  segmentors: [abc_segmentor, fallback_segmentor]
  translators: [script_translator]
  filters: [uniquifier]
speller:
  alphabet: abcdefghijklmnopqrstuvwxyz
  delimiter: " '"
translator:
  dictionary: dlc_synthetic
  user_dict: dlc_synthetic
  packs: []
  enable_completion: false
  enable_sentence: false
__patch:
  - rymcp_dlc/math/words.dict:/patch?
  - rymcp_dlc/physics/words.dict:/patch?
  - rymcp_dlc/computer/words.dict:/patch?
  - rymcp_dlc/poetry/words.dict:/patch?
'@
Write-Text (Join-Path $user 'dlc_synthetic.schema.yaml') ($schema+"`n")
if($Guarded){Write-Text (Join-Path $user 'dlc_synthetic.schema.yaml') ($schema.Replace('translators: [script_translator]','translators: [lua_translator@dlc_synthetic]')+"`n")}
Write-Text (Join-Path $user 'dlc_synthetic.dict.yaml') "---`nname: dlc_synthetic`nversion: '1'`nsort: by_weight`nuse_preset_vocabulary: false`n...`n$([char]0x4e00)`ta`t100`n$([char]0x4e8c)`tba`t100`n$([char]0x4e09)`tca`t100`n$([char]0x56db)`tda`t100`n$([char]0x4e94)`tfa`t100`n"
foreach($id in $ids){Write-Text (Join-Path $user ('rymcp_dlc_'+$id+'.dict.yaml')) "---`nname: rymcp_dlc_$id`nversion: '1'`nsort: by_weight`nuse_preset_vocabulary: false`nimport_tables:`n  - rymcp_dlc/$id/words`n...`n"}
function Module-Text([int]$index,[string]$text=''){
 $id=$ids[$index];if(-not $text){$text=$words[$index]}
 $rows="$text`t$($codes[$index])`t100`n"
 if($index -lt 2){$rows+="$overlapWord`tba ca`t100`n"}
 return "---`nname: rymcp_dlc/$id/words`nversion: '1'`nsort: by_weight`nuse_preset_vocabulary: false`npatch:`n  translator/packs/+:`n    - rymcp_dlc_$id`n...`n$rows"
}
function Adler32([byte[]]$data){
 [long]$a=1;[long]$b=0
 foreach($value in $data){$a=($a+$value)%65521;$b=($b+$a)%65521}
 return ('{0:x8}' -f [long]($b*65536+$a))
}
function Write-Module([int]$index,[string]$text=''){
 $directory=Join-Path $user ('rymcp_dlc/'+$ids[$index])
 $value=Module-Text $index $text
 Write-Text (Join-Path $directory 'words.dict.yaml') $value
 if($Guarded){$bytes=$utf8.GetBytes($value);Write-Text (Join-Path $directory 'manifest.tsv') "format`t1`nid`t$($ids[$index])`nrevision`t1`nlanguages`tcn`nfile`twords.dict.yaml`t$($bytes.Length)`t$(Adler32 $bytes)`n"}
}
$traits=New-Object RimeProbe+Traits
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
foreach($pair in @(@('shared_data_dir',$shared),@('user_data_dir',$user),@('prebuilt_data_dir',(Join-Path $user 'build')),@('staging_dir',(Join-Path $user 'build')),@('log_dir',$logs),@('app_name','rime.dlc_synthetic'))){$traits.($pair[0])=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($pair[1])}
$traits.min_log_level=2
$script:session=[UIntPtr]::Zero;$script:initialized=$false
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$id,[bool]$passed,$actual=$null){$checks.Add([pscustomobject]@{Id=$id;Passed=$passed;Actual=$actual});if(-not $passed){throw ('DLC synthetic check failed: '+$id)}}
function Close-Engine{if($script:initialized){[RimeProbe]::RimeFinalize();$script:initialized=$false;$script:session=[UIntPtr]::Zero}}
function Start-Engine{[RimeProbe]::RimeInitialize([ref]$traits);$script:initialized=$true}
function Redeploy{
 Close-Engine;Start-Engine
 [RimeProbe]::RimeDeployerInitialize([ref]$traits)
 $ok=[RimeProbe]::RimeDeployWorkspace();Check 'deploy-api' ($ok -ne 0)
 Close-Engine;Start-Engine
 $script:session=[RimeProbe]::RimeCreateSession();Check 'schema-select' ([RimeProbe]::RimeSelectSchema($script:session,'dlc_synthetic') -ne 0)
}
function Query([string]$code){[RimeProbe]::RimeClearComposition($script:session);foreach($c in $code.Replace(' ','').ToCharArray()){[void][RimeProbe]::RimeProcessKey($script:session,[int]$c,0)};return [RimeProbe]::Snapshot($script:session,100)}
$errorText=$null;$boundary=$null
try{
 [RimeProbe]::RimeSetup([ref]$traits)
 if($BadPatchFirst){
  Write-Text (Join-Path $user 'rymcp_dlc/math/words.dict.yaml') "---`nname: rymcp_dlc/math/words`nversion: '1'`nsort: by_weight`nuse_preset_vocabulary: false`npatch: []`n...`n$($words[0])`ta ba`t100`n"
  Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits)
  $badResult=[RimeProbe]::RimeDeployWorkspace()
  $boundary=[ordered]@{BadPatchDeployApi=$badResult;CompiledSchemaExists=(Test-Path -LiteralPath (Join-Path $user 'build/dlc_synthetic.schema.yaml'));Expected='Malformed native patch may reject schema linking; remove the module and redeploy.'}
  Close-Engine
  Remove-Item -LiteralPath (Join-Path $user 'rymcp_dlc/math/words.dict.yaml')
 }
 Redeploy
 Check 'neutral-no-module' (@((Query 'a ba').Candidates) -notcontains $words[0])
 for($i=0;$i -lt 4;$i++){Write-Module $i}
 Redeploy
 for($i=0;$i -lt 4;$i++){Check ('coexist-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 Check 'overlap-shown-once' (@((Query 'ba ca').Candidates|Where-Object { $_ -ceq $overlapWord }).Count -eq 1)
 $revised=([string][char]0x620a)*2
 Write-Module 0 $revised
 Redeploy
 $snapshot=Query $codes[0]
 Check 'update-new-word' (@($snapshot.Candidates) -contains $revised)
 Check 'update-old-word-gone' (@($snapshot.Candidates) -notcontains $words[0])
 $index=[Array]::IndexOf([string[]]$snapshot.Candidates,$revised)
 Check 'learn-select' ([RimeProbe]::SelectCandidate($script:session,$index) -ne 0)
 [void][RimeProbe]::RimeCommitComposition($script:session)
 [void][RimeProbe]::ReadCommit($script:session)
 Close-Engine;Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits)
 $before=Join-Path $out 'synthetic-learning-before.tsv'
 Check 'learning-export-before' ([RimeProbe]::ExportUserDict('dlc_synthetic',$before) -gt 0)
 Close-Engine
 $math=Join-Path $user 'rymcp_dlc/math'
 if(-not ([IO.Path]::GetFullPath($math)).StartsWith(($user+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid synthetic module path.'}
 Remove-Item -LiteralPath $math -Recurse
 Redeploy
 Check 'uninstall-cache-retained' (Test-Path -LiteralPath (Join-Path $user 'build/rymcp_dlc_math.table.bin'))
 $compiled=[IO.File]::ReadAllText((Join-Path $user 'build/dlc_synthetic.schema.yaml'),$utf8)
 Check 'uninstall-schema-excludes-pack' (-not $compiled.Contains('- rymcp_dlc_math'))
 for($i=1;$i -lt 4;$i++){Check ('uninstall-others-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 Check 'uninstall-retains-overlapping-other-pack' (@((Query 'ba ca').Candidates) -contains $overlapWord)
 Close-Engine;Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits)
 $after=Join-Path $out 'synthetic-learning-after.tsv'
 Check 'learning-export-after' ([RimeProbe]::ExportUserDict('dlc_synthetic',$after) -gt 0)
 $beforeRows=@([IO.File]::ReadAllLines($before,$utf8)|Where-Object { -not $_.StartsWith('#') -and $_ })
 $afterRows=@([IO.File]::ReadAllLines($after,$utf8)|Where-Object { -not $_.StartsWith('#') -and $_ })
 Check 'learning-preserved' (($beforeRows -join "`n") -ceq ($afterRows -join "`n"))
 Close-Engine
 Write-Module 0 $revised
 Redeploy
 Check 'reinstall-learned-word' (@((Query $codes[0]).Candidates) -contains $revised)
 # The same file supplies activation and data. Missing/malformed headers must
 # not leave a separately active pack with a missing imported source.
 Close-Engine
 Remove-Item -LiteralPath (Join-Path $user 'rymcp_dlc/math/words.dict.yaml')
 Redeploy
 for($i=1;$i -lt 4;$i++){Check ('missing-others-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 Close-Engine
 Write-Text (Join-Path $user 'rymcp_dlc/math/words.dict.yaml') "---`nname: [`n"
 Redeploy
 for($i=1;$i -lt 4;$i++){Check ('malformed-header-others-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 Close-Engine
 Write-Text (Join-Path $user 'rymcp_dlc/math/words.dict.yaml') "---`npatch:`n  translator/packs/+: [rymcp_dlc_math]`n...`n"
 Redeploy
 for($i=1;$i -lt 4;$i++){Check ('incomplete-header-others-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 if($Guarded){
  Close-Engine
  Write-Module 0
  Remove-Item -LiteralPath (Join-Path $user 'rymcp_dlc/math/manifest.tsv')
  Redeploy
  Check 'missing-manifest-disables-whole-module' (@((Query $codes[0]).Candidates) -notcontains $words[0])
  Close-Engine
  Write-Module 0
  [IO.File]::AppendAllText((Join-Path $user 'rymcp_dlc/math/words.dict.yaml'),"# corrupt checksum`n",$utf8)
  Redeploy
  Check 'checksum-mismatch-disables-whole-module' (@((Query $codes[0]).Candidates) -notcontains $words[0])
  Close-Engine
  Write-Module 0
  $manifest=Join-Path $user 'rymcp_dlc/math/manifest.tsv'
  [IO.File]::AppendAllText($manifest,"file`trequired.txt`t1`t00000000`n",$utf8)
  Redeploy
  Check 'missing-required-file-disables-whole-module' (@((Query $codes[0]).Candidates) -notcontains $words[0])
  Close-Engine
  Write-Module 0
  $manifest=Join-Path $user 'rymcp_dlc/math/manifest.tsv'
  $english="format`t1`nword`tcnmixedenglish`tcnmixedenglish`tcnmixedenglish`t-`t100`t2`t-`t-`n"
  Write-Text (Join-Path $user 'rymcp_dlc/math/english.tsv') $english
  $bytes=$utf8.GetBytes($english)
  $content=[IO.File]::ReadAllText($manifest,$utf8).Replace("languages`tcn`n","languages`tcn,en`n")+"file`tenglish.tsv`t$($bytes.Length)`t$(Adler32 $bytes)`n"
  Write-Text $manifest $content
  Redeploy
  Check 'bad-english-disables-cn-in-whole-module' (@((Query $codes[0]).Candidates) -notcontains $words[0])
  Close-Engine
  $english=$english.Replace("`t2`t-`t-`n","`t1`t-`t-`n")
  Write-Text (Join-Path $user 'rymcp_dlc/math/english.tsv') $english
  $bytes=$utf8.GetBytes($english)
  $content=$content -replace '(?m)^file\tenglish.tsv\t[^\r\n]+',("file`tenglish.tsv`t$($bytes.Length)`t$(Adler32 $bytes)")
  Write-Text $manifest $content
  Redeploy
  Check 'valid-cn-and-english-module-activates' (@((Query $codes[0]).Candidates) -contains $words[0])
  Close-Engine
  Write-Module 0
  $source=Join-Path $user 'rymcp_dlc/math';$target=Join-Path $shared 'rymcp_dlc/math'
  [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
  Copy-Item -LiteralPath $source -Destination $target -Recurse
  if(-not ([IO.Path]::GetFullPath($source)).StartsWith(($user+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid synthetic module path.'}
  Remove-Item -LiteralPath $source -Recurse
  Redeploy
  Check 'shared-copy-does-not-reactivate-module' (@((Query $codes[0]).Candidates) -notcontains $words[0])
  for($i=1;$i -lt 4;$i++){Check ('shared-others-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 }
 Check 'flat-cache-layout' (Test-Path -LiteralPath (Join-Path $user 'build/rymcp_dlc_physics.table.bin'))
}catch{$errorText=$_.Exception.Message}finally{Close-Engine;@{Format='cn-dlc-native-layout-v1';Guarded=[bool]$Guarded;Boundary=$boundary;Completed=($null -eq $errorText);Error=$errorText;Checks=@($checks)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8}
if($errorText){throw $errorText}
Write-Output ('CN DLC native layout: '+$checks.Count+' checks passed.')
