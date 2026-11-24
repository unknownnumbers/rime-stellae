# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new synthetic fixture directory'}
$root=[IO.Path]::GetFullPath($OutputDirectory)
$notices=Join-Path $root 'installed/scheme-notices'
$payload=Join-Path $root 'payload'
$null=New-Item -ItemType Directory -Path $notices,$payload -Force
$helper=Join-Path $PSScriptRoot '../../../installer/BundleData.ps1'
$checks=@()
function Check([string]$Name,[bool]$Passed){
  $script:checks+=@([ordered]@{name=$Name;passed=$Passed})
  if(-not $Passed){throw $Name}
}
function Write-Fixture([string]$Path,[string]$Value){
  $null=New-Item -ItemType Directory -Path (Split-Path $Path) -Force
  [IO.File]::WriteAllText($Path,$Value)
}
function Record([string]$Relative,[string]$Path){
  return [ordered]@{path=('scheme-notices/'+$Relative);installed_path=('scheme-notices/'+$Relative);sha256=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
}
function Package([string]$Path,[string]$Format,$Files){
  [ordered]@{format=$Format;bundleVersion='synthetic';inputSchemesBundled=$true;files=@($Files)}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $Path -Encoding UTF8
}
Write-Fixture (Join-Path $notices 'rymcp-old-schemes.zip') 'synthetic old archive'
Write-Fixture (Join-Path $notices 'README.md') 'old product description'
Write-Fixture (Join-Path $notices 'docs/modified.md') 'old bundled text'
Write-Fixture (Join-Path $notices 'docs/obsolete.md') 'old obsolete text'
$oldRows=@(
  Record 'rymcp-old-schemes.zip' (Join-Path $notices 'rymcp-old-schemes.zip')
  Record 'README.md' (Join-Path $notices 'README.md')
  Record 'docs/modified.md' (Join-Path $notices 'docs/modified.md')
  Record 'docs/obsolete.md' (Join-Path $notices 'docs/obsolete.md')
)
$outside=Join-Path $root 'installed/data/fixture.userdb/record'
Write-Fixture $outside 'synthetic learning outside notices'
$outsideHash=(Get-FileHash -LiteralPath $outside).Hash
$oldRows+=@([ordered]@{path='data/fixture.userdb/record';installed_path='data/fixture.userdb/record';sha256=$outsideHash.ToLowerInvariant()})
$previous=Join-Path $root 'previous-package.json'
Package $previous 'stellae-rymcp-package-v1' $oldRows
Write-Fixture (Join-Path $notices 'docs/modified.md') 'user changed this document'
Write-Fixture (Join-Path $notices 'custom/keep.txt') 'unknown user file'
Write-Fixture (Join-Path $payload 'README.md') 'new product description'
Write-Fixture (Join-Path $payload 'docs/modified.md') 'new bundled text'
Write-Fixture (Join-Path $payload 'stellae-new-schemes.zip') 'synthetic new archive'
$newRows=@(
  Record 'README.md' (Join-Path $payload 'README.md')
  Record 'docs/modified.md' (Join-Path $payload 'docs/modified.md')
  Record 'stellae-new-schemes.zip' (Join-Path $payload 'stellae-new-schemes.zip')
)
$current=Join-Path $root 'current-package.json'
Package $current 'stellae-package-v2' $newRows
$report=Join-Path $root 'install.json'
& $helper -Action InstallNotices -SharedDirectory $notices -PayloadDirectory $payload -CurrentPackageManifest $current -PreviousPackageManifest $previous -ReportFile $report
$installed=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
Check 'New named scheme archive installed' (Test-Path -LiteralPath (Join-Path $notices 'stellae-new-schemes.zip'))
Check 'Old owned scheme archive removed' (-not(Test-Path -LiteralPath (Join-Path $notices 'rymcp-old-schemes.zip')))
Check 'Unchanged product document updated' ((Get-Content -LiteralPath (Join-Path $notices 'README.md') -Raw) -ceq 'new product description')
Check 'Modified document preserved' ((Get-Content -LiteralPath (Join-Path $notices 'docs/modified.md') -Raw) -ceq 'user changed this document')
Check 'Modified document reported' ('docs/modified.md' -in $installed.sharedConflicts)
Check 'Obsolete owned document removed' (-not(Test-Path -LiteralPath (Join-Path $notices 'docs/obsolete.md')))
Check 'Unknown nested file retained' ((Get-Content -LiteralPath (Join-Path $notices 'custom/keep.txt') -Raw) -ceq 'unknown user file')
Check 'Non-notices learning file unchanged' ((Get-FileHash -LiteralPath $outside).Hash -ceq $outsideHash)
Check 'Notices synchronization does not inspect user overrides' ($installed.userOverrides.Count -eq 0)
& $helper -Action InstallNotices -SharedDirectory $notices -PayloadDirectory $payload -CurrentPackageManifest $current -PreviousPackageManifest $current -ReportFile (Join-Path $root 'repeat.json')
Check 'Repeated install preserves the modified file' ((Get-Content -LiteralPath (Join-Path $notices 'docs/modified.md') -Raw) -ceq 'user changed this document')
& $helper -Action UninstallNotices -SharedDirectory $notices -PreviousPackageManifest $current -ReportFile (Join-Path $root 'uninstall.json')
Check 'Uninstall removes owned current archive' (-not(Test-Path -LiteralPath (Join-Path $notices 'stellae-new-schemes.zip')))
Check 'Uninstall removes unchanged document' (-not(Test-Path -LiteralPath (Join-Path $notices 'README.md')))
Check 'Uninstall retains modified and unknown documents' ((Test-Path -LiteralPath (Join-Path $notices 'docs/modified.md')) -and (Test-Path -LiteralPath (Join-Path $notices 'custom/keep.txt')))
Check 'Uninstall does not touch learning outside notices' ((Get-FileHash -LiteralPath $outside).Hash -ceq $outsideHash)
$unsafe=Join-Path $root 'unsafe-package.json'
Package $unsafe 'stellae-package-v2' @([ordered]@{path='scheme-notices/../outside';installed_path='scheme-notices/../outside';sha256=('0'*64)})
$rejected=$false
try{& $helper -Action UninstallNotices -SharedDirectory $notices -PreviousPackageManifest $unsafe}catch{$rejected=$true}
Check 'Unsafe package notice paths rejected' $rejected
[ordered]@{passed=$true;fixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS notice ownership policy: '+$checks.Count)
