# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param(
  [Parameter(Mandatory)][string]$Installer,
  [Parameter(Mandatory)][string]$LegacyInstaller,
  [Parameter(Mandatory)][ValidateSet('SC','TC')][string]$Profile,
  [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or
    $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'unknownnumbers/rime-stellae') {
  throw 'Use the disposable GitHub-hosted x64 Windows CI job.'
}
$out = [IO.Path]::GetFullPath($OutputDirectory)
$runner = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
if (-not $out.StartsWith($runner + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $out)) {
  throw 'Choose a new fixture report directory under RUNNER_TEMP.'
}
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$legacyPath = (Resolve-Path -LiteralPath $LegacyInstaller).Path
$installerHash = (Get-FileHash -LiteralPath $installerPath).Hash
$legacyHash = (Get-FileHash -LiteralPath $legacyPath).Hash
if ($installerHash -ceq $legacyHash) { throw 'Supply separate legacy and TTC installers.' }

$null = New-Item -ItemType Directory -Path $out
$env:STELLAE_BUNDLE_TEST_TRACE = Join-Path $out 'installer-trace.log'
$program = Join-Path $env:ProgramFiles 'RimeStellae'
$user = Join-Path $env:APPDATA 'RimeStellae'
$productKey = 'HKCU:/Software/RimeStellae'
$fontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft/Windows/Fonts'
$fontSubKey = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$registryName = 'Noto Sans CJK Regular Collection (OpenType)'
$legacyRegistryName = "Noto Sans CJK $Profile (OpenType)"
$standaloneFiles = @('FontProfile.ps1', 'FontProfileNative.cs', 'StellaeFontProfile.exe')
$shortcutNames = @('Candidate Font.lnk', '候選窗字體.lnk', '候选窗字体.lnk')
$checks = [Collections.Generic.List[string]]::new()
$phase = 'preflight'

function Assert-Result([bool]$Passed, [string]$Name) {
  if (-not $Passed) { throw $Name }
  $checks.Add($Name)
  Write-Output "PASS $Name"
}

function Invoke-Installer([string]$File, [string]$Arguments, [string]$Step) {
  $options = @{
    FilePath = $File
    ArgumentList = $Arguments
    PassThru = $true
    WindowStyle = 'Hidden'
    RedirectStandardOutput = Join-Path $out "$Step.stdout.log"
    RedirectStandardError = Join-Path $out "$Step.stderr.log"
  }
  $process = Start-Process @options
  try {
    if (-not $process.WaitForExit(540000)) {
      $process.Kill($true)
      $null = $process.WaitForExit(10000)
      throw "$Step timed out."
    }
    Assert-Result ($process.ExitCode -in @(0,3010)) "$Step exit code $($process.ExitCode)"
  } finally {
    $process.Dispose()
  }
}

function Get-RegisteredFonts {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fontSubKey)
  $result = @{}
  if ($key) {
    try {
      foreach ($name in $key.GetValueNames()) { $result[$name] = $key.GetValue($name) }
    } finally { $key.Dispose() }
  }
  return $result
}

function Get-OldFontShortcuts {
  $start = [Environment]::GetFolderPath('CommonPrograms')
  Get-ChildItem -LiteralPath $start -Filter '*.lnk' -Recurse -File |
    Where-Object Name -cin $shortcutNames
}

function Get-PreservedHashes([string[]]$Names) {
  $result = @{}
  foreach ($name in $Names) {
    $result[$name] = (Get-FileHash -LiteralPath (Join-Path $user $name)).Hash
  }
  return $result
}

function Assert-Preserved($Expected, $Actual, [string]$Label) {
  foreach ($name in $Expected.Keys) {
    Assert-Result ($Expected[$name] -ceq $Actual[$name]) "$Label preserved $name"
  }
}

function Assert-Collection($Registry, $Manifest) {
  $faceNames = @('Noto Sans CJK SC', 'Noto Sans CJK TC', 'Noto Sans CJK HK')
  $font = @($Manifest.files)
  Assert-Result ($Manifest.schemaVersion -eq 2 -and $font.Count -eq 1 -and
    $font[0].file -ceq 'NotoSansCJK-Regular.ttc' -and $font[0].families.Count -eq 10) `
    'installed manifest describes a single ten-face Noto TTC'
  Assert-Result ($Registry.ContainsKey($registryName)) 'current user has the shared TTC registration'
  $collection = [IO.Path]::GetFullPath([string]$Registry[$registryName])
  $fontRoot = [IO.Path]::GetFullPath($fontDirectory).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  Assert-Result ($collection.StartsWith($fontRoot, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $collection) -like '*NotoSansCJK-Regular.ttc' -and
    (Get-Item -LiteralPath $collection).Length -eq $font[0].size -and
    (Get-FileHash -LiteralPath $collection).Hash -ieq $font[0].sha256) `
    'the installed TTC matches the bundled font'
  $collections = @(Get-ChildItem -LiteralPath $fontDirectory -Filter '*NotoSansCJK-Regular.ttc' -File)
  Assert-Result ($collections.Count -eq 1 -and $collections[0].FullName -ieq $collection) `
    'exactly one copy of the TTC is installed'
  foreach ($family in $faceNames) {
    Assert-Result ($family -cin $font[0].families -and [StellaeCandidateFontNative]::HasFontFamily($family)) `
      "DirectWrite resolves $family"
  }
}

function Assert-ProgramCleanup {
  foreach ($name in $standaloneFiles) {
    Assert-Result (-not (Test-Path -LiteralPath (Join-Path $program $name))) "legacy $name removed"
  }
  Assert-Result (@(Get-OldFontShortcuts).Count -eq 0) 'legacy font shortcut removed'
}

