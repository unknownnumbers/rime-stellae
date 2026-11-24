# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param([Parameter(Mandatory)][string]$SourceRoot)
$ErrorActionPreference = 'Stop'
$panel = Join-Path (Resolve-Path -LiteralPath $SourceRoot).Path 'WeaselUI/WeaselPanel.cpp'
$include = Join-Path (Split-Path -Parent $panel) 'AppearancePaintTrace.inc'
if (Test-Path -LiteralPath $include) { throw 'Use a clean disposable frontend source copy.' }

function Replace-Anchor([string]$Text, [string]$Before, [string]$After) {
  $count = [regex]::Matches($Text, [regex]::Escape($Before)).Count
  if ($count -ne 1) { throw "Expected one candidate painting anchor, found $count." }
  $Text.Replace($Before, $After)
}

$text = [IO.File]::ReadAllText($panel).Replace("`r`n", "`n")
$text = Replace-Anchor $text '#include "WeaselPanel.h"' "#include `"WeaselPanel.h`"`n#include `"AppearancePaintTrace.inc`""
$text = Replace-Anchor $text 'void WeaselPanel::DoPaint(CDCHandle dc) {' @'
void WeaselPanel::DoPaint(CDCHandle dc) {
  AppearancePaintTrace appearance_trace;
'@
$text = Replace-Anchor $text '      if (FAILED(pDWR->pRenderTarget->EndDraw())) {' @'
      const HRESULT drawing_result = pDWR->pRenderTarget->EndDraw();
      appearance_trace.submitted = SUCCEEDED(drawing_result);
      if (FAILED(drawing_result)) {
'@
$text = Replace-Anchor $text @'
  UpdateLayeredWindow(m_hWnd, ScreenDC, &WindowPosAtScreen, &sz, dc,
                      &PointOriginal, RGB(0, 0, 0), &bf, ULW_ALPHA);
'@ @'
  const BOOL visible_frame =
      UpdateLayeredWindow(m_hWnd, ScreenDC, &WindowPosAtScreen, &sz, dc,
                          &PointOriginal, RGB(0, 0, 0), &bf, ULW_ALPHA);
  if (visible_frame && AppearancePaintTrace::active)
    AppearancePaintTrace::active->Append(m_hWnd, m_ctx, m_style);
'@
$text = Replace-Anchor $text '    pDWR->DrawTextLayoutAt({offsetx, offsety});' @'
    pDWR->DrawTextLayoutAt({offsetx, offsety});
    if (AppearancePaintTrace::active && candidate_comment &&
        pTextFormat == pDWR->pTextFormat.Get())
      AppearancePaintTrace::active->ObserveLayout(pDWR->pTextLayout.Get(),
                                                 pDWR->pDWFactory.Get());
'@

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'PaintTrace.inc') -Destination $include
[IO.File]::WriteAllText($panel, $text, [Text.UTF8Encoding]::new($false))
