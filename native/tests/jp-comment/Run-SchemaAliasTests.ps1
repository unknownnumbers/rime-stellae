# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Header,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$headerPath=(Resolve-Path -LiteralPath $Header).Path
if((Split-Path $headerPath -Leaf) -cne 'JpCommentStyle.h'){throw 'Use the assembled Japanese presentation header.'}
$compiler=(Get-Command cl.exe -ErrorAction Stop).Source
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $output){throw 'Use a fresh fixture output directory.'}
$null=New-Item -ItemType Directory -Path $output
$source=Join-Path $PSScriptRoot 'schema_alias.cpp'
$executable=Join-Path $output 'schema-alias.exe'
$object=Join-Path $output 'schema-alias.obj'
& $compiler /nologo /EHsc /std:c++17 /W4 /WX /utf-8 ('/I'+(Split-Path $headerPath -Parent)) $source ('/Fo'+$object) ('/Fe'+$executable)
if($LASTEXITCODE){throw 'The Japanese schema-alias fixture did not compile.'}
& $executable | Tee-Object -FilePath (Join-Path $output 'result.json')
if($LASTEXITCODE){throw 'The Japanese schema-alias fixture failed.'}
