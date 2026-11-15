# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$BaselineCpp,
  [Parameter(Mandatory)][string]$CandidateCpp,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh finite test directory.'}
& python (Join-Path $PSScriptRoot 'Prepare-NotificationTests.py') --baseline-cpp $BaselineCpp --candidate-cpp $CandidateCpp --output-dir $OutputDirectory
if($LASTEXITCODE){throw 'Production method extraction failed.'}
$reports=@()
foreach($variant in @('baseline','patched')){
  $folder=Join-Path $OutputDirectory $variant
  $exe=Join-Path $folder 'NotificationTests.exe'
  $obj=Join-Path $folder 'NotificationTests.obj'
  & cl.exe /nologo /std:c++17 /EHsc /W4 /utf-8 /D_SILENCE_CXX17_CODECVT_HEADER_DEPRECATION_WARNING "/I$folder" (Join-Path $PSScriptRoot 'NotificationTests.cpp') "/Fe$exe" "/Fo$obj" 2>&1 | Tee-Object -FilePath (Join-Path $folder 'compile.log')
  if($LASTEXITCODE){throw "Notification fixture compilation failed: $variant"}
  $text=(& $exe 2>&1|Out-String).Replace("`r",'')
  $exit=$LASTEXITCODE
  [IO.File]::WriteAllText((Join-Path $folder 'result.txt'),$text,[Text.UTF8Encoding]::new($false))
  $match=[regex]::Match($text,'(?m)^RESULT passed=([0-9]+) failed=([0-9]+)$')
  if(-not $match.Success){throw 'Missing finite notification result.'}
  $passed=[int]$match.Groups[1].Value
  $failed=[int]$match.Groups[2].Value
  if($variant -ceq 'baseline'){
    if($exit -eq 0 -or $failed -ne 17 -or $passed -ne 30){throw 'The baseline did not reproduce the expected notification loss.'}
  }elseif($exit -ne 0 -or $failed -ne 0 -or $passed -ne 47){throw 'The proposed notification fix did not pass.'}
  $reports+=[ordered]@{Variant=$variant;ExitCode=$exit;PassedCases=$passed;FailedCases=$failed}
}
$record=[ordered]@{Passed=$true;Compiler='MSVC C++17';BaselineFailureReproduced=$true;PatchedChecks=47;Variants=$reports;Methods=@('ProcessKeyEvent','OnNotify','_ShowMessage','_UpdateUI notification reset');PhysicalKeyboardTested=$false;ProductServerStarted=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'results.json'),($record|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$record|ConvertTo-Json -Depth 6
