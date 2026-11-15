# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$SourceRoot,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [string]$BaselineCpp,
  [string]$BaselineHeader
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh finite test output directory.'}
if([bool]$BaselineCpp -ne [bool]$BaselineHeader){throw 'Provide both baseline source paths or neither.'}
$prepare=@('--source-root',$SourceRoot,'--output-dir',$OutputDirectory)
$variants=@('patched')
if($BaselineCpp){$prepare+=@('--baseline-cpp',$BaselineCpp,'--baseline-header',$BaselineHeader);$variants=@('baseline','patched')}
& python (Join-Path $PSScriptRoot 'Prepare-ModeIconTests.py') @prepare
if($LASTEXITCODE){throw 'Production mode-icon code extraction failed.'}
$reports=@()
foreach($variant in $variants){
  $folder=Join-Path $OutputDirectory $variant
  $exe=Join-Path $folder 'ModeIconTests.exe'
  $obj=Join-Path $folder 'ModeIconTests.obj'
  & cl.exe /nologo /std:c++17 /EHsc /W4 /utf-8 "/I$folder" (Join-Path $PSScriptRoot 'ModeIconTests.cpp') "/Fe$exe" "/Fo$obj" 2>&1|Tee-Object -FilePath (Join-Path $folder 'compile.log')
  if($LASTEXITCODE){throw "Mode-icon fixture compilation failed: $variant"}
  $scratch=Join-Path $folder 'synthetic-files'
  $text=(& $exe $scratch 2>&1|Out-String).Replace("`r",'')
  $exit=$LASTEXITCODE
  [IO.File]::WriteAllText((Join-Path $folder 'result.txt'),$text,[Text.UTF8Encoding]::new($false))
  $match=[regex]::Match($text,'(?m)^RESULT passed=([0-9]+) failed=([0-9]+)$')
  if(-not $match.Success){throw 'Missing bounded mode-icon result.'}
  $passed=[int]$match.Groups[1].Value;$failed=[int]$match.Groups[2].Value
  if($variant -ceq 'baseline'){
    if($exit -eq 0 -or $failed -ne 14 -or $passed -ne 35){throw 'Baseline did not reproduce missing mode icons.'}
  }elseif($exit -ne 0 -or $failed -ne 0 -or $passed -ne 49){throw 'Proposed mode-icon overlay did not pass.'}
  $reports+=[ordered]@{Variant=$variant;ExitCode=$exit;PassedCases=$passed;FailedCases=$failed}
}
$record=[ordered]@{Passed=$true;Compiler='MSVC C++17';BaselineFailureReproduced=[bool]$BaselineCpp;PassedCases=$reports[-1].PassedCases;PatchedChecks=$reports[-1].PassedCases;Variants=$reports;Methods=@('ApplyModeStyle','LoadSchemaIcon','_LoadSchemaSpecificSettings mode overlay block');MetadataCopyPatternVerified=$true;AsciiModeUnchanged=$true;PhysicalKeyboardTested=$false;ProductServerStarted=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'results.json'),($record|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$record|ConvertTo-Json -Depth 6
