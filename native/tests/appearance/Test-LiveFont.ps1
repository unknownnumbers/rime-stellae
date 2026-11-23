# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param(
  [Parameter(Mandatory)][string]$Installer,
  [Parameter(Mandatory)][ValidateSet('SC','TC')][string]$Profile,
  [Parameter(Mandatory)][string]$InstrumentedServer,
  [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or
    $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'unknownnumbers/rime-stellae') {
  throw 'Use the disposable GitHub-hosted x64 Windows CI job.'
}
$reportRoot = [IO.Path]::GetFullPath($OutputDirectory)
$runnerRoot = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
if (-not $reportRoot.StartsWith($runnerRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $reportRoot)) {
  throw 'Choose a new fixture report directory under RUNNER_TEMP.'
}
$program = Join-Path $env:ProgramFiles 'RimeStellae'
$profileDirectory = Join-Path $env:APPDATA 'RimeStellae'
if ((Test-Path -LiteralPath $program) -or (Test-Path -LiteralPath $profileDirectory) -or
    (Test-Path -LiteralPath 'HKCU:/Software/RimeStellae') -or
    (Get-Process -Name 'StellaeServer*' -ErrorAction SilentlyContinue)) {
  throw 'The fixture requires a fresh runner with no prior Stellae installation.'
}

$null = New-Item -ItemType Directory -Path $reportRoot
$env:STELLAE_BUNDLE_TEST_TRACE = Join-Path $reportRoot 'installer-trace.log'
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$probeBinary = (Resolve-Path -LiteralPath $InstrumentedServer).Path
$trace = Join-Path $reportRoot 'paint-frames.log'
$report = Join-Path $reportRoot 'result.json'
$python = (Get-Command python -CommandType Application).Source

function Start-FixtureProcess([string]$File, [string[]]$Arguments,
    [string]$Name, [bool]$Redirect = $true) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $File
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.WorkingDirectory = Split-Path -Parent $File
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  if ($Redirect) {
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
  }
  if ($Name -eq 'paint server') { $start.Environment['STELLAE_TEST_PAINT_TRACE'] = $trace }
  $process = [Diagnostics.Process]::Start($start)
  if (-not $process) { throw "Could not start $Name." }
  return $process
}

function Invoke-FixtureStep([string]$File, [string[]]$Arguments, [string]$Name,
    [int]$Timeout, [int[]]$PassCodes = @(0)) {
  Write-Output "START $Name"
  $process = Start-FixtureProcess $File $Arguments $Name
  try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($Timeout)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "$Name timed out."
    }
    [IO.File]::WriteAllText((Join-Path $reportRoot "$Name.stdout.log"), $stdout.Result)
    [IO.File]::WriteAllText((Join-Path $reportRoot "$Name.stderr.log"), $stderr.Result)
    if ($process.ExitCode -notin $PassCodes) { throw "$Name failed with exit $($process.ExitCode)." }
  } finally {
    $process.Dispose()
  }
}

$server = $null
try {
  $arguments = if ($Profile -ceq 'SC') { @('/S', '/ProfileSC') } else { @('/S', '/T') }
  Invoke-FixtureStep $installerPath $arguments 'install' 600000 @(0,3010)
  $expectedHant = if ($Profile -ceq 'SC') { 0 } else { 1 }
  if ((Get-ItemPropertyValue -LiteralPath 'HKCU:/Software/RimeStellae' -Name Hant) -ne $expectedHant) {
    throw 'The installer did not preserve the selected output profile.'
  }
  $fonts = Get-Content -LiteralPath (Join-Path $program 'font-notices/font-manifest.json') -Raw | ConvertFrom-Json
  $faceNames = @('Noto Sans CJK SC', 'Noto Sans CJK TC', 'Noto Sans CJK HK')
  if ($fonts.schemaVersion -ne 2 -or $fonts.files.Count -ne 1 -or
      $fonts.files[0].file -cne 'NotoSansCJK-Regular.ttc' -or
      @($faceNames | Where-Object { $_ -cnotin $fonts.files[0].families }).Count) {
    throw 'The installed font manifest does not identify the single shared TTC.'
  }
  Add-Type -LiteralPath (Join-Path $program 'CandidateFontNative.cs')
  foreach ($family in $faceNames) {
    if (-not [StellaeCandidateFontNative]::HasFontFamily($family)) {
      throw "DirectWrite did not resolve $family from the installed TTC."
    }
  }
  $fontKey = 'HKCU:/Software/Microsoft/Windows NT/CurrentVersion/Fonts'
  $collection = Get-ItemPropertyValue -LiteralPath $fontKey -Name 'Noto Sans CJK Regular Collection (OpenType)'
  if ((Get-FileHash -LiteralPath $collection).Hash -ine $fonts.files[0].sha256) {
    throw 'The registered font collection does not match the verified installer file.'
  }
  $standalone = @('FontProfile.ps1', 'FontProfileNative.cs', 'StellaeFontProfile.exe')
  $startMenu = [Environment]::GetFolderPath('CommonPrograms')
  $fontLinks = @(Get-ChildItem -LiteralPath $startMenu -Filter '*.lnk' -Recurse -File |
    Where-Object Name -cin @('Candidate Font.lnk', '候選窗字體.lnk', '候选窗字体.lnk'))
  if (@($standalone | Where-Object { Test-Path -LiteralPath (Join-Path $program $_) }).Count -or $fontLinks.Count) {
    throw 'A standalone font tool was installed with the native appearance setting.'
  }

  $installedServer = Join-Path $program 'StellaeServer.exe'
  foreach ($current in @(Get-Process -Name StellaeServer -ErrorAction SilentlyContinue)) {
    try {
      if ($current.Path -ine $installedServer) { throw 'Unexpected server on the fresh test VM.' }
      $current.Kill()
      if (-not $current.WaitForExit(10000)) { throw 'The installed fixture server did not stop.' }
    } finally { $current.Dispose() }
  }

  # Load the test-only observer beside the actual installed data and DLLs.
  # The installed server remains available for an independent clean check.
  $probe = Join-Path $program 'StellaeServer.AppearanceTrace.exe'
  Copy-Item -LiteralPath $probeBinary -Destination $probe
  $server = Start-FixtureProcess $probe @() 'paint server' $false
  Invoke-FixtureStep $python @((Join-Path $PSScriptRoot 'Probe-LiveFont.py'),
    '--installation', $program, '--profile', $profileDirectory, '--trace', $trace,
    '--default-font', $Profile, '--report', $report, '--server-pid', [string]$server.Id) 'probe' 240000
  $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
  if ($result.passed -ne $true -or $result.sameSessionCommitted -ne $true) {
    throw 'The appearance and draft assertions did not complete.'
  }
  Write-Output "PASS actual candidate font, same live draft, $($result.schemeFilesChecked) untouched scheme files"
} catch {
  if (-not (Test-Path -LiteralPath $report)) {
    [ordered]@{passed=$false; phase='setup'; failure=$_.Exception.Message} |
      ConvertTo-Json | Set-Content -LiteralPath $report -Encoding utf8
  }
  throw
} finally {
  if ($server) {
    try {
      if (-not $server.HasExited) {
        $server.Kill()
        $null = $server.WaitForExit(10000)
      }
    } finally { $server.Dispose() }
  }
}
