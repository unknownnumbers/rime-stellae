# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$FontCollection,
  [string]$DefaultFont=(Join-Path $env:WINDIR 'Fonts/msyh.ttc'),
  [string]$Python='python',
  [string]$ThemeFile=(Join-Path $PSScriptRoot '../../schemes/config/pc/weasel.custom.yaml'),
  [string]$OutputFile=(Join-Path $PSScriptRoot '../../schemes/config/pc/preview/color_scheme_reference_gray.png')
)
$ErrorActionPreference='Stop'
& $Python (Join-Path $PSScriptRoot 'Generate-ThemePreview.py') --theme $ThemeFile --collection $FontCollection --default-font $DefaultFont --output-file $OutputFile
if($LASTEXITCODE){throw 'Static theme preview generation failed.'}