try {
  Assert-Result (-not (Test-Path -LiteralPath $program) -and -not (Test-Path -LiteralPath $user) -and
    -not (Test-Path -LiteralPath $productKey) -and
    -not (Get-Process -Name 'StellaeServer*' -ErrorAction SilentlyContinue)) `
    'clean Windows CI runner'
  $originalFonts = Get-RegisteredFonts
  Assert-Result (-not $originalFonts.ContainsKey($registryName) -and
    -not $originalFonts.ContainsKey($legacyRegistryName)) 'no prior Noto font registration'

  $phase = 'install pinned legacy bundle'
  $legacyArgs = if ($Profile -ceq 'SC') { '/S /ProfileSC' } else { '/S /T' }
  Invoke-Installer $legacyPath $legacyArgs 'legacy-install'
  $expectedHant = if ($Profile -ceq 'SC') { 0 } else { 1 }
  Assert-Result ((Get-ItemPropertyValue -LiteralPath $productKey -Name Hant) -eq $expectedHant) `
    'legacy installer created the expected output profile'
  $legacyFonts = Get-RegisteredFonts
  Assert-Result ($legacyFonts.ContainsKey($legacyRegistryName) -and
    -not $legacyFonts.ContainsKey($registryName)) 'legacy installer registered the selected OTF'
  $legacyFont = [IO.Path]::GetFullPath([string]$legacyFonts[$legacyRegistryName])
  Assert-Result ((Split-Path -Leaf $legacyFont) -like "RymCp-*NotoSansCJK$($Profile.ToLowerInvariant())-Regular.otf" -and
    (Test-Path -LiteralPath $legacyFont -PathType Leaf)) 'legacy OTF has its original product filename'
  Assert-Result ((Test-Path -LiteralPath (Join-Path $program 'FontProfile.ps1')) -and
    @(Get-OldFontShortcuts).Count -eq 1) 'legacy tool and its start menu shortcut are present'

  $style = @"
patch:
  style/font_face: Microsoft YaHei
  style/font_point: 17
  style/horizontal: true
"@
  [IO.File]::WriteAllText((Join-Path $user 'weasel.custom.yaml'), $style)
  [IO.File]::AppendAllText((Join-Path $user 'default.custom.yaml'), [Environment]::NewLine + '# Synthetic upgrade sentinel' + [Environment]::NewLine)
  [IO.File]::WriteAllText((Join-Path $user 'appearance-test-local.txt'), 'Synthetic user file')
  $preservedPaths = @('rymcp_candidate_font.yaml','default.custom.yaml','appearance-test-local.txt')
  $preserved = Get-PreservedHashes $preservedPaths
  $appearanceHash=(Get-FileHash -LiteralPath (Join-Path $user 'weasel.custom.yaml') -Algorithm SHA256).Hash

  $phase = 'upgrade legacy font installation to TTC'
  Invoke-Installer $installerPath '/S' 'ttc-upgrade'
  $newFonts = Get-RegisteredFonts
  Assert-Result (-not $newFonts.ContainsKey($legacyRegistryName)) 'owned legacy OTF registration retired'
  Assert-Preserved $originalFonts $newFonts 'upgrade'
  Add-Type -LiteralPath (Join-Path $program 'CandidateFontNative.cs')
  $manifestPath = Join-Path $program 'font-notices/font-manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  Assert-Collection $newFonts $manifest
  Assert-ProgramCleanup
  Assert-Preserved $preserved (Get-PreservedHashes $preservedPaths) 'upgrade'
  Assert-Result ((Get-ItemPropertyValue -LiteralPath $productKey -Name Hant) -eq $expectedHant) `
    'existing output profile retained on upgrade'
  Assert-Result ((Get-FileHash -LiteralPath (Join-Path $user 'stellae.custom.yaml') -Algorithm SHA256).Hash -ceq $appearanceHash -and -not (Test-Path -LiteralPath (Join-Path $user 'weasel.custom.yaml'))) 'legacy appearance file migrated byte-exactly'
  $preservedPaths+=@('stellae.custom.yaml')
  $preserved=Get-PreservedHashes $preservedPaths
  $compiled = [IO.File]::ReadAllText((Join-Path $user 'build/stellae.yaml'))
  Assert-Result ($compiled -match '(?m)^  font_face: *["'']?Microsoft YaHei["'']?\s*$' -and
    $compiled -match '(?m)^  font_point: *17\s*$' -and
    $compiled -match '(?m)^  horizontal: *true\s*$') 'existing appearance overrides retained in compiled style'

  $phase = 'reinstall same TTC bundle'
  Invoke-Installer $installerPath '/S' 'ttc-repeat'
  $repeatedFonts = Get-RegisteredFonts
  Assert-Result ($repeatedFonts.Count -eq $newFonts.Count) 'same-version upgrade adds no font registrations'
  Assert-Preserved $newFonts $repeatedFonts 'same-version upgrade'
  Assert-Collection $repeatedFonts $manifest
  Assert-ProgramCleanup
  Assert-Preserved $preserved (Get-PreservedHashes $preservedPaths) 'same-version upgrade'
  [ordered]@{
    passed = $true
    profile = $Profile
    installerSha256 = $installerHash
    legacyInstallerSha256 = $legacyHash
    checks = $checks
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding utf8NoBOM
} catch {
  [ordered]@{ passed = $false; phase = $phase; message = $_.Exception.Message; checks = $checks } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding utf8NoBOM
  throw
}
