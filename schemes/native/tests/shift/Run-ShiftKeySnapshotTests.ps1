param([ValidateSet('x64','Win32')][string]$Platform='x64', [string]$SourceRoot=$PWD.Path)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Run only on an ephemeral hosted CI runner.'}
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
$utf8=[Text.UTF8Encoding]::new($false)
$logs=Join-Path $source 'ci-logs'
$build=Join-Path $logs "shift-key-snapshot-$Platform-work"
if(Test-Path -LiteralPath $build){throw 'Preserve the previous finite run.'}
[IO.Directory]::CreateDirectory($build)|Out-Null
function Copy-ProductionFunction([string]$relative,[string]$start,[string]$end,[string]$target){
 $text=[IO.File]::ReadAllText((Join-Path $source $relative)).Replace("`r",'')
 $begin=$text.IndexOf($start,[StringComparison]::Ordinal)
 if($begin -lt 0){throw "Missing product function $start"}
 $finish=$text.IndexOf($end,$begin,[StringComparison]::Ordinal)
 if($finish -le $begin){throw "Missing end marker for $start"}
 [IO.File]::WriteAllText((Join-Path $build $target),$text.Substring($begin,$finish-$begin),$utf8)
}
Copy-ProductionFunction 'WeaselIPCServer/WeaselServerImpl.cpp' 'DWORD ServerImpl::OnKeyEvent(' 'DWORD ServerImpl::OnShutdownServer(' 'production-key-handler.inc'
Copy-ProductionFunction 'RimeWithWeasel/RimeWithWeasel.cpp' 'BOOL RimeWithWeaselHandler::ProcessKeyEvent(' 'void RimeWithWeaselHandler::CommitComposition(' 'production-engine-handler.inc'
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if(-not $vs){throw 'Official MSVC C++ tools unavailable.'}
$vcvars=Join-Path $vs 'VC/Auxiliary/Build/vcvarsall.bat'
$arch=if($Platform -eq 'x64'){'x64'}else{'x86'}
$exe=Join-Path $build 'ShiftKeySnapshotTests.exe'
$obj=Join-Path $build 'ShiftKeySnapshotTests.obj'
$cpp=Join-Path $PSScriptRoot 'ShiftKeySnapshotTests.cpp'
$include=Join-Path $source 'include'
$command=Join-Path $build 'compile.cmd'
$lines=@('@echo off',('call "'+$vcvars+'" '+$arch), 'if errorlevel 1 exit /b %errorlevel%',
 ('cl.exe /nologo /std:c++17 /EHsc /W4 /utf-8 /DUNICODE /D_UNICODE /I"'+$include+'" /I"'+$build+'" "'+$cpp+'" /Fe"'+$exe+'" /Fo"'+$obj+'" /link user32.lib'),
 'exit /b %errorlevel%')
[IO.File]::WriteAllLines($command,$lines,[Text.Encoding]::ASCII)
& $env:ComSpec /d /c $command 2>&1 | Tee-Object -FilePath (Join-Path $logs "shift-key-snapshot-$Platform-build.log")
if($LASTEXITCODE){throw "Finite Shift fixture compilation failed: $Platform"}
$text=(& $exe 2>&1 | Out-String).Replace("`r",'')
$exitCode=$LASTEXITCODE
Write-Output $text
[IO.File]::WriteAllText((Join-Path $logs "shift-key-snapshot-$Platform.txt"),$text,$utf8)
$match=[regex]::Match($text,'(?m)^RESULT passed=([0-9]+) failed=([0-9]+)$')
$passed=$exitCode -eq 0 -and $match.Success -and [int]$match.Groups[1].Value -gt 0 -and [int]$match.Groups[2].Value -eq 0
$report=[ordered]@{Passed=$passed;Architecture=$Platform;ExitCode=$exitCode;
 Cases=@([regex]::Matches($text,'(?m)^(PASS|FAIL) .*$')|ForEach-Object{$_.Value});
 PassedCases=if($match.Success){[int]$match.Groups[1].Value}else{-1};
 FailedCases=if($match.Success){[int]$match.Groups[2].Value}else{-1};
 Coverage=@('actual ShiftKeySnapshot codec and shared TSF/IMM capture helper','verbatim extracted product ServerImpl::OnKeyEvent','verbatim extracted product RimeWithWeaselHandler::ProcessKeyEvent','fake API/session/context observes current property lifetime');
 Limits=@('not real named-pipe transport','not OS SendInput or TSF Test/Key callback ordering','not full engine/Lua or real host text store');
 ProductionFilesModified=$false;ProductDllInstrumented=$false;ServerStarted=$false;
 LiveModified=$false;PersonalConfigurationUploaded=$false}
[IO.File]::WriteAllText((Join-Path $logs "shift-key-snapshot-$Platform.json"),($report|ConvertTo-Json -Depth 6),$utf8)
if(-not $passed){throw "Finite Shift fixture failed: $Platform"}
