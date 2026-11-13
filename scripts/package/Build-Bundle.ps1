# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or -not $IsWindows){throw 'Use a disposable hosted Windows runner'}
$repo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$inputs=Get-Content -LiteralPath (Join-Path $repo 'installer/bundle-inputs.json') -Raw|ConvertFrom-Json
if(-not $inputs.schemes -or $inputs.schemes.commit -notmatch '^[0-9a-f]{40}$' -or $inputs.schemes.sha256 -notmatch '^[0-9a-f]{64}$'){throw 'Pin the scheme source and archive before building'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new package output directory'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$output=(Resolve-Path -LiteralPath $OutputDirectory).Path
$cache=Join-Path $output 'inputs'
$null=New-Item -ItemType Directory -Path $cache
function Fetch($Spec,[string]$Name){
  if($Spec.url -notmatch '^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[^/]+/[^/]+$'){throw 'Expected a public pinned release URL'}
  $path=Join-Path $cache $Name
  Invoke-WebRequest $Spec.url -OutFile $path
  if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $Spec.sha256){throw 'Public input SHA256 differs'}
  return $path
}
$base=Fetch $inputs.frontendInstaller 'frontend-61052.exe'
$baseSources=Fetch $inputs.frontendSources 'frontend-61052-source.zip'
$seven=Fetch $inputs.sevenZipSources '7z2405-src.tar.xz'
$scheme=Fetch $inputs.schemes ('rymcp-'+$inputs.bundleVersion+'-stellae-schemes.zip')
$native=Get-Content -LiteralPath (Join-Path $repo 'native/source-manifest.json') -Raw|ConvertFrom-Json
$officialSpec=@($native.assets|Where-Object {$_.id -eq 'shared-data'})[0]
$official=Fetch $officialSpec 'official-weasel-0.17.4.exe'
& 7z.exe x $base ('-o'+(Join-Path $output 'base')) -aou -y|Out-File (Join-Path $output 'extract-base.log')
if($LASTEXITCODE){throw 'Original installer extraction failed'}
& 7z.exe x $official ('-o'+(Join-Path $output 'official')) 'data/*' -y|Out-File (Join-Path $output 'extract-official.log')
if($LASTEXITCODE){throw 'Official shared extraction failed'}
$stage=Join-Path $output 'stage/output'
& python (Join-Path $PSScriptRoot 'prepare_bundle.py') --repository $repo --base (Join-Path $output 'base') --official (Join-Path $output 'official') --schemes $scheme --stage $stage
if($LASTEXITCODE){throw 'Bundle source assembly failed'}
& python (Join-Path $PSScriptRoot 'render_installed_docs.py') --repository $repo --output-directory $stage --ref $env:GITHUB_SHA
if($LASTEXITCODE){throw 'Documentation rendering failed'}
& python (Join-Path $PSScriptRoot 'index_bundle.py') --stage $stage --ref $env:GITHUB_SHA
if($LASTEXITCODE){throw 'Bundle payload index failed'}
& python (Join-Path $PSScriptRoot 'verify_pe.py') --root $stage --report (Join-Path $output 'pe-verification.json')
if($LASTEXITCODE){throw 'Reused product PE validation failed'}
$makensis=Join-Path ${env:ProgramFiles(x86)} 'NSIS/Bin/makensis.exe'
if(-not (Test-Path -LiteralPath $makensis) -or ((& $makensis /VERSION|Out-String).Trim()) -cne 'v3.11'){
  & choco install nsis --version=3.11 -y --no-progress --force --allow-downgrade
  if($LASTEXITCODE){throw 'Pinned NSIS installation failed'}
}
if(((& $makensis /VERSION|Out-String).Trim()) -cne 'v3.11'){throw 'NSIS 3.11 is required'}
Push-Location $stage
try{
  & $makensis /INPUTCHARSET UTF8 /DWEASEL_VERSION=0.17.4 /DWEASEL_BUILD=61052 /DPRODUCT_VERSION=0.17.4.61052 ('/DBUNDLE_VERSION='+$inputs.bundleVersion) bundle.nsi 2>&1|Tee-Object (Join-Path $output 'nsis-build.log')
  if($LASTEXITCODE){throw 'Bundle NSIS compilation failed'}
}finally{Pop-Location}
$installer=Join-Path $stage ('archives/stellae-rymcp-'+$inputs.bundleVersion+'-installer.exe')
$release=Join-Path $output 'release'
$null=New-Item -ItemType Directory -Path $release
Copy-Item -LiteralPath $installer,(Join-Path $stage 'package-manifest.json'),(Join-Path $stage 'package-license-index.json'),(Join-Path $stage 'bundle-provenance.json'),(Join-Path $output 'pe-verification.json'),$seven -Destination $release
& 7z.exe x $installer ('-o'+(Join-Path $output 'actual')) -aou -y|Out-File (Join-Path $output 'extract-actual.log')
if($LASTEXITCODE){throw 'Final installer extraction failed'}
& python (Join-Path $PSScriptRoot 'verify_bundle.py') --stage $stage --extracted (Join-Path $output 'actual') --report (Join-Path $release 'payload-verification.json')
if($LASTEXITCODE){throw 'Final installer payload verification failed'}
$parts=Join-Path $output 'source-parts'
$null=New-Item -ItemType Directory -Path $parts
Copy-Item -LiteralPath $baseSources,$scheme -Destination $parts
Push-Location $repo
try{& git archive --format=zip ('--output='+(Join-Path $parts 'bundle-project-source.zip')) HEAD;if($LASTEXITCODE){throw 'Bundle project source archive failed'}}finally{Pop-Location}
Copy-Item -LiteralPath (Join-Path $stage 'bundle-inputs.json'),(Join-Path $stage 'SOURCES.md') -Destination $parts
Compress-Archive -Path (Join-Path $parts '*') -DestinationPath (Join-Path $release ('stellae-rymcp-'+$inputs.bundleVersion+'-source.zip')) -CompressionLevel Optimal
Write-Output ('BUNDLE_OUTPUT '+$output)
