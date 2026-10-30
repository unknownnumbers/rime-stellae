# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param(
  [Parameter(Mandatory)][string]$SourceRoot,
  [Parameter(Mandatory)][string]$SharedData,
  [Parameter(Mandatory)][string]$RuntimeN01,
  [ValidateSet('x64','Win32')][string]$Architecture='x64'
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or -not $IsWindows){throw 'Use a disposable Windows hosted runner.'}
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
$output=Join-Path $source 'output'
$logs=Join-Path $source 'ci-logs'
$null=New-Item -ItemType Directory -Path $logs -Force
$stem='controlled-keys-'+$Architecture.ToLowerInvariant()
$reportPath=Join-Path $logs ($stem+'.json')
$utf8=[Text.UTF8Encoding]::new($false)
$report=[ordered]@{SourceVersion='0.17.4.61052';SourceCommit=$env:GITHUB_SHA;Architecture=$Architecture;EmptyRuntime=$(if($Architecture -eq 'x64'){'N01 x64'}else{'R5 x86'});RegressionRuntime=$(if($Architecture -eq 'x64'){'R5 x64'}else{'R5 x86'});Scope='Empty-scheme pass-through and R2/V13/V18/V19 production callbacks with controlled COM host and real IPC';NativeAcpClaimed=$false;PhysicalKeyboardDispatcherUsed=$false;Passed=$false;Probes=@();SourceRestored=$false;ProductOutputRestored=$false;Errors=@();RestoreErrors=@()}
$sourceFiles=@{};$productFiles=@{};$added=@();$server=$null;$child=$null
$registry='HKCU:\Software\RimeStellae'
$oldUser=Get-ItemProperty -LiteralPath $registry -Name RimeUserDir -ErrorAction SilentlyContinue
foreach($name in @('Composition.cpp','WeaselTSF.def','EditSession.cpp','KeyEventSink.cpp')){
  $path=Join-Path $source ('WeaselTSF/'+$name)
  $sourceFiles[$path]=[IO.File]::ReadAllBytes($path)
}
foreach($name in @('stellae','stellaex64')){foreach($extension in @('dll','pdb','lib','exp')){
  $path=Join-Path $output "$name.$extension"
  $productFiles[$path]=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllBytes($path)}else{$null}
}}
$r5Engine=Join-Path $output 'rime.dll'
$productFiles[$r5Engine]=[IO.File]::ReadAllBytes($r5Engine)
$serverDirectory=if($Architecture -eq 'x64'){$output}else{Join-Path $output 'Win32'}
function Run-Probe([string]$Mode,[string]$Group,[int]$Checks){
  $trace=Join-Path $logs "$stem-$Mode.txt"
  $stderr=Join-Path $logs "$stem-$Mode-stderr.txt"
  $system=if($Architecture -eq 'x64'){'System32'}else{'SysWOW64'}
  $shell=Join-Path $env:WINDIR "$system/WindowsPowerShell/v1.0/powershell.exe"
  $dll=Join-Path $output $(if($Architecture -eq 'x64'){'stellaex64.dll'}else{'stellae.dll'})
  $arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Invoke-KeyPairingTests.ps1')+'" -DllPath "'+$dll+'" -EvidencePath "'+$trace+'" -Probe '+$Mode
  $script:child=Start-Process -FilePath $shell -ArgumentList $arguments -WorkingDirectory $output -WindowStyle Hidden -RedirectStandardError $stderr -PassThru
  $null=$child.Handle
  $timeout=-not $child.WaitForExit(30000)
  if($timeout){$child.Kill();$child.WaitForExit()}
  $text=if(Test-Path -LiteralPath $trace){[IO.File]::ReadAllText($trace).Replace("`r",'')}else{''}
  $errors=if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''}
  $summary=[regex]::Match($text,'(?m)^RESULT passed=([0-9]+) failed=([0-9]+) groups=([0-9]+)$')
  $failures=@([regex]::Matches($text,'(?m)^(FAIL|ERROR|UNREACHED) .*$')|ForEach-Object{$_.Value})
  $passed=-not $timeout -and $child.ExitCode -eq 0 -and $summary.Success -and
    [int]$summary.Groups[1].Value -eq $Checks -and [int]$summary.Groups[2].Value -eq 0 -and
    [int]$summary.Groups[3].Value -eq 1 -and $text.Contains("GROUP $Group PASS") -and $failures.Count -eq 0 -and
    [regex]::Matches($text,'(?m)^PASS .*$').Count -eq $Checks
  $report.Probes+=[ordered]@{Mode=$Mode;Group=$Group;ExpectedChecks=$Checks;Exit=$child.ExitCode;TimedOut=$timeout;Passed=$passed;Result=$summary.Value;Failures=$failures;Trace="ci-logs/$stem-$Mode.txt";Stderr=$errors}
  Write-Output $text
  $script:child=$null
  if(-not $passed){throw "Controlled callback group failed: $Group"}
}
function Deploy([string]$User,[switch]$Empty){
  $name=if($Empty){'empty'}else{'fixture'}
  $arguments=@((Join-Path $PSScriptRoot 'Deploy-PublicFixture.py'),'--engine',(Join-Path $output 'rime.dll'),'--header',(Join-Path $source 'include/rime_api.h'),'--shared',(Resolve-Path $SharedData).Path,'--user',$User,'--logs',(Join-Path $logs "$stem-$name-compiler"),'--report',(Join-Path $logs "$stem-$name-deploy.json"))
  if($Empty){$arguments+='--empty'}
  & python @arguments
  if($LASTEXITCODE){throw "C API deployment failed: $name"}
}
Push-Location $source
try{
  # The clean release products are already frozen by Build-Weasel.
  foreach($mapping in @(@('ResponseOwnerProductTests.cpp','ResponseOwnerProductTests.cpp.inc'),@('ProductHostFixture.h','ProductHostFixture.h'),@('SelectionControlledModes.inc','SelectionControlledModes.inc'),@('ControlledReadGrant.inc','ControlledReadGrant.inc'))){
    $target=Join-Path $source ('WeaselTSF/'+$mapping[1])
    if(Test-Path -LiteralPath $target){throw 'Unexpected test include in clean source.'}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $mapping[0]) -Destination $target
    $added+=$target
  }
  [IO.File]::AppendAllText((Join-Path $source 'WeaselTSF/Composition.cpp'),"`n#include `"ResponseOwnerProductTests.cpp.inc`"`n",$utf8)
  $producer=Join-Path $source 'WeaselTSF/EditSession.cpp'
  $text=[IO.File]::ReadAllText($producer).Replace("`r",'')
  $entry='  const auto outcome = m_client.ProcessKeyEventOutcome(key);'
  if(($text.Split([string[]]@($entry),[StringSplitOptions]::None).Count-1) -ne 1){throw 'Unique real producer entry not found.'}
  [IO.File]::WriteAllText($producer,$text.Replace($entry,"  extern unsigned rymcpRetainedKeyCalls;`n  ++rymcpRetainedKeyCalls;`n"+$entry),$utf8)
  $sink=Join-Path $source 'WeaselTSF/KeyEventSink.cpp'
  $text=[IO.File]::ReadAllText($sink).Replace("`r",'')
  $include='#include "CandidateList.h"'
  if(-not $text.Contains($include)){throw 'Expected key sink include absent.'}
  [IO.File]::WriteAllText($sink,$text.Replace($include,$include+"`nextern UINT WINAPI RymcpValidationCapsSendInput(UINT, LPINPUT, int);`n#define SendInput RymcpValidationCapsSendInput"),$utf8)
  [IO.File]::AppendAllText((Join-Path $source 'WeaselTSF/WeaselTSF.def'),"`n  RunResponseOwnerProductTests`n",$utf8)
  & msbuild weasel.sln /m /t:WeaselTSF /p:Configuration=Release "/p:Platform=$Architecture" /v:minimal 2>&1|Tee-Object (Join-Path $logs "$stem-build.log")
  if($LASTEXITCODE){throw 'Callback fixture build failed.'}
  $user=Join-Path $env:RUNNER_TEMP ($stem+'-'+[guid]::NewGuid().ToString('N'))
  $null=New-Item -ItemType Directory -Path $user
  New-Item -Path $registry -Force|Out-Null
  New-ItemProperty -LiteralPath $registry -Name RimeUserDir -Value $user -PropertyType String -Force|Out-Null
  if($Architecture -eq 'x64'){Copy-Item -LiteralPath $RuntimeN01 -Destination $r5Engine -Force}
  Deploy $user -Empty
  $server=Start-Process -FilePath (Join-Path $serverDirectory 'StellaeServer.exe') -WorkingDirectory $serverDirectory -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 2
  if($server.HasExited){throw 'Empty-scheme service exited.'}
  Run-Probe 'no-schemas' 'EMPTY' 36
  $server.Kill();$server.WaitForExit();$server=$null
  [IO.File]::WriteAllBytes($r5Engine,$productFiles[$r5Engine])
  Copy-Item -Path (Join-Path $PSScriptRoot 'fixture/*.yaml') -Destination $user
  Deploy $user
  $server=Start-Process -FilePath (Join-Path $serverDirectory 'StellaeServer.exe') -WorkingDirectory $serverDirectory -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 2
  if($server.HasExited){throw 'Post-install synthetic-scheme service exited.'}
  Run-Probe 'truthful-key-pairing' 'V13' 45
  Run-Probe 'truthful-key-nested' 'V18' 16
  Run-Probe 'truthful-key-repeat-space' 'V19' 34
  Run-Probe 'r2-caps-marker' 'R2' 35
}catch{$report.Errors+=$_.Exception.Message}
finally{
  foreach($process in @($child,$server)){try{if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}}catch{$report.RestoreErrors+=$_.Exception.Message}}
  foreach($path in $sourceFiles.Keys){try{[IO.File]::WriteAllBytes($path,$sourceFiles[$path])}catch{$report.RestoreErrors+=$_.Exception.Message}}
  foreach($path in $added){try{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}catch{$report.RestoreErrors+=$_.Exception.Message}}
  $report.SourceRestored=$report.RestoreErrors.Count -eq 0
  foreach($path in $productFiles.Keys){try{if($null -ne $productFiles[$path]){[IO.File]::WriteAllBytes($path,$productFiles[$path])}elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}catch{$report.RestoreErrors+=$_.Exception.Message}}
  $report.ProductOutputRestored=$report.RestoreErrors.Count -eq 0
  try{if($oldUser){Set-ItemProperty -LiteralPath $registry -Name RimeUserDir -Value $oldUser.RimeUserDir}else{Remove-ItemProperty -LiteralPath $registry -Name RimeUserDir -ErrorAction SilentlyContinue}}catch{$report.RestoreErrors+=$_.Exception.Message}
  $report.Passed=$report.Errors.Count -eq 0 -and $report.RestoreErrors.Count -eq 0 -and $report.Probes.Count -eq 5 -and @($report.Probes|Where-Object {-not $_.Passed}).Count -eq 0
  $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding utf8
  Pop-Location
}
if(-not $report.Passed){throw 'Controlled callback validation failed; inspect each reached assertion.'}
