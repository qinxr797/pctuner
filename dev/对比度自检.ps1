#Requires -Version 5.1
<#
    检查每套皮肤的文字对比度是否达到 WCAG AA（正文 4.5:1）。

    README 里写了「所有文字对比度实测 ≥ 4.5:1」—— 这句话必须是真的，
    所以把验证脚本一起放进仓库，谁都能自己跑一遍。

    加新皮肤、改配色之后跑一下：
        powershell -NoProfile -ExecutionPolicy Bypass -File dev\对比度自检.ps1

    ★ 2026-09-27 这个脚本抓出过 12 处不达标 ★
      五套皮肤的 TextDim（次要说明文字）都差一点点，最低只有 3.90。
      单看谁都觉得「还行吧」，量出来才知道不行。
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

$themes = Get-BuiltinThemes
$fgKeys = @('TextMain', 'TextMid', 'TextDim')
$bgKeys = @('WindowBg', 'PanelBg', 'CardBg', 'CardHover', 'SurfaceAlt', 'SurfaceSunken')
$bad = 0

foreach ($name in $themes.Keys) {
    $c = $themes[$name].Colors
    foreach ($fg in $fgKeys) {
        foreach ($bg in $bgKeys) {
            if (-not $c.ContainsKey($fg) -or -not $c.ContainsKey($bg)) { continue }
            $r = Get-ContrastRatio $c[$fg] $c[$bg]
            if ($r -lt 4.5) {
                $bad++
                Write-Host ("不达标  {0,-10} {1,-9}{2}  在  {3,-11}{4}  = {5}" -f $name, $fg, $c[$fg], $bg, $c[$bg], $r) -ForegroundColor Red
            }
        }
    }

    # ---- 语义色前景也要查 ----
    #   ★ 这一块以前漏了 ★ 「高危」「超出参考范围」这些标记是**最需要被看清**的字，
    #   结果反而没进自检。皮肤自带 Semantic 表就查它的（检验单的法定墨走这条）。
    if ($themes[$name].Contains('Semantic')) {
        $sem = $themes[$name].Semantic
        $paper = @($bgKeys | Where-Object { $c.ContainsKey($_) } | ForEach-Object { $c[$_] })
        foreach ($k in $sem.Keys) {
            $v = "$($sem[$k])"
            if ($paper -contains $v) { continue }   # 映射到纸色的是背景，不是墨
            foreach ($bg in $bgKeys) {
                if (-not $c.ContainsKey($bg)) { continue }
                $r = Get-ContrastRatio $v $c[$bg]
                if ($r -lt 4.5) {
                    $bad++
                    Write-Host ("不达标  {0,-10} 语义墨 {1}  在  {2,-11}{3}  = {4}" -f $name, $v, $bg, $c[$bg], $r) -ForegroundColor Red
                }
            }
        }
    }
}

if ($bad -eq 0) {
    Write-Host ("全部通过 —— {0} 套皮肤，{1} 组前景/背景组合都 ≥ 4.5:1" -f $themes.Count, ($themes.Count * $fgKeys.Count * $bgKeys.Count)) -ForegroundColor Green
    exit 0
} else {
    Write-Host "共 $bad 处不达标" -ForegroundColor Red
    exit 1
}
