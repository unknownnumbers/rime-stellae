# SPDX-License-Identifier: GPL-3.0-only
param(
  [string]$ThemeFile=(Join-Path $PSScriptRoot '../../schemes/config/pc/weasel.custom.yaml'),
  [string]$OutputFile=(Join-Path $PSScriptRoot '../../schemes/config/pc/preview/color_scheme_reference_gray.png')
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$text=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ThemeFile))
function ThemeColor([string]$Key){
  $match=[regex]::Match($text,'(?m)^    '+[regex]::Escape($Key)+':\s*0x([0-9a-fA-F]{8})')
  if(-not $match.Success){throw "Missing theme color: $Key"}
  $abgr=[Convert]::ToUInt32($match.Groups[1].Value,16)
  $a=($abgr -shr 24) -band 255
  $r=$abgr -band 255; $g=($abgr -shr 8) -band 255; $b=($abgr -shr 16) -band 255
  # Static previews follow the upstream PNG mechanism, on a white backdrop.
  [Drawing.Color]::FromArgb(255,255-((255-$r)*$a/255),255-((255-$g)*$a/255),255-((255-$b)*$a/255))
}
$bitmap=[Drawing.Bitmap]::new(348,236)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$font=[Drawing.Font]::new('Microsoft YaHei',18,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$label=[Drawing.Font]::new('Segoe UI',15,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$preedit=[Drawing.Font]::new('Segoe UI',17,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$brushes=@{}
try{
  if($font.FontFamily.Name -ne 'Microsoft YaHei'){throw 'Microsoft YaHei is required to render the static theme preview.'}
  $graphics.Clear([Drawing.Color]::White)
  $graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  foreach($key in @('back_color','text_color','candidate_text_color','hilited_candidate_text_color')){$brushes[$key]=[Drawing.SolidBrush]::new((ThemeColor $key))}
  $border=[Drawing.Pen]::new((ThemeColor 'border_color'),1)
  try{
    $graphics.FillRectangle($brushes.back_color,8,8,332,220)
    $graphics.DrawRectangle($border,8,8,332,220)
    $graphics.DrawString('mo xin ji di',$preedit,$brushes.text_color,20,15)
    $words=@('墨芯基底','墨芯','墨心','默心','墨新')
    for($i=0;$i -lt $words.Count;$i++){
      $brush=if($i -eq 0){$brushes.hilited_candidate_text_color}else{$brushes.candidate_text_color}
      $y=49+$i*33
      $graphics.DrawString(($i+1).ToString()+'.',$label,$brush,20,$y+2)
      $graphics.DrawString($words[$i],$font,$brush,49,$y)
    }
    $target=[IO.Path]::GetFullPath($OutputFile)
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
    $bitmap.Save($target,[Drawing.Imaging.ImageFormat]::Png)
  }finally{$border.Dispose()}
}finally{
  foreach($brush in $brushes.Values){$brush.Dispose()}
  $preedit.Dispose();$label.Dispose();$font.Dispose();$graphics.Dispose();$bitmap.Dispose()
}
