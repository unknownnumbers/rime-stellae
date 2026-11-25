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

# The pinned bare 61052 package explicitly has no schemes and no format field.
$bareNotices=Join-Path $root 'bare-installed/scheme-notices'
$barePayload=Join-Path $root 'bare-payload'
Write-Fixture (Join-Path $bareNotices 'README.md') 'unowned modified bare document'
Write-Fixture (Join-Path $bareNotices 'private/keep.txt') 'unknown bare document'
Write-Fixture (Join-Path $barePayload 'README.md') 'current bundled document'
Write-Fixture (Join-Path $barePayload 'docs/new-notice.txt') 'current owned notice'
$barePrevious=Join-Path $root 'bare-package.json'
[ordered]@{version='0.17.4.61052';inputSchemesBundled=$false;files=@()}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $barePrevious -Encoding UTF8
$bareCurrent=Join-Path $root 'bare-to-bundle-package.json'
Package $bareCurrent 'stellae-package-v2' @(
  Record 'README.md' (Join-Path $barePayload 'README.md')
  Record 'docs/new-notice.txt' (Join-Path $barePayload 'docs/new-notice.txt')
)
$bareReport=Join-Path $root 'bare-to-bundle.json'
& $helper -Action InstallNotices -SharedDirectory $bareNotices -PayloadDirectory $barePayload -CurrentPackageManifest $bareCurrent -PreviousPackageManifest $barePrevious -ReportFile $bareReport
$bareResult=Get-Content -LiteralPath $bareReport -Raw|ConvertFrom-Json
Check 'Bare package without format can upgrade to bundled notices' ($bareResult.passed -and (Test-Path -LiteralPath (Join-Path $bareNotices 'docs/new-notice.txt')))
Check 'Bare package claims no unknown or modified notices' ((Get-Content -LiteralPath (Join-Path $bareNotices 'README.md') -Raw) -ceq 'unowned modified bare document' -and (Get-Content -LiteralPath (Join-Path $bareNotices 'private/keep.txt') -Raw) -ceq 'unknown bare document')
Check 'Unowned bare notice collision is reported' ('README.md' -in $bareResult.sharedConflicts)
$rejected=$false
try{& $helper -Action InstallNotices -SharedDirectory $bareNotices -PayloadDirectory $barePayload -CurrentPackageManifest $barePrevious}catch{$rejected=$true}
Check 'Bare package cannot be the current notices payload' $rejected
foreach($invalid in @(
  [ordered]@{inputSchemesBundled=$true;bundleVersion='invalid';files=@()}
  [ordered]@{format='unknown-package';inputSchemesBundled=$true;bundleVersion='invalid';files=@()}
  [ordered]@{format='stellae-package-v2';inputSchemesBundled='false';bundleVersion='invalid';files=@()}
  [ordered]@{format='stellae-package-v2';inputSchemesBundled=0;bundleVersion='invalid';files=@()}
)){
  $invalidPath=Join-Path $root 'invalid-bundle-package.json'
  $invalid|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $invalidPath -Encoding UTF8
  $rejected=$false
  try{& $helper -Action UninstallNotices -SharedDirectory $bareNotices -PreviousPackageManifest $invalidPath}catch{$rejected=$true}
  Check 'Missing/unknown bundle format and non-boolean ownership remain rejected' $rejected
}
Check 'Rejected notice manifests preserve existing files' ((Get-Content -LiteralPath (Join-Path $bareNotices 'README.md') -Raw) -ceq 'unowned modified bare document' -and (Get-Content -LiteralPath (Join-Path $bareNotices 'private/keep.txt') -Raw) -ceq 'unknown bare document' -and (Get-Content -LiteralPath (Join-Path $bareNotices 'docs/new-notice.txt') -Raw) -ceq 'current owned notice')
$unsafe=Join-Path $root 'unsafe-package.json'
Package $unsafe 'stellae-package-v2' @([ordered]@{path='scheme-notices/../outside';installed_path='scheme-notices/../outside';sha256=('0'*64)})
$rejected=$false
try{& $helper -Action UninstallNotices -SharedDirectory $notices -PreviousPackageManifest $unsafe}catch{$rejected=$true}
Check 'Unsafe package notice paths rejected' $rejected
[ordered]@{passed=$true;fixtureOnly=$true;checks=$checks}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding UTF8
Write-Output ('PASS notice ownership policy: '+$checks.Count)
