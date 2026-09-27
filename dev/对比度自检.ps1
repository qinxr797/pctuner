#Requires -Version 5.1
<#
    检查两套皮肤的文字对比度是否达到 WCAG AA（正文 4.5:1）。

    README 里写了「所有文字对比度实测 ≥ 4.5:1」—— 这句话必须是真的，
    所以把验证脚本一起放进仓库，谁都能自己跑一遍。

    加新色槽、改配色之后跑一下：
        powershell -NoProfile -ExecutionPolicy Bypass -File dev\对比度自检.ps1

    查四组（色值全部来自 Modules\Theme.ps1，不在这里抄一份）：
      1. 三级文字色 × 所有可能压在底下的背景
      2. 主按钮字 / 主角卡字 × 它们各自的底
      3. 语义色前景 × 卡片、画布、悬停底、自己配对的语义底
      4. 选中态（强调色字）× 选中底

    ★ 2026-09-27 这个脚本抓出过 12 处不达标 ★
      单看谁都觉得「还行吧」，量出来才知道不行。
    ★ v6.0 ★ 参考图的次文字 #8E91A8 在白卡上只有 3.10:1，就是被它拦下来改成 #666A88 的。
#>
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Modules\Theme.ps1')

function Get-RelLuminance([System.Drawing.Color]$c) {
    $lin = {
        param($v)
        $v = $v / 255.0
        if ($v -le 0.03928) { $v / 12.92 } else { [math]::Pow((($v + 0.055) / 1.055), 2.4) }
    }
    0.2126 * (& $lin $c.R) + 0.7152 * (& $lin $c.G) + 0.0722 * (& $lin $c.B)
}

function Get-ContrastRatio([string]$Fg, [string]$Bg) {
    $l1 = Get-RelLuminance ([System.Drawing.ColorTranslator]::FromHtml($Fg))
    $l2 = Get-RelLuminance ([System.Drawing.ColorTranslator]::FromHtml($Bg))
    if ($l1 -lt $l2) { $t = $l1; $l1 = $l2; $l2 = $t }
    [math]::Round(($l1 + 0.05) / ($l2 + 0.05), 2)
}

$bad = 0
$n = 0
function Test-Pair([string]$Theme, [string]$FgName, [string]$Fg, [string]$BgName, [string]$Bg) {
    $script:n++
    $r = Get-ContrastRatio $Fg $Bg
    if ($r -lt 4.5) {
        $script:bad++
        Write-Host ("不达标  {0}  {1,-14}{2}  在  {3,-14}{4}  = {5}" -f $Theme, $FgName, $Fg, $BgName, $Bg, $r) -ForegroundColor Red
    }
}

$bgKeys = @('Canvas', 'Sidebar', 'Card', 'CardHover', 'SurfaceAlt', 'SurfaceSunken', 'AccentTint')
foreach ($name in $Script:Palettes.Keys) {
    $c = $Script:Palettes[$name]
    $dark = ($name -eq '深色')

    # 1. 三级文字
    foreach ($fg in 'TextMain', 'TextMid', 'TextDim') {
        foreach ($bg in $bgKeys) { Test-Pair $name $fg $c[$fg] $bg $c[$bg] }
    }
    # 2. 压在实色块上的字
    Test-Pair $name 'OnAccent' $c.OnAccent 'Accent' $c.Accent
    Test-Pair $name 'OnAccent' $c.OnAccent 'AccentPressed' $c.AccentPressed
    Test-Pair $name 'OnHero' $c.OnHero 'HeroFill' $c.HeroFill
    Test-Pair $name 'OnHeroDim' $c.OnHeroDim 'HeroFill' $c.HeroFill
    # 4. 选中态：侧边栏当前页、选中的预设 = Accent 字压 AccentTint 底；链接式文字压卡片
    Test-Pair $name 'Accent' $c.Accent 'AccentTint' $c.AccentTint
    Test-Pair $name 'Accent' $c.Accent 'Card' $c.Card

    # 3. 语义色：前景 × 常见底 + 自己配对的底
    $Script:ThemeName = $name
    $Script:ThemeIsDark = $dark
    $pairs = @(@('#556B54', '#E7EBE4'), @('#7A6B45', '#EDE7D9'), @('#8A5750', '#EDE0DD'), @('#89694F', '#EDE2D6'))
    foreach ($pr in $pairs) {
        $fg = Get-ThemeHex $pr[0]
        foreach ($bg in 'Canvas', 'Card', 'CardHover', 'SurfaceAlt') { Test-Pair $name "语义$($pr[0])" $fg $bg $c[$bg] }
        Test-Pair $name "语义$($pr[0])" $fg '配对底' (Get-ThemeHex $pr[1])
    }
    # 危险按钮：白字压高危红
    Test-Pair $name 'ButtonDanger字' $(if ($dark) { $c.Canvas } else { '#FFFFFF' }) 'SemBad' (Get-ThemeHex '#8A5750')
}

if ($bad -eq 0) {
    Write-Host ("全部通过 —— {0} 套皮肤，{1} 组前景/背景组合都 ≥ 4.5:1" -f $Script:Palettes.Count, $n) -ForegroundColor Green
    exit 0
} else {
    Write-Host "共 $bad 处不达标（共查 $n 组）" -ForegroundColor Red
    exit 1
}
