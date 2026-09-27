#Requires -Version 5.1
<#
    生成 app.ico —— 和界面左上角那个「调」徽标同一套配色。

    为什么自己画而不是找张图：这是要跟着公开仓库一起发的，
    随手下载的图标八成带许可问题。自己画的 20 行代码，干干净净。

    ICO 里放 4 个尺寸（16/32/48/256）。256 那张用 PNG 压缩存 ——
    Vista 以后的 Windows 认这种格式，体积能小一个数量级。
#>
param([string]$Out = (Join-Path $PSScriptRoot 'app.ico'))

Add-Type -AssemblyName System.Drawing

# 仪表灰皮肤的面板色 + 暖白读数色，跟程序里一致
$bg = [System.Drawing.ColorTranslator]::FromHtml('#20252D')
$fg = [System.Drawing.ColorTranslator]::FromHtml('#E8EAEE')
$ln = [System.Drawing.ColorTranslator]::FromHtml('#5A6472')

function New-IconBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)

    # 圆角方块底
    $r = [math]::Max(2, [int]($Size * 0.18))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $Size - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush $bg), $path)

    # 一条刻度线，暗示「这是个测量工具」——小尺寸下省掉，糊成一团反而脏
    if ($Size -ge 32) {
        $pen = New-Object System.Drawing.Pen $ln, ([single]([math]::Max(1, $Size / 32)))
        $y = [int]($Size * 0.78)
        $g.DrawLine($pen, [int]($Size * 0.18), $y, [int]($Size * 0.82), $y)
        $pen.Dispose()
    }

    # 「调」字
    $fs = [single]($Size * 0.58)
    $font = New-Object System.Drawing.Font '微软雅黑', $fs, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $box = New-Object System.Drawing.RectangleF 0, ([single](-$Size * 0.06)), ([single]$Size), ([single]$Size)
    $g.DrawString('调', $font, (New-Object System.Drawing.SolidBrush $fg), $box, $sf)

    $font.Dispose(); $sf.Dispose(); $path.Dispose(); $g.Dispose()
    return $bmp
}

$sizes = @(16, 32, 48, 256)
$pngs = @()
foreach ($s in $sizes) {
    $b = New-IconBitmap -Size $s
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , $ms.ToArray()
    $ms.Dispose(); $b.Dispose()
}

# 手写 ICO 容器：6 字节文件头 + 每张 16 字节目录项 + 各张 PNG 数据
$fsOut = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter $fsOut
$bw.Write([uint16]0)               # reserved
$bw.Write([uint16]1)               # type = icon
$bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    # 256 在目录项里写 0（一个字节存不下 256）
    $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $bw.Write([byte]0)             # 调色板数
    $bw.Write([byte]0)             # reserved
    $bw.Write([uint16]1)           # 色彩平面
    $bw.Write([uint16]32)          # 位深
    $bw.Write([uint32]$pngs[$i].Length)
    $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush(); $bw.Close(); $fsOut.Close()

Write-Host "图标已生成：$Out（$([int]((Get-Item $Out).Length / 1KB)) KB，$($sizes -join '/') 四个尺寸）"
