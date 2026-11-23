# SPDX-License-Identifier: GPL-3.0-only
# Download and extract fixed public runtimes; never run either installer.
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'Choose a fresh runtime output directory.' }
New-Item -ItemType Directory -Path $out | Out-Null
$archiveCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
$archiveTool = if ($archiveCommand) { $archiveCommand.Source } else { Join-Path $env:ProgramFiles '7-Zip/7z.exe' }
if (-not (Test-Path -LiteralPath $archiveTool)) { throw '7-Zip is required for installer extraction.' }
$assets = @(
    @{Id='official';Url='https://github.com/rime/weasel/releases/download/0.17.4/weasel-0.17.4.0-installer.exe';Hash='cf509534a8f5f8af9c98ed7cbb8f135439f145a8cbe7e50ede42bb5b5ab45c29';Runtime=@{x64='2d8f1bc3737635a11d9fb1bfca4dc9e70533633930a8a0142a81ca879c39c45b'}},
    @{Id='stellae';Url='https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.20/stellae-rymcp-2026.11.20-installer.exe';Hash='692684d2102c85cd7c6714da21006a97b312d039cd4658f45de9877c6f4ade60';Runtime=@{x64='7c2d5d5a922d0d8fbd07c6a9f4d8f9be56a4e2f9b3a50e54cfabede09f509f21';Win32='a1c6fb6b92844ee6365b4f576583a0aca10d7bf2146f158c37d1cade7d12252c'}}
)
function Machine([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { return 0 }
    $offset = [BitConverter]::ToInt32($bytes,0x3c)
    if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length) { return 0 }
    return [BitConverter]::ToUInt16($bytes,$offset+4)
}
$records = @()
foreach ($asset in $assets) {
    $archive = Join-Path $out ($asset.Id + '.exe')
    Invoke-WebRequest -Uri $asset.Url -OutFile $archive -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $asset.Hash) { throw ('Download hash mismatch: ' + $asset.Id) }
    $extract = Join-Path $out ($asset.Id + '-extracted')
    & $archiveTool x $archive ('-o'+$extract) -aou -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Extraction failed: ' + $asset.Id) }
    $machines = if ($asset.Id -eq 'official') { @{x64=0x8664} } else { @{x64=0x8664;Win32=0x14c} }
    foreach ($architecture in $machines.Keys) {
        $matches = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'rime*.dll' | Where-Object { (Machine $_.FullName) -eq $machines[$architecture] -and (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $asset.Runtime[$architecture] })
        if (-not $matches.Count) { throw ('Pinned runtime not found for ' + $asset.Id + '/' + $architecture) }
        $engineDir = Join-Path $out ($asset.Id + '-' + $architecture)
        New-Item -ItemType Directory -Path $engineDir | Out-Null
        Copy-Item -LiteralPath $matches[0].FullName -Destination (Join-Path $engineDir 'rime.dll')
        $records += [pscustomobject]@{Source=$asset.Id;Architecture=$architecture;ArchiveSha256=$actualHash;RuntimeSha256=(Get-FileHash -LiteralPath (Join-Path $engineDir 'rime.dll') -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
$officialShared = Join-Path $out 'official-extracted/data'
foreach ($required in @('default.yaml','pinyin.yaml','stroke.schema.yaml','stroke.dict.yaml','key_bindings.yaml','punctuation.yaml','symbols.yaml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $officialShared $required))) { throw ('Missing shared data: ' + $required) }
}
[pscustomobject]@{Format='rymcp-validation-runtimes-v1';InstallersExecuted=$false;Runtimes=$records} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'runtimes.json') -Encoding UTF8
Write-Output 'Fixed public runtimes and official shared data extracted.'
