# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$FontCollection,
  [string]$DefaultFont=(Join-Path $env:WINDIR 'Fonts/msyh.ttc'),
  [string]$Python='python',
  [string]$ThemeFile=(Join-Path $PSScriptRoot '../../schemes/config/pc/stellae/appearance.yaml'),
  [string]$OutputDirectory=(Join-Path $PSScriptRoot '../../schemes/config/pc/preview')
)
$ErrorActionPreference='Stop'
& $Python (Join-Path $PSScriptRoot 'Generate-ThemePreview.py') --theme $ThemeFile --collection $FontCollection --default-font $DefaultFont --output-directory $OutputDirectory
if($LASTEXITCODE){throw 'Static theme preview generation failed.'}
