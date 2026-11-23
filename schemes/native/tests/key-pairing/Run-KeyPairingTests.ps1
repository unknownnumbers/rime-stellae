# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ServerOutputDirectory,
    [ValidateSet('x64','Win32')][string]$Architecture = 'x64'
)
. (Join-Path $PSScriptRoot '../../../scripts/native/Common.ps1')
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $IsWindows) {
    throw 'Run only on an ephemeral Windows hosted CI runner.'
}
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$serverOutput = (Resolve-Path -LiteralPath $ServerOutputDirectory).Path
Assert-NativeAssembly $source 'weasel-61047'
$manifestHash = (Get-FileHash -LiteralPath $script:NativeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$serverResult = Get-Content -LiteralPath (Join-Path $serverOutput 'build-result.json') -Raw | ConvertFrom-Json
if ($serverResult.variant -cne 'weasel-server-61042' -or -not $serverResult.compilationPassed -or
    $serverResult.publicBuildCommit -cne $env:GITHUB_SHA -or
    $serverResult.publicBuildRunId -cne $env:GITHUB_RUN_ID -or
    $serverResult.manifestSha256 -cne $manifestHash) {
    throw 'The 61042 Server must be built from this manifest and commit in this workflow run.'
}
$serverRecords = @($serverResult.products | Where-Object { $_.name -ceq 'WeaselServer.exe' })
if ($serverRecords.Count -ne 1) { throw 'Expected one declared 61042 Server product.' }
$serverBinary = Join-Path $serverOutput 'WeaselServer.exe'
$null = Assert-NativeHash $serverBinary $serverRecords[0].sha256
Assert-NativePe $serverBinary 0x8664
$header = Join-Path $source 'WeaselTSF/WeaselTSF.h'
if (-not [IO.File]::ReadAllText($header).Contains('friend class ResponseOwnerProductFixture;')) {
    throw 'Expected the frozen product fixture friend declaration.'
}
$output = Join-Path $source 'output'
$logs = Join-Path $source 'ci-logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$stem = 'key-pairing-' + $Architecture.ToLowerInvariant()
$reportPath = Join-Path $logs ($stem + '.json')
if (Test-Path -LiteralPath $reportPath) { throw 'Preserve the previous finite run.' }
$utf8 = [Text.UTF8Encoding]::new($false)
$report = [ordered]@{
    SourceVersion='0.17.4.61047'; SourceCommit=$env:GITHUB_SHA; PublicBuildRunId=$env:GITHUB_RUN_ID
    ManifestSha256=$manifestHash; Architecture=$Architecture; ServerVersion='0.17.4.61042'
    ServerSha256=$serverRecords[0].sha256; Engine='same-run R5 x64 Server runtime'
    Scope='V13/V18/V19 production Test/Actual callbacks, controlled COM context, real engine IPC'
    ExpectedChecks=95; NativeAcpClaimed=$false; FullActivateExTested=$false
    PhysicalKeyboardDispatcherUsed=$false; FieldRootCauseProven=$false; Installed=$false
    Passed=$false; Probes=@(); SourceRestored=$false; ProductOutputRestored=$false
    Errors=@(); RestoreErrors=@()
}
$sourceFiles=@{}; $productFiles=@{}; $added=@(); $server=$null; $child=$null
$registry='HKCU:\Software\Rime\Weasel'
$oldUser=Get-ItemProperty -LiteralPath $registry -Name RimeUserDir -ErrorAction SilentlyContinue
$original=Join-Path $source 'WeaselTSF/Composition.cpp'
$definition=Join-Path $source 'WeaselTSF/WeaselTSF.def'
$producer=Join-Path $source 'WeaselTSF/EditSession.cpp'
foreach ($path in @($original,$definition,$producer)) { $sourceFiles[$path]=[IO.File]::ReadAllBytes($path) }
foreach ($name in @('weasel','weaselx64','WeaselServer')) {
    foreach ($extension in @('dll','exe','pdb','lib','exp')) {
        $path=Join-Path $output "$name.$extension"
        $productFiles[$path]=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllBytes($path)}else{$null}
    }
}
$probes=@(
    @{Mode='truthful-key-pairing';Group='V13';Checks=45},
    @{Mode='truthful-key-nested';Group='V18';Checks=16},
    @{Mode='truthful-key-repeat-space';Group='V19';Checks=34}
)
Push-Location -LiteralPath $source
try {
    Copy-Item -LiteralPath $serverBinary -Destination (Join-Path $output 'WeaselServer.exe') -Force
    foreach ($mapping in @(
        @('ResponseOwnerProductTests.cpp','ResponseOwnerProductTests.cpp.inc'),
        @('ProductHostFixture.h','ProductHostFixture.h'),
        @('SelectionControlledModes.inc','SelectionControlledModes.inc'),
        @('ControlledReadGrant.inc','ControlledReadGrant.inc'))) {
        $target=Join-Path $source ('WeaselTSF/'+$mapping[1])
        if(Test-Path -LiteralPath $target){throw "Test include already present: $target"}
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $mapping[0]) -Destination $target
        $added+=$target
    }
    [IO.File]::AppendAllText($original,"`n#include `"ResponseOwnerProductTests.cpp.inc`"`n",$utf8)
    $producerText=[IO.File]::ReadAllText($producer).Replace("`r",'')
    $keyCall='  const auto outcome = m_client.ProcessKeyEventOutcome(key);'
    if(($producerText.Split([string[]]@($keyCall),[StringSplitOptions]::None).Count-1) -ne 1){throw 'Unique real producer key entry not found.'}
    $producerText=$producerText.Replace($keyCall,"  extern unsigned rymcpRetainedKeyCalls;`n  ++rymcpRetainedKeyCalls;`n"+$keyCall)
    [IO.File]::WriteAllText($producer,$producerText,$utf8)
    if([IO.File]::ReadAllText($definition).Contains('RunResponseOwnerProductTests')){throw 'Test export already present.'}
    [IO.File]::AppendAllText($definition,"`n  RunResponseOwnerProductTests`n",$utf8)
    & msbuild weasel.sln /m /t:WeaselTSF /p:Configuration=Release "/p:Platform=$Architecture" /v:minimal 2>&1 |
        Tee-Object (Join-Path $logs "$stem-build.log")
    if($LASTEXITCODE){throw 'Production key fixture compilation failed.'}
    $user=Join-Path $env:RUNNER_TEMP ($stem+'-public-user-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $user | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'fixture/*.yaml') -Destination $user
    New-Item -Path $registry -Force | Out-Null
    New-ItemProperty -LiteralPath $registry -Name RimeUserDir -Value $user -PropertyType String -Force | Out-Null
    & python (Join-Path $PSScriptRoot 'Deploy-PublicFixture.py') `
        --engine (Join-Path $output 'rime.dll') --header (Join-Path $source 'include/rime_api.h') `
        --shared (Join-Path $output 'data') --user $user `
        --logs (Join-Path $logs "$stem-deploy-compiler") --report (Join-Path $logs "$stem-deploy.json")
    if($LASTEXITCODE){throw 'Synthetic public C API fixture preparation failed.'}
    $deployment=Get-Content -LiteralPath (Join-Path $logs "$stem-deploy.json") -Raw | ConvertFrom-Json
    if(-not $deployment.DeploymentPassed){throw 'Synthetic fixture prerequisites did not pass.'}
    $server=Start-Process -FilePath (Join-Path $output 'WeaselServer.exe') -WorkingDirectory $output -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if($server.HasExited){throw 'Synthetic public server exited.'}
    $system=if($Architecture -eq 'x64'){'System32'}else{'SysWOW64'}
    $shell=Join-Path $env:WINDIR "$system/WindowsPowerShell/v1.0/powershell.exe"
    $dll=Join-Path $output $(if($Architecture -eq 'x64'){'weaselx64.dll'}else{'weasel.dll'})
    $invoke=Join-Path $PSScriptRoot 'Invoke-KeyPairingTests.ps1'
    foreach($probe in $probes){
        $mode=$probe.Mode
        $trace=Join-Path $logs "$stem-$mode.txt"
        $stderr=Join-Path $logs "$stem-$mode-stderr.txt"
        $arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$invoke+'" -DllPath "'+$dll+'" -EvidencePath "'+$trace+'" -Probe '+$mode
        $child=Start-Process -FilePath $shell -ArgumentList $arguments -WorkingDirectory $output -WindowStyle Hidden -RedirectStandardError $stderr -PassThru
        $null=$child.Handle
        $timeout=-not $child.WaitForExit(30000)
        if($timeout){$child.Kill();$child.WaitForExit()}
        $text=if(Test-Path -LiteralPath $trace){[IO.File]::ReadAllText($trace).Replace("`r",'')}else{''}
        $errors=if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''}
        $summary=[regex]::Match($text,'(?m)^RESULT passed=([0-9]+) failed=([0-9]+) groups=([0-9]+)$')
        $failures=@([regex]::Matches($text,'(?m)^(FAIL|ERROR|UNREACHED) .*$')|ForEach-Object{$_.Value})
        $caseCount=[regex]::Matches($text,'(?m)^PASS .*$').Count
        $groupCount=[regex]::Matches($text,'(?m)^GROUP .*$').Count
        $passed=-not $timeout -and $child.ExitCode -eq 0 -and $summary.Success -and
            [int]$summary.Groups[1].Value -eq $probe.Checks -and [int]$summary.Groups[2].Value -eq 0 -and
            [int]$summary.Groups[3].Value -eq 1 -and $caseCount -eq $probe.Checks -and $groupCount -eq 1 -and
            $text.Contains("GROUP $($probe.Group) PASS") -and $failures.Count -eq 0
        $report.Probes+=[pscustomobject]@{Mode=$mode;Group=$probe.Group;ExpectedChecks=$probe.Checks;Exit=$child.ExitCode;
            TimedOut=$timeout;Passed=$passed;Result=$summary.Value;Failures=$failures;
            Trace="ci-logs/$stem-$mode.txt";Stderr=$errors}
        Write-Output $text
        $child=$null
    }
} catch { $report.Errors+=$_.Exception.Message }
finally {
    foreach($process in @($child,$server)){
        try{if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}}
        catch{$report.RestoreErrors+=$_.Exception.Message}
    }
    foreach($path in $sourceFiles.Keys){
        try{[IO.File]::WriteAllBytes($path,$sourceFiles[$path])}catch{$report.RestoreErrors+=$_.Exception.Message}
    }
    foreach($path in $added){
        try{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}catch{$report.RestoreErrors+=$_.Exception.Message}
    }
    $report.SourceRestored=$report.RestoreErrors.Count -eq 0
    foreach($path in $productFiles.Keys){
        try{
            if($null -ne $productFiles[$path]){[IO.File]::WriteAllBytes($path,$productFiles[$path])}
            elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
        }catch{$report.RestoreErrors+=$_.Exception.Message}
    }
    $report.ProductOutputRestored=$report.RestoreErrors.Count -eq 0
    try{
        if($oldUser){Set-ItemProperty -LiteralPath $registry -Name RimeUserDir -Value $oldUser.RimeUserDir}
        else{Remove-ItemProperty -LiteralPath $registry -Name RimeUserDir -ErrorAction SilentlyContinue}
    }catch{$report.RestoreErrors+=$_.Exception.Message}
    $report.Passed=$report.Errors.Count -eq 0 -and $report.RestoreErrors.Count -eq 0 -and
        $report.Probes.Count -eq 3 -and @($report.Probes|Where-Object{-not $_.Passed}).Count -eq 0
    $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding utf8
    Pop-Location
}
if(-not $report.Passed){throw 'Production key pairing failed; inspect raw per-group evidence.'}
Write-Output "KEY_PAIRING_RESULT passed=$($report.Passed) report=$reportPath"
