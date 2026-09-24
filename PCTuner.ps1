<#
=====================================================================
  PCTuner.ps1  ——  电脑调优助手  主程序
---------------------------------------------------------------------
  用法：双击同目录下的「一键启动.bat」即可（会自动申请管理员权限）。

  五个页面：
    性能优化   —— 一条条开关，每条都写清楚了是干什么的
    垃圾清理   —— 先扫描看能清多少，再决定清哪些
    启动项管理 —— 开机自启程序，附带「这个能不能关」的建议
    系统体检   —— 硬件信息 + 按性价比排序的升级/保养建议
    操作日志   —— 做过什么一目了然

  安全保障：
    · 改任何东西之前先备份原值，「还原」是真的能还原
    · 可选：动手前自动创建系统还原点
    · 清理只删缓存和临时文件，路径全部硬编码 + 安全校验
=====================================================================
#>

param(
    # 自检模式：把界面完整构建一遍但不显示窗口，用来验证程序没坏。
    # 平时用不到，双击 bat 启动时不会带这个参数。
    [switch]$SelfTest,

    # 静默清理模式：不开界面，直接跑一遍推荐的清理项。
    # 「日常维护」页里的「每周自动清理」建立的计划任务就是调用这个。
    [switch]$AutoClean
)

$ErrorActionPreference = 'Continue'

# ===== 版本号 =====
# 改版本号只改这一处，标题栏 / 副标题 / 诊断报告都从这里取。
$Script:AppVersion     = '2.1'
$Script:AppVersionDate = '2026-09-24'
$Script:AppVersionName = '激进优化版'

# ---------------------------------------------------------------------
#  0. 加载 .NET 界面库
# ---------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------------
#  1. 检查管理员权限，没有就重新以管理员身份启动自己
#     （修改注册表 HKLM、系统服务、电源计划都需要管理员）
# ---------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $SelfTest -and -not $AutoClean -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        )
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "这个工具需要管理员权限才能修改系统设置。`r`n`r`n请右键点击「一键启动.bat」→ 以管理员身份运行。",
            '电脑调优助手', 'OK', 'Warning') | Out-Null
    }
    exit
}

# ---------------------------------------------------------------------
#  2. 载入各个模块
# ---------------------------------------------------------------------
$Script:AppRoot = Split-Path -Parent $PSCommandPath
# 载入顺序有依赖：Engine 提供日志和注册表底座，其余模块都用得到，必须第一个
$Script:ModuleNames = @('Engine', 'Tweaks', 'Games', 'Cleaner', 'Maintain', 'Inspect', 'SysInfo', 'Startup', 'Appx', 'Theme')

# ---------- 1.1 先查文件齐不齐 ----------
# 为什么要专门查一遍：通过微信/QQ 传「文件夹」过去经常会漏文件
#   —— 微信收到的文件是按需下载的，没等下载完就运行，就会缺几个。
# 如果直接 dot-source，PowerShell 只会甩一句
#   「无法将 xxx\Inspect.ps1 项识别为 cmdlet、函数、脚本文件或可运行程序的名称」，
# 这句话对普通用户毫无意义，根本不知道是「文件没传全」。
$missing = @()
foreach ($m in $Script:ModuleNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:AppRoot "Modules\$m.ps1"))) { $missing += "$m.ps1" }
}
if ($missing.Count -gt 0) {
    if ($SelfTest) { Write-Host ("自检失败：缺少模块 " + ($missing -join ', ')); exit 2 }
    [System.Windows.Forms.MessageBox]::Show(@"
程序文件不完整，Modules 文件夹里缺少 $($missing.Count) 个文件：

$($missing -join "`r`n")

它应该在这个位置：
$Script:AppRoot\Modules

【为什么会这样】
多半是用微信 / QQ 传「文件夹」时没传全。
微信收到的文件是「按需下载」的，没等全部下载完就点开运行，就会缺文件。

【怎么解决】
1. 让对方重新发一次「电脑调优助手.zip」压缩包（一个文件，不会漏）
2. 右键这个 zip → 属性 → 勾上「解除锁定」→ 确定
3. 解压到一个固定位置，比如 D:\PCTuner
4. 双击里面的「一键启动.bat」

（Modules 文件夹里应该正好有 8 个 .ps1 文件）
"@, '电脑调优助手 - 文件不完整', 'OK', 'Error') | Out-Null
    exit
}

# ---------- 1.2 位置检查 ----------
# 在微信接收目录里直接运行有两个实际问题：
#   · 微信会清理/搬动这些文件，程序随时可能跑一半就没了
#   · Backup 文件夹（「还原」功能全靠它）也会建在那里，跟着一起丢
$rootLower = $Script:AppRoot.ToLower()
$badPlace = $null
if ($rootLower -match 'xwechat_files|wechat files|tencent files|\\msg\\file\\') {
    $badPlace = '微信 / QQ 的接收文件目录'
} elseif ($rootLower -match '\\appdata\\local\\temp\\|\\windows\\temp\\') {
    # 直接在压缩包里双击运行时，资源管理器 / 7-Zip 会把内容解到这两个目录下
    $badPlace = '系统临时目录（通常是直接在压缩包里双击运行造成的）'
}
if ($badPlace -and -not $SelfTest -and -not $AutoClean) {
    $ans = [System.Windows.Forms.MessageBox]::Show(@"
检测到程序正运行在：$badPlace

$Script:AppRoot

【为什么不建议在这里运行】
· 微信 / 系统会自动清理这个目录，文件随时可能消失
· 本工具的「Backup」文件夹（一键还原全靠它）也会建在这里，
  一起被清掉之后就还原不回去了

【建议】
先把整个「PCTuner」文件夹**剪切**到一个固定位置，
比如 D:\PCTuner，再从那里运行。

要继续吗？（选「否」退出，去挪好位置再来）
"@, '电脑调优助手 - 位置不合适', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { exit }
}

# ---------- 1.2.5 自动解除「网络来源」锁定 ----------
#
# ★ 这一步是为了治一个反复出现的报错：「对路径的访问被拒绝」★
#
# 从微信 / QQ / 浏览器拿到的压缩包，解压出来的**每一个文件**都会被
# Windows 打上一个叫 Zone.Identifier 的隐藏数据流（右键属性里那个
# 「解除锁定」勾选框就是它）。带着这个标记的 .ps1，PowerShell 会
# 拒绝读取，报出来的却是很难懂的「对路径的访问被拒绝」——
# 文件明明好好地躺在那儿，就是读不了。
#
# 以前的做法是让用户自己右键 → 属性 → 解除锁定，
# 但普通用户根本不知道要对**哪个**文件做、也经常漏掉子文件夹里的。
# 所以这里开机直接全部清掉，不麻烦用户。
#
# 清不掉也没关系（比如文件只读），下面的诊断会接着说清是什么情况。
try {
    Get-ChildItem -LiteralPath $Script:AppRoot -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
        }
} catch { }

# ---------- 1.2.6 文件到底怎么了：出错时给真诊断，不再一句话打发 ----------
function Get-FileTrouble {
    <#
      检查一个文件为什么用不了，返回「人话原因 + 怎么办」。
      没问题返回 $null。

      为什么要单独写这个：以前不管什么错都提示「多半是微信没传全」，
      但「文件被锁定」「杀毒软件拦了」和「真的没传全」是三回事，
      解决办法完全不同。给错方向的提示比不给还糟 ——
      用户会反复重传，然后发现怎么传都不行。
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @"
【原因】这个文件根本不存在。

【怎么办】多半是用微信 / QQ 传「文件夹」时漏了文件
（微信的文件是点开才下载的，没下完就运行就会缺）。
让对方重新发一次「电脑调优助手.zip」**压缩包**（一个文件，不会漏），
你收到后先完整下载，再解压。
"@
    }

    $fi = $null
    try { $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }

    if ($fi -and $fi.Length -eq 0) {
        return @"
【原因】文件存在，但是是空的（0 字节）—— 内容没传过来。

【怎么办】同上，让对方重发「电脑调优助手.zip」压缩包，
等它**完全下载完**（微信里显示的不是「下载中」）再解压。
"@
    }

    # 真正去读一下，看是不是读得动
    $readErr = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $fs.Close()
    } catch {
        $readErr = $_.Exception
    }

    if ($readErr -is [System.UnauthorizedAccessException] -or "$($readErr.Message)" -match '拒绝|denied') {
        return @"
【原因】文件在，但 Windows 不让读它。常见的就两种：

  ① 文件被标记成「来自网络，不安全」（最常见）
     程序启动时已经自动帮你解除过一次了，如果还是这个错，
     说明解除失败 —— 多半是下面第 ② 种。

  ② 杀毒软件把它拦下了
     这个工具会读注册表、查开机启动项、扫描弹窗来源，
     这些动作和病毒的行为很像，360 / 火绒 / 电脑管家
     经常会误报并锁住文件。

【怎么办 —— 按顺序试】

  第 1 步：右键「电脑调优助手.zip」→ 属性 →
          勾上底部的「解除锁定」→ 确定 → **重新解压一遍**
          （关键：要对 **zip 压缩包** 解锁，再解压；
            对解压出来的文件夹解锁是没用的）

  第 2 步：还不行的话，看杀毒软件的「隔离区 / 病毒查杀记录」，
          里面多半有这个文件。选择「恢复」并「添加信任」。

  第 3 步：把整个文件夹换个位置再试，比如直接放 D:\PCTuner。
          不要放在「下载」文件夹、桌面、U 盘或微信接收目录里。

  第 4 步：都不行就临时退出杀毒软件，用完再打开。
"@
    }

    if ($readErr -and "$($readErr.Message)" -match '正在使用|being used|另一个程序') {
        return @"
【原因】文件正被别的程序占用着。

【怎么办】多半是杀毒软件正在扫描它，或者这个工具已经开了一个窗口。
等十几秒再试一次；还不行就重启电脑。
"@
    }

    if ($readErr) {
        return "【原因】读取文件失败：$($readErr.Message)"
    }

    return $null   # 文件本身没问题，那就是脚本内容的问题
}

# ---------- 1.3 逐个载入，出错时能说清是哪个模块、为什么 ----------
foreach ($m in $Script:ModuleNames) {
    $f = Join-Path $Script:AppRoot "Modules\$m.ps1"
    try {
        . $f
    } catch {
        $why = Get-FileTrouble -Path $f
        if (-not $why) {
            $why = @"
【原因】文件读得到，但内容有问题（脚本本身报错了）。

【怎么办】这属于程序 bug，把这个窗口截图发给给你这个工具的人。
"@
        }
        if ($SelfTest) {
            Write-Host ("自检失败：模块 $m.ps1 载入出错 - " + $_.Exception.Message)
            Write-Host $why
            exit 2
        }
        [System.Windows.Forms.MessageBox]::Show(@"
载入模块「$m.ps1」时出错。

文件位置：
$f

系统报的原始错误：
$($_.Exception.Message)

$why
"@, '电脑调优助手 - 文件读不了', 'OK', 'Error') | Out-Null
        exit
    }
}

Initialize-Engine -RootPath $Script:AppRoot

# ---------------------------------------------------------------------
#  1.5 静默清理模式：计划任务调用的就是这条路径，不开界面
# ---------------------------------------------------------------------
if ($AutoClean) {
    Invoke-SilentClean | Out-Null
    exit 0
}

# ---------------------------------------------------------------------
#  3. 界面小工具
# ---------------------------------------------------------------------
function Get-Brush {
    <#
      拿一支画笔。

      ★ 换肤的关键在这里 ★
      界面代码里写的是「默认皮肤的那个色号」，比如 Get-Brush '#F6F5F2'。
      这个函数会先查一遍当前皮肤的映射表：
      如果这个色号属于可换肤的中性色/主色，就换成当前皮肤的对应色；
      查不到（说明是绿/红/卡其那种语义色）就原样返回。

      这样做的好处是：**代码里所有 Get-Brush 调用一行都不用改**，
      换肤自动生效；而「高危=红色」这种含义色不会被皮肤弄乱。
    #>
    param([string]$Hex)
    if ($Script:ColorRemap -and $Script:ColorRemap.ContainsKey($Hex.ToUpper())) {
        $Hex = $Script:ColorRemap[$Hex.ToUpper()]
    }
    return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)))
}
function New-Thick {
    param($L, $T, $R, $B)
    if ($null -eq $T) { return (New-Object System.Windows.Thickness $L) }
    return (New-Object System.Windows.Thickness $L, $T, $R, $B)
}
function Sync-UI {
    <# WPF 版的 DoEvents：长任务执行时让界面还能刷新，不至于「假死」 #>
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $cb = [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $cb, $frame) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Set-Status {
    param([string]$Text)
    if ($Script:UI -and $Script:UI.StatusText) { $Script:UI.StatusText.Text = $Text }
    Sync-UI
}
function Set-Busy {
    <# 底部那条会动的进度条。长任务期间打开，免得用户以为程序卡死了。 #>
    param([bool]$On)
    if ($Script:UI -and $Script:UI.BusyBar) {
        $Script:UI.BusyBar.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    }
    Sync-UI
}

# --- 列表卡片的配色（悬停 / 选中要有反馈，否则点了左边不知道自己点的是哪一条）---
$Script:CARD_BG      = '#F6F5F2'
$Script:CARD_BORDER  = '#E0DED8'
$Script:CARD_HOVER   = '#F0EFEB'
$Script:CARD_SEL_BG  = '#E4E7EC'
$Script:CARD_SEL_BD  = '#7F8A99'
$Script:SelectedCard = $null

function New-ListCard {
    <# 统一生成左侧列表用的卡片，自带悬停反馈 #>
    $c = New-Object System.Windows.Controls.Border
    $c.Background = Get-Brush $Script:CARD_BG
    $c.BorderBrush = Get-Brush $Script:CARD_BORDER
    $c.BorderThickness = New-Thick 1
    $c.CornerRadius = New-Object System.Windows.CornerRadius 8
    $c.Padding = New-Thick 13 11 13 11
    $c.Margin = New-Thick 0 0 0 7
    $c.Cursor = 'Hand'
    $c.Add_MouseEnter({ if ($Script:SelectedCard -ne $this) { $this.Background = Get-Brush $Script:CARD_HOVER } })
    $c.Add_MouseLeave({ if ($Script:SelectedCard -ne $this) { $this.Background = Get-Brush $Script:CARD_BG } })
    return $c
}

function Select-Card {
    <# 把某张卡片标成「当前选中」，上一张恢复原样 #>
    param($Card)
    if ($Script:SelectedCard) {
        try {
            $Script:SelectedCard.Background = Get-Brush $Script:CARD_BG
            $Script:SelectedCard.BorderBrush = Get-Brush $Script:CARD_BORDER
        } catch { }
    }
    $Script:SelectedCard = $Card
    if ($Card) {
        $Card.Background = Get-Brush $Script:CARD_SEL_BG
        $Card.BorderBrush = Get-Brush $Script:CARD_SEL_BD
    }
}
function Format-Reflow {
    <#
      把说明文字里「为了源码好读而手动折的行」重新接回整段，让 WPF 自己按栏宽折行。

      为什么要做：说明文本都是按大约 40 个字手写折行的，在右侧那个窄栏里显示，
      两种折行会打架，出现「平衡模式为了省电，会在你不动 / 的时候把 CPU 频率降到很低」
      这种莫名其妙的断句。

      但不能无脑全合并 —— 列表项、编号、小标题、缩进的命令行本来就该独立成行。
      所以只合并「两行都是普通正文」的情况。
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    # 这些开头的行保持原样：项目符号 / 编号 / 小标题 / 提示符号 / 缩进
    $keep = '^(\s{2,}|[·•\-—>|★☆✓✗⚠※]|【|\d+[\.\)、]|第[一二三四五六七八九十]|[A-Da-d][\.\)]\s)'
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.TrimEnd()
        if ($t.Trim() -eq '') { [void]$out.Add(''); continue }
        $standalone = ($t -match $keep) -or ($t.TrimEnd() -match '】$')
        $prev = if ($out.Count -gt 0) { $out[$out.Count - 1] } else { $null }
        $prevMergeable = ($null -ne $prev) -and ($prev -ne '') -and -not ($prev -match $keep) -and -not ($prev -match '】$')
        if ($standalone -or -not $prevMergeable) {
            [void]$out.Add($t)
        } else {
            # 中文直接接上；两边都是英文/数字时补一个空格
            $sep = ''
            if ($prev -match '[A-Za-z0-9)]$' -and $t -match '^[A-Za-z0-9(]') { $sep = ' ' }
            $out[$out.Count - 1] = $prev + $sep + $t.TrimStart()
        }
    }
    return ($out -join "`r`n")
}

function New-TextBlock {
    <#
      说明文字里用 **这样** 标记重点。
      注意：WPF 的 TextBlock 不认 Markdown —— 直接赋给 .Text 的话
      屏幕上会原样出现两个星号，很难看。所以这里把文本按 ** 切开，
      拼成一串 Run，偶数段普通、奇数段加粗，让重点真的变成粗体。
    #>
    param([string]$Text, [double]$Size = 13, [string]$Color = '#2B2A26', [bool]$Bold = $false, [bool]$Wrap = $false)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontSize = $Size
    $tb.Foreground = Get-Brush $Color
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    if ($Wrap) { $tb.TextWrapping = 'Wrap'; $tb.LineHeight = $Size * 1.65 }

    if ($Text -and $Text.Contains('**')) {
        $isBold = $false
        foreach ($seg in ($Text -split '\*\*')) {
            if ($seg -ne '') {
                $run = New-Object System.Windows.Documents.Run $seg
                if ($isBold) { $run.FontWeight = 'Bold' }
                $tb.Inlines.Add($run)
            }
            $isBold = -not $isBold
        }
    } else {
        $tb.Text = $Text
    }
    return $tb
}
function Get-TintBg {
    <#
      按前景色给徽章配一个同色系的浅底。
      换浅色主题时踩的坑：原来深色主题下徽章底写的是深色（#12161D），
      批量换色后变成了白色，结果白徽章贴在白卡片上完全看不出边界。
      改成按语义取淡色底，既有区分度又不刺眼。
    #>
    param([string]$Fg)
    switch ($Fg) {
        '#556B54' { return '#E2E7E0' }   # 灰绿：良好 / 必做 / 低风险
        '#7A6B45' { return '#EDE7D9' }   # 灰卡其：需实测 / 中风险 / 可疑
        '#89694F' { return '#EDE7D9' }   # 灰陶：会弹黑框
        '#8A5750' { return '#EDE0DD' }   # 灰玫瑰：高危 / 高风险
        '#55606F' { return '#E4E7EC' }   # 灰蓝：推荐 / 已知打扰 / 主色
        '#6E6B63' { return '#E8E7E2' }   # 暖灰：中性（显式列出来——
                                         # 原来它是靠 default 恰好返回同一个值才对的，
                                         # 属于「碰巧能跑」，中性色一改就会悄悄失效）
        default   { return '#E8E7E2' }
    }
}

function New-Badge {
    param([string]$Text, [string]$Fg, [string]$Bg)
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush $Bg
    $b.CornerRadius = New-Object System.Windows.CornerRadius 5
    $b.Padding = New-Thick 8 3 8 3
    $b.Margin = New-Thick 0 0 6 4
    $b.VerticalAlignment = 'Center'      # 不加这句，徽章和旁边的文字会错开半行
    $tb = New-TextBlock -Text $Text -Size 11 -Color $Fg
    $tb.FontWeight = 'SemiBold'
    $b.Child = $tb
    return $b
}
# 风险等级 -> 颜色
function Get-RiskColors {
    param([string]$Risk)
    switch ($Risk) {
        '低' { return @{ Fg = '#556B54'; Bg = '#E2E7E0' } }
        '中' { return @{ Fg = '#7A6B45'; Bg = '#EDE7D9' } }
        '高' { return @{ Fg = '#8A5750'; Bg = '#EDE0DD' } }
        default { return @{ Fg = '#6E6B63'; Bg = '#E8E7E2' } }
    }
}

# ---------------------------------------------------------------------
#  4. 界面布局（XAML）
# ---------------------------------------------------------------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="电脑调优助手" Height="800" Width="1240" MinHeight="620" MinWidth="1000"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBg}" Foreground="{DynamicResource TextMain}"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13">
  <Window.Resources>
    <!-- 换肤用的中性色与主色。运行时由 Apply-Theme 整体替换。
         注意：绿/红/卡其那几个语义色故意不在这里 —— 换肤不能改变「高危」的颜色。 -->
    <SolidColorBrush x:Key="Accent" Color="#55606F"/>
    <SolidColorBrush x:Key="AccentDark" Color="#39424E"/>
    <SolidColorBrush x:Key="AccentLight" Color="#7F8A99"/>
    <SolidColorBrush x:Key="AccentTint" Color="#E4E7EC"/>
    <SolidColorBrush x:Key="BorderMed" Color="#D6D4CD"/>
    <SolidColorBrush x:Key="BorderSoft" Color="#DDDBD5"/>
    <SolidColorBrush x:Key="BorderStrong" Color="#C6C4BC"/>
    <SolidColorBrush x:Key="CardBg" Color="#F6F5F2"/>
    <SolidColorBrush x:Key="NeutralTint" Color="#E8E7E2"/>
    <SolidColorBrush x:Key="OnAccent" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="PanelBg" Color="#FBFAF8"/>
    <SolidColorBrush x:Key="ScrollThumbBg" Color="#CBC9C1"/>
    <SolidColorBrush x:Key="ScrollThumbDrag" Color="#9E9B91"/>
    <SolidColorBrush x:Key="ScrollThumbHover" Color="#B5B2A9"/>
    <SolidColorBrush x:Key="SurfaceAlt" Color="#EDECE8"/>
    <SolidColorBrush x:Key="SurfaceSunken" Color="#E5E3DC"/>
    <SolidColorBrush x:Key="TextDim" Color="#6E6B63"/>
    <SolidColorBrush x:Key="TextMain" Color="#2B2A26"/>
    <SolidColorBrush x:Key="TextMid" Color="#4A4842"/>
    <SolidColorBrush x:Key="WindowBg" Color="#E4E3DE"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
    </Style>

    <!-- 滚动条：Windows 默认那套浅色滚动条在深色界面上非常跳，这里整个重做 -->
    <Style x:Key="ScrollPageButton" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="MinHeight" Value="28"/>
      <Setter Property="MinWidth" Value="28"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Th" Background="{DynamicResource ScrollThumbBg}" CornerRadius="4" Margin="3,2,3,2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Th" Property="Background" Value="{DynamicResource ScrollThumbHover}"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="Th" Property="Background" Value="{DynamicResource ScrollThumbDrag}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ScrollPageButton}"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ScrollPageButton}"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource ScrollPageButton}"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Style="{StaticResource ScrollThumb}"/>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource ScrollPageButton}"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- 复选框：默认样式是白底小方块，深色界面上很突兀。改成描边 + 选中填蓝 + 打勾 -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="17" Height="17" CornerRadius="4" VerticalAlignment="Center"
                      Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource BorderStrong}" BorderThickness="1.4">
                <Path x:Name="Tick" Data="M 3,7.5 L 6.4,11 L 12.2,3.8" Stroke="{DynamicResource OnAccent}" StrokeThickness="1.9"
                      StrokeEndLineCap="Round" StrokeStartLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter x:Name="CP" Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{DynamicResource AccentLight}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource AccentLight}"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource AccentLight}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 搜索框 -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource PanelBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderMed}"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentLight}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 进度条：长时间扫描时给个动起来的反馈，免得以为卡死了 -->
    <Style TargetType="ProgressBar">
      <Setter Property="Background" Value="{DynamicResource SurfaceSunken}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentLight}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
      <Setter Property="Background" Value="{DynamicResource PanelBg}"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource BorderMed}"
                    BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentTint}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentLight}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceSunken}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <!-- 压在松岭绿上的字要纯白（对比度 5.9）；卡片底色那个米白在这里会发灰 -->
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#EDE0DD"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource TextDim}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Grid>
              <Border x:Name="Bd" Background="Transparent" Padding="19,11" Margin="0,0,3,0" CornerRadius="9,9,0,0">
                <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <!-- 选中时底部那条绿色指示条 -->
              <Border x:Name="Ind" Height="2.5" VerticalAlignment="Bottom" Margin="19,0,22,0"
                      Background="{DynamicResource AccentLight}" CornerRadius="2" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceAlt}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextMid}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceAlt}"/>
                <Setter TargetName="Ind" Property="Visibility" Value="Visible"/>
                <!-- 换浅色主题时这里差点翻车：原来是白字（深色主题下的写法），
                     改成浅底之后就成了「白字压白底」，选中的标签整个看不见。 -->
                <Setter Property="Foreground" Value="{DynamicResource AccentDark}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- TabControl 自己也要重做，否则内容区会留着默认的灰边框和方角 -->
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TabPanel Grid.Row="0" IsItemsHost="True" Panel.ZIndex="1" Background="Transparent"/>
              <Border Grid.Row="1" Background="{DynamicResource SurfaceAlt}" CornerRadius="0,10,10,10">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ========== 顶部标题栏 ========== -->
    <Border Grid.Row="0" Background="{DynamicResource CardBg}" Padding="20,13" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="0,0,0,1">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="34" Height="34" CornerRadius="9" Background="{DynamicResource Accent}" VerticalAlignment="Center">
            <TextBlock Text="调" FontSize="17" FontWeight="Bold" Foreground="{DynamicResource OnAccent}"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="电脑调优助手" FontSize="18" FontWeight="Bold"/>
              <Border Background="{DynamicResource AccentTint}" CornerRadius="3" Padding="6,1" Margin="8,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="VerBadge" Text="" FontSize="11" FontWeight="Bold" Foreground="{DynamicResource Accent}"/>
              </Border>
            </StackPanel>
            <TextBlock x:Name="SubTitle" Text="" FontSize="11.5" Foreground="{DynamicResource TextDim}" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <CheckBox x:Name="ChkRestorePoint" Content="操作前自动创建系统还原点" IsChecked="True"
                    Foreground="{DynamicResource TextDim}" FontSize="12" Margin="0,0,14,0"/>
          <Button x:Name="BtnRestorePoint" Content="立即创建还原点"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ========== 主体 ========== -->
    <TabControl Grid.Row="1" x:Name="Tabs" Background="Transparent" BorderThickness="0" Padding="0" Margin="14,10,14,0">

      <!-- 第一页：性能优化 -->
      <TabItem Header="性能优化">
        <Grid Margin="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="430"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0" Margin="16,14,8,14">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{DynamicResource CardBg}" CornerRadius="8" BorderBrush="{DynamicResource BorderMed}"
                    BorderThickness="1" Padding="13,11" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="预设 · 点一下自动勾好。游戏预设保证三个游戏都不吃亏；浏览器瘦身按代价从小到大分三档。"
                           Foreground="{DynamicResource TextDim}" FontSize="12" Margin="0,0,0,9"/>
                <WrapPanel x:Name="PresetBar"/>
              </StackPanel>
            </Border>
            <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
              <Grid Width="200" Margin="0,0,10,0">
                <TextBox x:Name="TweakSearch"/>
                <TextBlock x:Name="TweakSearchHint" Text="搜索优化项…" Foreground="{DynamicResource TextDim}" FontSize="12.5"
                           Margin="11,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
              </Grid>
              <Button x:Name="BtnPickRecommended" Content="勾选通用推荐项"/>
              <Button x:Name="BtnPickNone" Content="全部不选"/>
              <Button x:Name="BtnRescan" Content="重新检测状态"/>
            </StackPanel>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="TweakPanel" Margin="0,0,10,0"/>
            </ScrollViewer>
            <Border Grid.Row="3" BorderBrush="{DynamicResource BorderMed}" BorderThickness="0,1,0,0" Padding="0,12,0,0" Margin="0,10,0,0">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnApplySelected" Content="应用选中的优化" Style="{StaticResource AccentButton}" Padding="20,9"/>
                <Button x:Name="BtnRevertSelected" Content="还原选中的优化"/>
                <Button x:Name="BtnRevertAll" Content="全部还原为系统默认" Style="{StaticResource DangerButton}"/>
                <TextBlock x:Name="TweakSelCount" Text="" Foreground="{DynamicResource TextDim}" FontSize="12.5"
                           VerticalAlignment="Center" Margin="6,0,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
          <Border Grid.Column="1" Background="{DynamicResource PanelBg}" Margin="8,14,16,14" CornerRadius="10" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="1">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18,16">
              <StackPanel x:Name="TweakDetail"/>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <!-- 第二页：垃圾清理 -->
      <TabItem Header="垃圾清理">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="430"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0" Margin="16,14,8,14">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
              <Grid Width="170" Margin="0,0,10,0">
                <TextBox x:Name="CleanSearch"/>
                <TextBlock x:Name="CleanSearchHint" Text="搜索清理项…" Foreground="{DynamicResource TextDim}" FontSize="12.5"
                           Margin="11,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
              </Grid>
              <Button x:Name="BtnScanJunk" Content="扫描可清理的垃圾" Style="{StaticResource AccentButton}"/>
              <Button x:Name="BtnPickCleanRec" Content="勾选推荐项"/>
              <Button x:Name="BtnPickCleanNone" Content="全部不选"/>
              <TextBlock x:Name="TotalJunkText" Text="还没扫描" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="CleanPanel" Margin="0,0,10,0"/>
            </ScrollViewer>
            <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0">
              <Button x:Name="BtnClean" Content="开始清理选中项" Style="{StaticResource AccentButton}" Padding="20,9"/>
              <TextBlock x:Name="CleanSelCount" Text="" Foreground="{DynamicResource TextDim}" FontSize="12.5"
                         VerticalAlignment="Center" Margin="6,0,0,0"/>
            </StackPanel>
          </Grid>
          <Border Grid.Column="1" Background="{DynamicResource PanelBg}" Margin="8,14,16,14" CornerRadius="10" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="1">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18,16">
              <StackPanel x:Name="CleanDetail"/>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <!-- 第三页：日常维护 -->
      <TabItem Header="日常维护">
        <Grid Margin="16,14,16,14">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="480"/>
          </Grid.ColumnDefinitions>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,10,0">
            <StackPanel x:Name="MaintainPanel"/>
          </ScrollViewer>
          <Border Grid.Column="1" Background="{DynamicResource PanelBg}" CornerRadius="10" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="1">
            <Grid Margin="16,14,16,14">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0">
                <TextBlock Text="大文件查找" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextDim}" Margin="0,6,0,0"
                           Text="「我的 C 盘到底被什么占满了」—— 点一个盘符开始扫描，列出最大的 40 个文件。只列出来给你看，不会自动删任何东西。扫描要一两分钟。"/>
                <WrapPanel x:Name="BigFileDrives" Margin="0,10,0,6"/>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,6,0,0">
                <StackPanel x:Name="BigFilePanel"/>
              </ScrollViewer>
            </Grid>
          </Border>
        </Grid>
      </TabItem>

      <!-- 第四页：弹窗排查 -->
      <TabItem Header="弹窗排查">
        <Grid Margin="16,14,16,14">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="470"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0" Margin="0,0,10,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Margin="0,0,0,10">
              <TextBlock TextWrapping="Wrap" FontSize="12.5" Foreground="{DynamicResource TextMid}"
                         Text="黑框一闪而过、一次弹好几个 —— 那是有程序在后台调用命令行但没把窗口藏好。这里会把所有「会在后台执行命令」的地方扫一遍，按可疑程度排序。"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnInspect" Content="开始扫描" Style="{StaticResource AccentButton}" Padding="20,9"/>
                <Button x:Name="BtnInspectFilter" Content="只看会弹黑框的"/>
                <TextBlock x:Name="InspectSummary" Text="还没扫描" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="10,0,0,0" FontSize="12"/>
              </StackPanel>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="InspectPanel"/>
            </ScrollViewer>
          </Grid>
          <Border Grid.Column="1" Background="{DynamicResource PanelBg}" CornerRadius="10" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="1">
            <Grid Margin="16,14,16,14">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0">
                <TextBlock Text="抓现行" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextDim}" Margin="0,6,0,0"
                           Text="左边扫的是「开机会自动跑什么」。但弹窗也可能来自某个已经在运行的程序定期开的子进程——那种情况扫任何自启位置都找不到。这里直接盯「新建进程」，不管它藏在哪都跑不掉。"/>
                <Border Background="{DynamicResource PanelBg}" CornerRadius="6" Padding="11,9" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Text="① 实时监控（最快，立等可取）" FontSize="12.5" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/>
                    <TextBlock TextWrapping="Wrap" FontSize="11.5" Foreground="{DynamicResource TextDim}" Margin="0,4,0,0"
                               Text="点「开始」后正常用电脑，等黑框出现。出现的瞬间就会记下来是谁开的、它的父进程是谁。"/>
                    <WrapPanel Margin="0,8,0,0">
                      <Button x:Name="BtnWatchStart" Content="▶ 开始监控" Style="{StaticResource AccentButton}"/>
                      <Button x:Name="BtnWatchStop" Content="■ 停止" IsEnabled="False"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Background="{DynamicResource PanelBg}" CornerRadius="6" Padding="11,9" Margin="0,8,0,0">
                  <StackPanel>
                    <TextBlock Text="② 持续记录（关掉工具也在记）" FontSize="12.5" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/>
                    <TextBlock TextWrapping="Wrap" FontSize="11.5" Foreground="{DynamicResource TextDim}" Margin="0,4,0,0"
                               Text="打开系统自带的进程创建审核，之后随时回来查，带完整命令行。适合「弹窗不定时、蹲不到」的情况。"/>
                    <WrapPanel Margin="0,8,0,0">
                      <Button x:Name="BtnProcAudit" Content="开启持续记录"/>
                      <Button x:Name="BtnProcLog" Content="查看进程记录"/>
                      <Button x:Name="BtnRecentRuns" Content="查看任务记录"/>
                      <Button x:Name="BtnEnableTaskLog" Content="开启任务记录"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <TextBlock x:Name="WatchStatus" Text="" FontSize="12" Foreground="#7A6B45" Margin="0,9,0,0" TextWrapping="Wrap"/>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,6,0,0">
                <StackPanel x:Name="RecentRunPanel"/>
              </ScrollViewer>
            </Grid>
          </Border>
        </Grid>
      </TabItem>

      <!-- 第五页：启动项管理 -->
      <TabItem Header="启动项管理">
        <Grid Margin="16,14,16,14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BtnRefreshStartup" Content="刷新列表"/>
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="8,0,0,0" FontSize="12"
                       Text="勾掉复选框 = 禁止开机自启（立即生效，随时能勾回来，不删除任何文件）。标「看情况」的自己判断：认得、且需要它开机就在，就留着；完全没印象的可以先关一天试试。"/>
          </StackPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="StartupPanel" Margin="0,0,10,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- 自带软件：微软预装的 UWP 应用，哪些能删哪些不能 -->
      <TabItem Header="自带软件">
        <Grid Margin="16,14,16,14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Button x:Name="BtnRefreshAppx" Content="刷新列表"/>
            <Button x:Name="BtnCheckAppxSafe" Content="勾选「可以删」的"/>
            <Button x:Name="BtnUninstallAppx" Content="卸载勾选的应用" Style="{StaticResource AccentButton}"/>
            <TextBlock x:Name="AppxCounter" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="10,0,0,0" FontSize="12"/>
          </StackPanel>
          <Border Grid.Row="1" Background="{DynamicResource AccentTint}" CornerRadius="6" Padding="12,9" Margin="0,0,0,10">
            <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextMid}"
                       Text="卸载只针对当前用户，不动系统镜像 —— 任何一个删错了，都能去 Microsoft Store 搜名字原样装回来。标「必须留」的项勾不上，那些是删了会让系统出毛病的（应用商店、安全中心界面、运行库、解码器）。标「看情况」的先点开说明看完再决定，拿不准就别删。"/>
          </Border>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="AppxPanel" Margin="0,0,10,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- 个性化：换肤 -->
      <TabItem Header="个性化">
        <Grid Margin="16,14,16,14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="{DynamicResource AccentTint}" CornerRadius="6" Padding="12,9" Margin="0,0,0,12">
            <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextMid}"
                       Text="换肤只改界面的底色、卡片和主色。绿/黄/红那几个状态标签的颜色是故意不跟着变的 —— 「高危」永远是红的，不能因为换了皮肤看错。选好立刻生效，下次打开自动记住。"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="ThemePanel" Margin="0,0,10,0"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- 第四页：系统体检 -->
      <TabItem Header="系统体检">
        <Grid Margin="16,14,16,14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BtnHealthScan" Content="重新体检" Style="{StaticResource AccentButton}"/>
            <Button x:Name="BtnFpsDiag" Content="★ 为什么我帧数没变？" Style="{StaticResource AccentButton}"/>
            <Button x:Name="BtnAddExclusion" Content="把游戏文件夹加入杀毒白名单"/>
            <Button x:Name="BtnSfc" Content="检查系统文件完整性"/>
            <Button x:Name="BtnCopyReport" Content="复制体检报告"/>
            <Button x:Name="BtnExportReport" Content="导出诊断报告到桌面"/>
          </StackPanel>
          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="460"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="{DynamicResource PanelBg}" CornerRadius="10" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="1" Margin="0,0,10,0">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,14">
                <StackPanel x:Name="InfoPanel"/>
              </ScrollViewer>
            </Border>
            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="AdvicePanel" Margin="0,0,10,0"/>
            </ScrollViewer>
          </Grid>
        </Grid>
      </TabItem>

      <!-- 第五页：操作日志 -->
      <TabItem Header="操作日志">
        <Grid Margin="16,14,16,14">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="BtnOpenBackup" Content="打开备份 / 日志文件夹"/>
            <TextBlock Text="所有修改的原始值都保存在备份文件夹里，「还原」功能依赖它，请不要删除。"
                       Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="8,0,0,0" FontSize="12"/>
          </StackPanel>
          <TextBox Grid.Row="1" x:Name="LogBox" IsReadOnly="True" AcceptsReturn="True"
                   Background="{DynamicResource NeutralTint}" Foreground="{DynamicResource TextMid}" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="1"
                   FontFamily="Consolas, Microsoft YaHei UI" FontSize="12" Padding="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- ========== 底部状态栏 ========== -->
    <Border Grid.Row="2" Background="{DynamicResource CardBg}" Padding="20,9" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="StatusText" Text="就绪" Foreground="{DynamicResource TextDim}" FontSize="12"
                   TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
        <ProgressBar Grid.Column="1" x:Name="BusyBar" Width="150" Height="3" IsIndeterminate="True"
                     Visibility="Collapsed" VerticalAlignment="Center" Margin="14,0,0,0"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

# 把所有命名控件收集到 $Script:UI
$Script:UI = @{}
foreach ($n in @(
        'SubTitle', 'VerBadge', 'ChkRestorePoint', 'BtnRestorePoint', 'Tabs',
        'TweakPanel', 'TweakDetail', 'BtnPickRecommended', 'BtnPickNone', 'BtnRescan', 'PresetBar',
        'BtnApplySelected', 'BtnRevertSelected', 'BtnRevertAll',
        'CleanPanel', 'CleanDetail', 'BtnScanJunk', 'BtnPickCleanRec', 'BtnPickCleanNone', 'BtnClean', 'TotalJunkText',
        'TweakSearch', 'TweakSearchHint', 'TweakSelCount', 'CleanSearch', 'CleanSearchHint', 'CleanSelCount',
        'StartupPanel', 'BtnRefreshStartup',
        'AppxPanel', 'BtnRefreshAppx', 'BtnCheckAppxSafe', 'BtnUninstallAppx', 'AppxCounter',
        'ThemePanel',
        'MaintainPanel', 'BigFileDrives', 'BigFilePanel',
        'InspectPanel', 'BtnInspect', 'BtnInspectFilter', 'InspectSummary',
        'RecentRunPanel', 'BtnRecentRuns', 'BtnEnableTaskLog',
        'BtnWatchStart', 'BtnWatchStop', 'BtnProcAudit', 'BtnProcLog', 'WatchStatus',
        'InfoPanel', 'AdvicePanel', 'BtnHealthScan', 'BtnFpsDiag', 'BtnAddExclusion', 'BtnSfc', 'BtnCopyReport', 'BtnExportReport',
        'LogBox', 'BtnOpenBackup', 'StatusText', 'BusyBar')) {
    $Script:UI[$n] = $Script:Window.FindName($n)
}
$Script:LogBox = $Script:UI.LogBox

# ---------------------------------------------------------------------
#  5. 性能优化页
# ---------------------------------------------------------------------
$Script:Tweaks = Get-AllTweaks
$Script:TweakRows = @{}     # Id -> @{ Check; Badge; Tweak }
$Script:GameNotes = Get-GameNotes
$Script:Presets = Get-GamePresets

function Build-PresetUI {
    <#
      顶部那几排预设按钮。按 Group 分行 —— 游戏预设和浏览器瘦身
      是两回事，混成一堆按钮会让人不知道该点哪个。
    #>
    $bar = $Script:UI.PresetBar
    $bar.Children.Clear()

    $groups = @()
    foreach ($ps in $Script:Presets) { if ($groups -notcontains $ps.Group) { $groups += $ps.Group } }

    foreach ($grp in $groups) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Thick 0 0 0 2
        $lbl = New-TextBlock -Text $grp -Size 11.5 -Bold $true -Color '#55606F'
        $lbl.Width = 68
        $lbl.VerticalAlignment = 'Center'
        $row.Children.Add($lbl) | Out-Null
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($ps in ($Script:Presets | Where-Object { $_.Group -eq $grp })) {
            $b = New-Object System.Windows.Controls.Button
            $b.Content = $ps.Name
            $b.Tag = $ps
            $b.Margin = New-Thick 0 0 8 6
            # 每组的主推项用强调色：游戏是三合一，浏览器是深度档
            if ($ps.Id -in 'FPS3', 'BROW2') {
                try { $b.Style = $Script:Window.FindResource('AccentButton') } catch { }
            }
            $b.Add_Click({ Select-Preset $this.Tag })
            $wrap.Children.Add($b) | Out-Null
        }
        $row.Children.Add($wrap) | Out-Null
        $bar.Children.Add($row) | Out-Null
    }
}

function Select-Preset {
    # 先清掉搜索框：不然点完预设会出现「已勾选 18 项，但列表里只看得见 3 项」的困惑
    <#
      点预设：把该预设包含的项目全部勾上，其余取消勾选，
      然后在右边详情栏把这个预设讲清楚。
      注意：不会自动应用，还是要你自己点「应用选中的优化」。
    #>
    param($Preset)
    if ($Script:UI.TweakSearch.Text) { $Script:UI.TweakSearch.Text = '' }
    $n = 0
    foreach ($tw in $Script:Tweaks) {
        $row = $Script:TweakRows[$tw.Id]
        if (-not $row) { continue }
        $want = ($Preset.Ids -contains $tw.Id)
        if ($want -and -not $row.Check.IsEnabled) { continue }   # 本机不适用的项跳过
        $row.Check.IsChecked = $want
        if ($want) { $n++ }
    }
    Update-TweakSelCount
    Show-PresetDetail $Preset $n
    Set-Status ("已按「{0}」勾选 {1} 项 —— 确认右边说明后，点下面的「应用选中的优化」" -f $Preset.Name, $n)
}

function Show-PresetDetail {
    param($Preset, [int]$Count)
    $p = $Script:UI.TweakDetail
    $p.Children.Clear()

    $p.Children.Add((New-TextBlock -Text $Preset.Name -Size 17 -Bold $true -Wrap $true)) | Out-Null

    $sub = New-TextBlock -Text ("共勾选 {0} 项 · 这只是勾选，还没有应用" -f $Count) -Size 12 -Color '#7A6B45'
    $sub.Margin = New-Thick 0 8 0 12
    $p.Children.Add($sub) | Out-Null

    $p.Children.Add((New-TextBlock -Text (Format-Reflow $Preset.Desc) -Size 12.5 -Color '#565349' -Wrap $true)) | Out-Null

    # 兼容性提醒
    $warn = @(Get-SelectionWarnings -TweakIds $Preset.Ids)
    if ($warn.Count -gt 0) {
        $wc = New-Object System.Windows.Controls.Border
        $wc.Background = Get-Brush '#F0EADC'
        $wc.BorderBrush = Get-Brush '#7A6B45'
        $wc.BorderThickness = New-Thick 3 0 0 0
        $wc.CornerRadius = New-Object System.Windows.CornerRadius 4
        $wc.Padding = New-Thick 12 10 12 10
        $wc.Margin = New-Thick 0 16 0 0
        $wsp = New-Object System.Windows.Controls.StackPanel
        $wsp.Children.Add((New-TextBlock -Text '兼容性提醒' -Size 12.5 -Bold $true -Color '#7A6B45')) | Out-Null
        foreach ($w in $warn) {
            $t = New-TextBlock -Text $w -Size 12 -Color '#4A4842' -Wrap $true
            $t.Margin = New-Thick 0 6 0 0
            $wsp.Children.Add($t) | Out-Null
        }
        $wc.Child = $wsp
        $p.Children.Add($wc) | Out-Null
    }

    # 这个预设包含哪些项目
    $lt = New-TextBlock -Text '包含的项目（点左边任意一项可以看它的详细说明）' -Size 13 -Bold $true -Color '#55606F'
    $lt.Margin = New-Thick 0 18 0 8
    $p.Children.Add($lt) | Out-Null
    foreach ($id in $Preset.Ids) {
        $tw = $Script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $tw) { continue }
        $t = New-TextBlock -Text ("· " + $tw.Name) -Size 12 -Color '#5E5B54' -Wrap $true
        $t.Margin = New-Thick 0 0 0 3
        $p.Children.Add($t) | Out-Null
    }
}

function Show-TweakDetail {
    param($Tweak)
    $p = $Script:UI.TweakDetail
    $p.Children.Clear()
    if ($Tweak -and $Script:TweakRows[$Tweak.Id]) { Select-Card $Script:TweakRows[$Tweak.Id].Card } else { Select-Card $null }
    if (-not $Tweak) {
        $p.Children.Add((New-TextBlock -Text '怎么用这一页' -Size 16 -Bold $true)) | Out-Null
        $tip = New-TextBlock -Wrap $true -Size 12.5 -Color '#565349' -Text @'

最省事的办法：点上面的「★ 三合一 FPS 通用」，它会自动勾好
对 CS2 / 无畏契约 / 三角洲行动 三个游戏都有好处的项目，
然后点左下角「应用选中的优化」。

想自己挑，就点左边任意一项 —— 这里会显示：
· 这一项是干什么的、原理是什么
· 对 CS2、无畏契约、三角洲【分别】有什么影响
· 代价和风险是什么、出问题怎么还原

设计原则：所有预设都只做「三个游戏都不吃亏」的事。
任何可能让其中一个变差的项目（比如全局关闭全屏优化），
一律不放进预设，只留给你自己单独测。
'@
        $p.Children.Add($tip) | Out-Null
        return
    }

    $p.Children.Add((New-TextBlock -Text $Tweak.Name -Size 17 -Bold $true -Wrap $true)) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = New-Thick 0 10 0 12
    $rc = Get-RiskColors $Tweak.Risk
    $wrap.Children.Add((New-Badge -Text $Tweak.Category -Fg '#6E6B63' -Bg '#E8E7E2')) | Out-Null
    $wrap.Children.Add((New-Badge -Text ("风险 " + $Tweak.Risk) -Fg $rc.Fg -Bg $rc.Bg)) | Out-Null
    if ($Tweak.Reboot) { $wrap.Children.Add((New-Badge -Text '需要重启生效' -Fg '#7A6B45' -Bg '#EDE7D9')) | Out-Null }
    if ($Tweak.Recommended) { $wrap.Children.Add((New-Badge -Text '推荐' -Fg '#55606F' -Bg '#E4E7EC')) | Out-Null }
    $p.Children.Add($wrap) | Out-Null

    $p.Children.Add((New-TextBlock -Text ("预期效果：" + $Tweak.Effect) -Size 12.5 -Color '#4A4842' -Wrap $true)) | Out-Null

    # ---- 对三个 FPS 游戏分别的影响 ----
    $gt = New-TextBlock -Text '对你玩的三个游戏分别意味着什么' -Size 13 -Bold $true -Color '#55606F'
    $gt.Margin = New-Thick 0 16 0 8
    $p.Children.Add($gt) | Out-Null

    foreach ($g in $Script:GAME_LIST) {
        $v = Get-TweakGameVerdict -Notes $Script:GameNotes -TweakId $Tweak.Id -GameKey $g.Key
        $col = Get-VerdictColor $v.V

        $gc = New-Object System.Windows.Controls.Border
        $gc.Background = Get-Brush '#FBFAF8'
        $gc.BorderBrush = Get-Brush $col
        $gc.BorderThickness = New-Thick 3 0 0 0
        $gc.CornerRadius = New-Object System.Windows.CornerRadius 4
        $gc.Padding = New-Thick 11 8 11 9
        $gc.Margin = New-Thick 0 0 0 6

        $gsp = New-Object System.Windows.Controls.StackPanel
        $hdr = New-Object System.Windows.Controls.StackPanel
        $hdr.Orientation = 'Horizontal'
        $gname = New-TextBlock -Text $g.Short -Size 12.5 -Bold $true
        $hdr.Children.Add($gname) | Out-Null
        $vb = New-Badge -Text $v.V -Fg $col -Bg (Get-TintBg $col)
        $vb.Margin = New-Thick 8 0 0 0
        $hdr.Children.Add($vb) | Out-Null
        $gsp.Children.Add($hdr) | Out-Null

        $gn = New-TextBlock -Text $v.N -Size 12 -Color '#5E5B54' -Wrap $true
        $gn.Margin = New-Thick 0 4 0 0
        $gsp.Children.Add($gn) | Out-Null

        $gc.Child = $gsp
        $p.Children.Add($gc) | Out-Null
    }

    $sep = New-Object System.Windows.Controls.Border
    $sep.Height = 1; $sep.Background = Get-Brush '#DDDBD5'; $sep.Margin = New-Thick 0 14 0 12
    $p.Children.Add($sep) | Out-Null

    $p.Children.Add((New-TextBlock -Text (Format-Reflow $Tweak.Detail) -Size 12.5 -Color '#565349' -Wrap $true)) | Out-Null

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = New-Thick 0 18 0 0
    $bApply = New-Object System.Windows.Controls.Button
    $bApply.Content = '只应用这一项'; $bApply.Tag = $Tweak
    $bApply.Add_Click({ Invoke-ApplyTweaks @($this.Tag) })
    $bRevert = New-Object System.Windows.Controls.Button
    $bRevert.Content = '只还原这一项'; $bRevert.Tag = $Tweak
    $bRevert.Add_Click({ Invoke-RevertTweaks @($this.Tag) })
    $bar.Children.Add($bApply) | Out-Null
    $bar.Children.Add($bRevert) | Out-Null
    $p.Children.Add($bar) | Out-Null
}

function Update-TweakSelCount {
    <# 底部实时显示「已勾选几项」——不然勾了一堆，点应用之前完全不知道会动多少东西 #>
    $n = @(Get-CheckedTweaks).Count
    $Script:UI.TweakSelCount.Text = if ($n -gt 0) { "已勾选 $n 项" } else { '还没勾选任何项目' }
    $Script:UI.BtnApplySelected.IsEnabled = ($n -gt 0)
    $Script:UI.BtnRevertSelected.IsEnabled = ($n -gt 0)
}

function Update-TweakFilter {
    <#
      搜索框筛选。31 个优化项靠滚是很难找的，
      按「名称 / 分类 / 效果 / 说明」一起匹配，整条分类都没命中就连标题一起隐藏。
    #>
    $q = "$($Script:UI.TweakSearch.Text)".Trim()
    $Script:UI.TweakSearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }

    foreach ($cat in $Script:TweakCatOrder) {
        $shown = 0
        foreach ($tw in ($Script:Tweaks | Where-Object { $_.Category -eq $cat })) {
            $row = $Script:TweakRows[$tw.Id]
            if (-not $row) { continue }
            $hit = (-not $q) -or
                   ($tw.Name -like "*$q*") -or ($tw.Category -like "*$q*") -or
                   ($tw.Effect -like "*$q*") -or ($tw.Detail -like "*$q*")
            $visible = $hit -and (-not $Script:TweakCatCollapsed[$cat])
            $row.Card.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
            if ($hit) { $shown++ }
        }
        $h = $Script:TweakCatHeaders[$cat]
        if ($h) {
            $h.Border.Visibility = if ($shown -gt 0) { 'Visible' } else { 'Collapsed' }
            $h.Count.Text = "$shown"
        }
    }
}

function Build-TweakUI {
    $panel = $Script:UI.TweakPanel
    $panel.Children.Clear()
    $Script:TweakRows = @{}
    $Script:TweakCatHeaders = @{}
    $Script:TweakCatCollapsed = @{}
    $Script:TweakCatOrder = @()

    $cats = @()
    foreach ($t in $Script:Tweaks) { if ($cats -notcontains $t.Category) { $cats += $t.Category } }
    $Script:TweakCatOrder = $cats

    foreach ($cat in $cats) {
        $Script:TweakCatCollapsed[$cat] = $false

        # 分类标题做成可点击的一行：显示条数，点一下折叠/展开整组
        $hb = New-Object System.Windows.Controls.Border
        $hb.Padding = New-Thick 2 9 2 7
        $hb.Margin = New-Thick 0 8 0 4
        $hb.Background = Get-Brush '#00FFFFFF'
        $hb.Cursor = 'Hand'
        $hrow = New-Object System.Windows.Controls.StackPanel
        $hrow.Orientation = 'Horizontal'
        $arrow = New-TextBlock -Text '▾' -Size 11 -Color '#55606F'
        $arrow.Margin = New-Thick 0 1 6 0
        $hrow.Children.Add($arrow) | Out-Null
        $hrow.Children.Add((New-TextBlock -Text $cat -Size 14 -Bold $true -Color '#55606F')) | Out-Null
        $cnt = New-TextBlock -Text '' -Size 11.5 -Color '#6E6B63'
        $cnt.Margin = New-Thick 8 2 0 0
        $hrow.Children.Add($cnt) | Out-Null
        $hb.Child = $hrow
        $hb.Tag = $cat
        $hb.Add_MouseLeftButtonUp({
                $c = $this.Tag
                $Script:TweakCatCollapsed[$c] = -not $Script:TweakCatCollapsed[$c]
                $Script:TweakCatHeaders[$c].Arrow.Text = if ($Script:TweakCatCollapsed[$c]) { '▸' } else { '▾' }
                Update-TweakFilter
            })
        $panel.Children.Add($hb) | Out-Null
        $Script:TweakCatHeaders[$cat] = @{ Border = $hb; Arrow = $arrow; Count = $cnt }

        foreach ($tw in ($Script:Tweaks | Where-Object { $_.Category -eq $cat })) {
            $card = New-ListCard
            $card.Tag = $tw
            $card.Add_MouseLeftButtonUp({ Show-TweakDetail $this.Tag })

            $g = New-Object System.Windows.Controls.Grid
            foreach ($w in @('Auto', '*', 'Auto')) {
                $cd = New-Object System.Windows.Controls.ColumnDefinition
                $cd.Width = [System.Windows.GridLength]::Auto
                if ($w -eq '*') { $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
                $g.ColumnDefinitions.Add($cd)
            }

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Margin = New-Thick 0 0 2 0
            $cb.Tag = $tw
            $cb.Add_Click({ Show-TweakDetail $this.Tag; Update-TweakSelCount })
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)
            $g.Children.Add($cb) | Out-Null

            $sp = New-Object System.Windows.Controls.StackPanel
            $nameTb = New-TextBlock -Text $tw.Name -Size 13.5 -Bold $true
            $nameTb.TextWrapping = 'Wrap'
            $sp.Children.Add($nameTb) | Out-Null
            $meta = New-TextBlock -Text ("风险 {0}  ·  {1}" -f $tw.Risk, $tw.Effect) -Size 11.5 -Color '#6E6B63'
            $meta.TextWrapping = 'Wrap'
            $meta.Margin = New-Thick 0 3 0 0
            $sp.Children.Add($meta) | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($sp, 1)
            $g.Children.Add($sp) | Out-Null

            # 状态做成固定宽度的「药丸」，这样一列下来右边缘是对齐的；
            # 原来是长度不一的纯文字（已优化✓ / 未优化 / 不适用），看着参差不齐
            $pill = New-Object System.Windows.Controls.Border
            $pill.MinWidth = 66
            $pill.CornerRadius = New-Object System.Windows.CornerRadius 10
            $pill.Padding = New-Thick 9 3 9 4
            $pill.Margin = New-Thick 10 0 0 0
            $pill.VerticalAlignment = 'Center'
            $badge = New-TextBlock -Text '检测中' -Size 11.5 -Color '#6E6B63'
            $badge.HorizontalAlignment = 'Center'
            $pill.Child = $badge
            [System.Windows.Controls.Grid]::SetColumn($pill, 2)
            $g.Children.Add($pill) | Out-Null

            $card.Child = $g
            $panel.Children.Add($card) | Out-Null

            $Script:TweakRows[$tw.Id] = @{ Check = $cb; Badge = $badge; Pill = $pill; Tweak = $tw; Card = $card }
        }
    }
    Show-TweakDetail $null
}

function Update-TweakStates {
    param([bool]$PreselectRecommended = $false)
    Set-Busy $true
    Set-Status '正在检测每一项的当前状态…'
    foreach ($tw in $Script:Tweaks) {
        $row = $Script:TweakRows[$tw.Id]
        if (-not $row) { continue }
        $available = Test-TweakAvailable $tw
        if (-not $available) {
            $row.Badge.Text = '不适用'
            $row.Badge.Foreground = Get-Brush '#6E6B63'
            $row.Pill.Background = Get-Brush '#EAE9E3'
            $row.Check.IsEnabled = $false
            $row.Check.IsChecked = $false
            $row.Card.Opacity = 0.55
            continue
        }
        $row.Check.IsEnabled = $true
        $row.Card.Opacity = 1.0
        $applied = Test-TweakApplied $tw
        if ($applied) {
            $row.Badge.Text = '已优化 ✓'
            $row.Badge.Foreground = Get-Brush '#556B54'
            $row.Pill.Background = Get-Brush '#DCE8DA'
        } else {
            $row.Badge.Text = '未优化'
            $row.Badge.Foreground = Get-Brush '#6E6B63'
            $row.Pill.Background = Get-Brush '#EAE9E3'
        }
        if ($PreselectRecommended) {
            $row.Check.IsChecked = ($tw.Recommended -and -not $applied)
        }
        Sync-UI
    }
    Set-Busy $false
    Update-TweakSelCount
    Update-TweakFilter
    Set-Status '就绪'
}

function Get-CheckedTweaks {
    $sel = @()
    foreach ($tw in $Script:Tweaks) {
        $row = $Script:TweakRows[$tw.Id]
        if ($row -and $row.Check.IsChecked -and $row.Check.IsEnabled) { $sel += $tw }
    }
    return $sel
}

function Invoke-ApplyTweaks {
    param($List)
    $List = @($List)
    if ($List.Count -eq 0) {
        [System.Windows.MessageBox]::Show('还没有勾选任何项目。左边勾上想开的优化，或者点「勾选推荐项」。', '电脑调优助手') | Out-Null
        return
    }
    # 项目太多时只列前 12 个，免得弹窗长到看不完
    $shown = @($List | Select-Object -First 12 | ForEach-Object { '· ' + $_.Name })
    if ($List.Count -gt 12) { $shown += ("· …… 以及其余 {0} 项" -f ($List.Count - 12)) }
    $names = $shown -join "`r`n"

    $risky = @($List | Where-Object { $_.Risk -eq '高' })
    $warn = ''
    if ($risky.Count -gt 0) {
        $warn = "`r`n`r`n⚠ 其中有 $($risky.Count) 项标记为「高风险」，会降低系统安全性或影响某些功能。请确认你已经读过它们的说明。"
    }

    # 游戏兼容性检查：确认这一批不会让 CS2 / 无畏契约 / 三角洲 里的任何一个吃亏
    $gw = @(Get-SelectionWarnings -TweakIds @($List | ForEach-Object { $_.Id }))
    if ($gw.Count -gt 0) {
        $warn += "`r`n`r`n【游戏兼容性】`r`n" + (($gw | ForEach-Object { '· ' + $_ }) -join "`r`n")
    }

    $r = [System.Windows.MessageBox]::Show("即将应用以下 $($List.Count) 项优化：`r`n`r`n$names$warn`r`n`r`n所有修改都会先备份原值，之后随时可以还原。确定继续吗？",
        '确认应用', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    if ($Script:UI.ChkRestorePoint.IsChecked) {
        Set-Status '正在创建系统还原点（可能需要 10~60 秒）…'
        New-SystemRestorePoint -Description 'PC调优助手-应用优化前' | Out-Null
    }

    $ok = 0
    foreach ($t in $List) {
        Set-Status ("正在应用：{0}" -f $t.Name)
        if (Invoke-TweakApply $t) { $ok++ }
        Sync-UI
    }
    Update-TweakStates
    $needReboot = @($List | Where-Object { $_.Reboot }).Count -gt 0
    $msg = "完成：成功应用 $ok / $($List.Count) 项。"
    if ($needReboot) { $msg += "`r`n`r`n其中有些项目需要重启电脑才会生效。" }
    Set-Status $msg
    [System.Windows.MessageBox]::Show($msg, '电脑调优助手') | Out-Null
}

function Invoke-RevertTweaks {
    param($List)
    $List = @($List)
    if ($List.Count -eq 0) {
        [System.Windows.MessageBox]::Show('还没有勾选任何项目。', '电脑调优助手') | Out-Null
        return
    }
    $names = ($List | ForEach-Object { '· ' + $_.Name }) -join "`r`n"
    $r = [System.Windows.MessageBox]::Show("即将把以下 $($List.Count) 项还原为修改前的状态：`r`n`r`n$names`r`n`r`n确定吗？",
        '确认还原', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    $ok = 0
    foreach ($t in $List) {
        Set-Status ("正在还原：{0}" -f $t.Name)
        if (Invoke-TweakRevert $t) { $ok++ }
        Sync-UI
    }
    Update-TweakStates
    $msg = "完成：成功还原 $ok / $($List.Count) 项。部分项目需要重启才会恢复。"
    Set-Status $msg
    [System.Windows.MessageBox]::Show($msg, '电脑调优助手') | Out-Null
}

# ---------------------------------------------------------------------
#  6. 垃圾清理页
# ---------------------------------------------------------------------
$Script:CleanItems = Get-CleanupItems
$Script:CleanRows = @{}

function Show-CleanDetail {
    param($Item)
    $p = $Script:UI.CleanDetail
    $p.Children.Clear()
    if ($Item -and $Script:CleanRows[$Item.Id]) { Select-Card $Script:CleanRows[$Item.Id].Card } else { Select-Card $null }
    if (-not $Item) {
        $p.Children.Add((New-TextBlock -Text "点左边任意一项，这里会说明它清的是什么、安不安全。`r`n`r`n建议先点「扫描可清理的垃圾」看看各项能清多少，再决定。" -Color '#6E6B63' -Wrap $true)) | Out-Null
        return
    }
    $p.Children.Add((New-TextBlock -Text $Item.Name -Size 17 -Bold $true -Wrap $true)) | Out-Null
    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = New-Thick 0 10 0 12
    $rc = Get-RiskColors $Item.Risk
    $wrap.Children.Add((New-Badge -Text ("风险 " + $Item.Risk) -Fg $rc.Fg -Bg $rc.Bg)) | Out-Null
    if ($Item.Recommended) { $wrap.Children.Add((New-Badge -Text '推荐' -Fg '#55606F' -Bg '#E4E7EC')) | Out-Null }
    $p.Children.Add($wrap) | Out-Null
    $p.Children.Add((New-TextBlock -Text (Format-Reflow $Item.Detail) -Size 12.5 -Color '#565349' -Wrap $true)) | Out-Null
}

function Update-CleanSelCount {
    $n = 0
    foreach ($r in $Script:CleanRows.Values) { if ($r.Check.IsChecked) { $n++ } }
    $Script:UI.CleanSelCount.Text = if ($n -gt 0) { "已勾选 $n 项" } else { '还没勾选任何项目' }
    $Script:UI.BtnClean.IsEnabled = ($n -gt 0)
}

function Update-CleanFilter {
    $q = "$($Script:UI.CleanSearch.Text)".Trim()
    $Script:UI.CleanSearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    foreach ($it in $Script:CleanItems) {
        $row = $Script:CleanRows[$it.Id]
        if (-not $row) { continue }
        $hit = (-not $q) -or ($it.Name -like "*$q*") -or ($it.Detail -like "*$q*")
        $row.Card.Visibility = if ($hit) { 'Visible' } else { 'Collapsed' }
    }
}

function Build-CleanUI {
    $panel = $Script:UI.CleanPanel
    $panel.Children.Clear()
    $Script:CleanRows = @{}

    foreach ($it in $Script:CleanItems) {
        $card = New-ListCard
        $card.Tag = $it
        $card.Add_MouseLeftButtonUp({ Show-CleanDetail $this.Tag })

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @('Auto', '*', 'Auto')) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::Auto
            if ($w -eq '*') { $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = New-Thick 0 0 2 0
        $cb.IsChecked = [bool]$it.Recommended
        $cb.Tag = $it
        $cb.Add_Click({ Show-CleanDetail $this.Tag; Update-CleanSelCount })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $g.Children.Add($cb) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        $nameTb = New-TextBlock -Text $it.Name -Size 13.5 -Bold $true
        $nameTb.TextWrapping = 'Wrap'
        $sp.Children.Add($nameTb) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null

        $size = New-TextBlock -Text '—' -Size 13 -Color '#6E6B63' -Bold $true
        $size.VerticalAlignment = 'Center'
        $size.Margin = New-Thick 10 0 0 0
        [System.Windows.Controls.Grid]::SetColumn($size, 2)
        $g.Children.Add($size) | Out-Null

        $card.Child = $g
        $panel.Children.Add($card) | Out-Null
        $Script:CleanRows[$it.Id] = @{ Check = $cb; Size = $size; Item = $it; Card = $card }
    }
    Show-CleanDetail $null
}

function Invoke-ScanJunk {
    Set-Busy $true
    $total = 0
    foreach ($it in $Script:CleanItems) {
        $row = $Script:CleanRows[$it.Id]
        Set-Status ("正在扫描：{0}" -f $it.Name)
        $row.Size.Text = '扫描中…'
        Sync-UI
        $sz = Measure-CleanupItem $it
        if ($sz -lt 0) {
            $row.Size.Text = '执行后才知道'
            $row.Size.Foreground = Get-Brush '#6E6B63'
        } elseif ($sz -eq 0) {
            $row.Size.Text = '无'
            $row.Size.Foreground = Get-Brush '#6E6B63'
        } else {
            $row.Size.Text = Format-Size $sz
            $row.Size.Foreground = Get-Brush '#7A6B45'
            $total += $sz
        }
        Sync-UI
    }
    $Script:UI.TotalJunkText.Text = ("全部加起来大约可以清理 {0}" -f (Format-Size $total))
    Set-Busy $false
    Set-Status '扫描完成'
    Write-Log ("垃圾扫描完成，合计约 {0}" -f (Format-Size $total)) '信息'
}

function Invoke-CleanSelected {
    $sel = @()
    foreach ($it in $Script:CleanItems) {
        $row = $Script:CleanRows[$it.Id]
        if ($row -and $row.Check.IsChecked) { $sel += $it }
    }
    if ($sel.Count -eq 0) {
        [System.Windows.MessageBox]::Show('还没有勾选任何清理项。', '电脑调优助手') | Out-Null
        return
    }
    $names = ($sel | ForEach-Object { '· ' + $_.Name }) -join "`r`n"
    $r = [System.Windows.MessageBox]::Show(
        "即将清理以下 $($sel.Count) 项：`r`n`r`n$names`r`n`r`n建议先关闭浏览器和游戏平台客户端，正在使用的文件删不掉。`r`n清理不可撤销，确定继续吗？",
        '确认清理', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    Set-Busy $true
    $freed = 0
    $needExplorer = $false
    foreach ($it in $sel) {
        Set-Status ("正在清理：{0}" -f $it.Name)
        Sync-UI
        $f = Invoke-CleanupItem $it
        $freed += $f
        $row = $Script:CleanRows[$it.Id]
        $row.Size.Text = if ($f -gt 0) { '已清理' } else { '无可清理' }
        $row.Size.Foreground = Get-Brush '#556B54'
        if ($it.NeedExplorerRestart) { $needExplorer = $true }
        Sync-UI
    }
    if ($needExplorer) { Restart-ExplorerShell }
    Set-Busy $false

    $msg = "清理完成，共释放 $(Format-Size $freed) 硬盘空间。"
    Set-Status $msg
    Write-Log $msg '成功'
    [System.Windows.MessageBox]::Show($msg, '电脑调优助手') | Out-Null
}

# ---------------------------------------------------------------------
#  7. 启动项页
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#  个性化（换肤）页
# ---------------------------------------------------------------------
function New-ThemeSwatchRow {
    <# 一套皮肤的三个色块预览 #>
    param([string[]]$Colors)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $sp.Margin = New-Thick 0 8 0 0
    foreach ($c in $Colors) {
        $b = New-Object System.Windows.Controls.Border
        # ★ 这里必须直接 ConvertFromString，不能走 Get-Brush ★
        #   Get-Brush 会按当前皮肤做重映射，
        #   那样每个预览块都会被改成当前皮肤的颜色，六套皮肤长得一模一样。
        $b.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString($c))
        $b.Width = 46; $b.Height = 22
        $b.CornerRadius = New-Object System.Windows.CornerRadius 4
        $b.Margin = New-Thick 0 0 6 0
        $b.BorderBrush = Get-Brush '#DDDBD5'
        $b.BorderThickness = New-Thick 1
        $sp.Children.Add($b) | Out-Null
    }
    return $sp
}

function Build-ThemeUI {
    $panel = $Script:UI.ThemePanel
    $panel.Children.Clear()
    $cur = Get-ThemeSetting

    # ---------- 纯色皮肤 ----------
    $t1 = New-TextBlock -Text '纯色皮肤' -Size 15 -Bold $true
    $t1.Margin = New-Thick 0 0 0 10
    $panel.Children.Add($t1) | Out-Null

    $themes = Get-BuiltinThemes
    foreach ($name in $themes.Keys) {
        $th = $themes[$name]

        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#F6F5F2'
        $card.BorderBrush = if ($name -eq $cur.Name) { Get-Brush '#55606F' } else { Get-Brush '#E0DED8' }
        $card.BorderThickness = if ($name -eq $cur.Name) { New-Thick 2 } else { New-Thick 1 }
        $card.CornerRadius = New-Object System.Windows.CornerRadius 8
        $card.Padding = New-Thick 14 11 14 12
        $card.Margin = New-Thick 0 0 0 8
        $card.Cursor = 'Hand'
        $card.Tag = $name
        $card.Add_MouseLeftButtonUp({
                Set-AppTheme -Name $this.Tag -Image $Script:ThemeImage -Opacity $Script:ThemeOpacity
                Redraw-AllPages
                Set-Status "皮肤已换成「$($this.Tag)」"
            })

        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $head.Children.Add((New-TextBlock -Text $name -Size 13.5 -Bold $true)) | Out-Null
        if ($name -eq $cur.Name) {
            $bd = New-Badge -Text '使用中' -Fg '#55606F' -Bg '#E4E7EC'
            $bd.Margin = New-Thick 8 0 0 0
            $head.Children.Add($bd) | Out-Null
        }
        if (Test-ThemeIsDark $name) {
            $dk = New-Badge -Text '深色' -Fg '#6E6B63' -Bg '#E8E7E2'
            $dk.Margin = New-Thick 4 0 0 0
            $head.Children.Add($dk) | Out-Null
        }
        $sp.Children.Add($head) | Out-Null
        $sp.Children.Add((New-TextBlock -Text $th.Desc -Size 12 -Color '#6E6B63' -Wrap $true)) | Out-Null
        $sp.Children.Add((New-ThemeSwatchRow -Colors $th.Swatch)) | Out-Null

        $card.Child = $sp
        $panel.Children.Add($card) | Out-Null
    }

    # ---------- 自定义背景图 ----------
    $t2 = New-TextBlock -Text '用自己的图片当背景' -Size 15 -Bold $true
    $t2.Margin = New-Thick 0 18 0 8
    $panel.Children.Add($t2) | Out-Null

    $ic = New-Object System.Windows.Controls.Border
    $ic.Background = Get-Brush '#F6F5F2'
    $ic.BorderBrush = Get-Brush '#E0DED8'
    $ic.BorderThickness = New-Thick 1
    $ic.CornerRadius = New-Object System.Windows.CornerRadius 8
    $ic.Padding = New-Thick 14 12 14 14
    $isp = New-Object System.Windows.Controls.StackPanel

    $tip = New-TextBlock -Size 12 -Color '#6E6B63' -Wrap $true -Text (
        '选一张图铺在窗口背景上。图片会被复制到工具自己的文件夹里保存，' +
        '所以选完之后原图删掉、U 盘拔掉都不影响。' + "`r`n" +
        '建议选颜色比较淡、内容不太花的图 —— 太花的图会让上面的字看不清。' +
        '下面的「面板不透明度」就是用来调这个的：拉低一点图更明显，拉高一点字更清楚。')
    $tip.Margin = New-Thick 0 0 0 10
    $isp.Children.Add($tip) | Out-Null

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'

    $btnPick = New-Object System.Windows.Controls.Button
    $btnPick.Content = '选择图片…'
    $btnPick.Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = '选一张背景图'
            $dlg.Filter = '图片文件|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.webp|所有文件|*.*'
            if ($dlg.ShowDialog() -ne $true) { return }
            $saved = Copy-ThemeImage -SourcePath $dlg.FileName
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image $saved -Opacity $st.Opacity
            Redraw-AllPages
            Set-Status '背景图已设置'
        })
    $row.Children.Add($btnPick) | Out-Null

    $btnClear = New-Object System.Windows.Controls.Button
    $btnClear.Content = '取消背景图'
    $btnClear.Add_Click({
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image '' -Opacity $st.Opacity
            Redraw-AllPages
            Set-Status '已恢复纯色背景'
        })
    $row.Children.Add($btnClear) | Out-Null
    $isp.Children.Add($row) | Out-Null

    # 当前用的是哪张图
    # ★ PowerShell 5.1 里 if 不能当表达式用在参数位置上 ★
    #   写成 -Text (if (...) {...} else {...}) 会静默传进去一个 $null，
    #   然后在下一行 .Margin 上炸掉。先算到变量里再传。
    $nowText = '当前没有使用背景图'
    if ($cur.Image) { $nowText = "当前背景图：$($cur.Image)" }
    $now = New-TextBlock -Size 11.5 -Color '#6E6B63' -Wrap $true -Text $nowText
    $now.Margin = New-Thick 0 10 0 0
    $isp.Children.Add($now) | Out-Null

    # 不透明度滑块
    $ol = New-TextBlock -Size 12.5 -Bold $true -Text ('面板不透明度：{0}%' -f [int]($cur.Opacity * 100))
    $ol.Margin = New-Thick 0 14 0 4
    $isp.Children.Add($ol) | Out-Null

    $sld = New-Object System.Windows.Controls.Slider
    $sld.Minimum = 0.35; $sld.Maximum = 1.0
    $sld.Value = $cur.Opacity
    $sld.TickFrequency = 0.05
    $sld.IsSnapToTickEnabled = $true
    $sld.Width = 320
    $sld.HorizontalAlignment = 'Left'
    $sld.Tag = $ol
    $sld.Add_ValueChanged({
            $this.Tag.Text = ('面板不透明度：{0}%' -f [int]($this.Value * 100))
        })
    # 拖完再套用 —— 拖动过程中每动一下就重绘全部页面会非常卡
    $sld.Add_PreviewMouseUp({
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image $st.Image -Opacity ([double]$this.Value)
            Apply-PanelOpacity
            Set-Status ('面板不透明度已设为 {0}%' -f [int]($this.Value * 100))
        })
    $isp.Children.Add($sld) | Out-Null

    $on = New-TextBlock -Size 11.5 -Color '#6E6B63' -Wrap $true -Text (
        '只在使用背景图时有效。100% = 完全挡住背景图（和纯色一样），拉低才能看见图。')
    $on.Margin = New-Thick 0 6 0 0
    $isp.Children.Add($on) | Out-Null

    $ic.Child = $isp
    $panel.Children.Add($ic) | Out-Null
}

function Apply-PanelOpacity {
    <#
      有背景图时，把 TabControl 调成半透明让图透出来。
      没有背景图就恢复全不透明 —— 否则纯色皮肤会显得发灰。
    #>
    try {
        if ($Script:ThemeImage -and (Test-Path -LiteralPath $Script:ThemeImage)) {
            $Script:UI.Tabs.Opacity = $Script:ThemeOpacity
        } else {
            $Script:UI.Tabs.Opacity = 1.0
        }
    } catch { }
}

function Redraw-AllPages {
    <#
      换肤之后要把所有「用代码画出来的」页面重绘一遍 ——
      XAML 里的部分靠 DynamicResource 自动变，
      但卡片是代码里 Get-Brush 画的，不重绘不会变色。
    #>
    Apply-PanelOpacity
    try { Build-TweakUI } catch { }
    try { Build-PresetUI } catch { }
    try { Build-CleanUI } catch { }
    try { Build-ThemeUI } catch { }
    try { if ($Script:UI.StartupPanel.Children.Count -gt 0) { Build-StartupUI } } catch { }
    try { if ($Script:UI.AppxPanel.Children.Count -gt 0) { Build-AppxUI } } catch { }
    try { if ($Script:UI.MaintainPanel.Children.Count -gt 0) { Build-MaintainUI } } catch { }
    try { if ($Script:UI.AdvicePanel.Children.Count -gt 0) { Build-HealthUI } } catch { }
}

# ---------------------------------------------------------------------
#  自带软件页
#  设计要点：「必须留」的项复选框直接禁用 —— 不是点了弹警告，
#  而是压根勾不上。少一次手滑的机会。
# ---------------------------------------------------------------------
$Script:AppxRows = @{}

function Update-AppxCounter {
    $n = 0
    foreach ($cb in $Script:AppxRows.Values) { if ($cb.IsChecked) { $n++ } }
    $Script:UI.AppxCounter.Text = if ($n -gt 0) { "已勾选 $n 个待卸载" } else { '' }
}

function Build-AppxUI {
    $panel = $Script:UI.AppxPanel
    $panel.Children.Clear()
    $Script:AppxRows = @{}
    Set-Status '正在读取自带应用列表…'
    Sync-UI

    $Script:AppxFailReason = $null
    $items = @(Get-AppxCatalog)
    if ($items.Count -eq 0) {
        $why = '常见原因：这台机器是精简版系统，自带应用已经被处理过了 —— 那就不用管这一页。'
        if ($Script:AppxFailReason -eq 'pwsh') {
            $why = '原因：当前是用 PowerShell 7（pwsh）运行的，' +
            '微软的 Appx 模块在 PowerShell 7 上不支持，读不到应用列表。' + "`r`n`r`n" +
            '解决办法：关掉这个窗口，改成双击「一键启动.bat」——' +
            '它用的是系统自带的 PowerShell 5.1，这一页就正常了。'
        } elseif ($Script:AppxFailReason) {
            $why = "原因：$Script:AppxFailReason"
        }
        $panel.Children.Add((New-TextBlock -Wrap $true -Color '#6E6B63' -Text (
                    '没读到自带应用列表。' + "`r`n`r`n" + $why))) | Out-Null
        Set-Status '就绪'
        return
    }

    foreach ($it in $items) {
        $c = switch ($it.Verdict) {
            '可以删' { @{ Fg = '#556B54'; Bg = '#E2E7E0' } }
            '必须留' { @{ Fg = '#8A5750'; Bg = '#EDE0DD' } }
            default { @{ Fg = '#7A6B45'; Bg = '#EDE7D9' } }
        }

        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#F6F5F2'
        $card.BorderBrush = Get-Brush '#E0DED8'
        $card.BorderThickness = New-Thick 1
        $card.CornerRadius = New-Object System.Windows.CornerRadius 8
        $card.Padding = New-Thick 12 10 12 10
        $card.Margin = New-Thick 0 0 0 7

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @('Auto', '*')) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::Auto
            if ($w -eq '*') { $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = New-Thick 0 0 2 0
        $cb.VerticalAlignment = 'Top'
        $cb.IsChecked = $false
        $cb.Tag = $it          # 整个对象挂上去，取 Verdict / Name 都方便
        # ★ 受保护的项：直接禁用复选框，连勾都勾不上 ★
        if ($it.Protected -or $it.Verdict -eq '必须留') {
            $cb.IsEnabled = $false
            $cb.ToolTip = '这一项删了会影响系统正常使用，工具不允许卸载'
        } else {
            $cb.Add_Click({ Update-AppxCounter })
        }
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $g.Children.Add($cb) | Out-Null
        $Script:AppxRows[$it.Name] = $cb

        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $head.Children.Add((New-TextBlock -Text $it.Label -Size 13.5 -Bold $true)) | Out-Null
        $bd = New-Badge -Text $it.Verdict -Fg $c.Fg -Bg $c.Bg
        $bd.Margin = New-Thick 8 0 0 0
        $head.Children.Add($bd) | Out-Null
        if ($it.Size -and $it.Size -ne '—') {
            $sz = New-Badge -Text $it.Size -Fg '#6E6B63' -Bg '#E8E7E2'
            $sz.Margin = New-Thick 4 0 0 0
            $head.Children.Add($sz) | Out-Null
        }
        $sp.Children.Add($head) | Out-Null

        $tx = New-TextBlock -Text (Format-Reflow $it.Text) -Size 12 -Color '#6E6B63' -Wrap $true
        $tx.Margin = New-Thick 0 5 0 0
        $sp.Children.Add($tx) | Out-Null

        $pn = New-TextBlock -Text $it.Name -Size 11 -Color '#8A877F' -Wrap $true
        $pn.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($pn) | Out-Null

        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null
        $card.Child = $g
        $panel.Children.Add($card) | Out-Null
    }

    $safe = @($items | Where-Object { $_.Verdict -eq '可以删' }).Count
    Update-AppxCounter
    Set-Status ("自带应用 {0} 个，其中 {1} 个可以放心删" -f $items.Count, $safe)
}

function Invoke-AppxUninstall {
    $names = @()
    foreach ($k in $Script:AppxRows.Keys) {
        $cb = $Script:AppxRows[$k]
        # 三重确认：勾上了 + 复选框是启用的 + 不在硬黑名单里
        if ($cb.IsChecked -and $cb.IsEnabled -and -not (Test-AppxProtected $k)) { $names += $k }
    }
    if ($names.Count -eq 0) {
        [System.Windows.MessageBox]::Show('还没有勾选要卸载的应用。', '电脑调优助手') | Out-Null
        return
    }

    $r = [System.Windows.MessageBox]::Show(
        ("确定要卸载这 {0} 个自带应用吗？`r`n`r`n{1}`r`n`r`n卸载只影响当前用户，任何一个都能去 Microsoft Store 搜名字装回来。" -f `
                $names.Count, ($names -join "`r`n")),
        '确认卸载', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    Set-Busy $true
    $ok = 0; $fail = 0
    foreach ($n in $names) {
        Set-Status "正在卸载 $n …"
        Sync-UI
        if (Remove-AppxSafe -Name $n) { $ok++ } else { $fail++ }
    }
    Set-Busy $false
    Build-AppxUI
    [System.Windows.MessageBox]::Show(
        ("卸载完成：成功 {0} 个，失败 {1} 个。`r`n`r`n失败的多半是系统保护的包，日志页有具体原因。" -f $ok, $fail),
        '电脑调优助手') | Out-Null
}

function Build-StartupUI {
    $panel = $Script:UI.StartupPanel
    $panel.Children.Clear()
    Set-Status '正在读取开机启动项…'
    $items = @(Get-StartupItems)
    if ($items.Count -eq 0) {
        $panel.Children.Add((New-TextBlock -Text '没有发现任何开机启动项，很干净。' -Color '#6E6B63')) | Out-Null
        Set-Status '就绪'
        return
    }

    foreach ($it in $items) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#F6F5F2'
        $card.BorderBrush = Get-Brush '#E0DED8'
        $card.BorderThickness = New-Thick 1
        $card.CornerRadius = New-Object System.Windows.CornerRadius 8
        $card.Padding = New-Thick 12 10 12 10
        $card.Margin = New-Thick 0 0 0 7

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @('Auto', '*')) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::Auto
            if ($w -eq '*') { $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = New-Thick 0 0 2 0
        $cb.VerticalAlignment = 'Top'
        $cb.IsChecked = [bool]$it.Enabled
        $cb.Tag = $it
        $cb.Add_Click({
                $item = $this.Tag
                Set-StartupItemEnabled -Item $item -Enabled ([bool]$this.IsChecked) | Out-Null
                Set-Status ("启动项「{0}」已{1}" -f $item.Name, $(if ($this.IsChecked) { '启用' } else { '禁用' }))
            })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $g.Children.Add($cb) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $nm = New-TextBlock -Text $it.Name -Size 13.5 -Bold $true
        $head.Children.Add($nm) | Out-Null
        $lvColor = switch ($it.AdviceLevel) {
            '可关' { @{ Fg = '#556B54'; Bg = '#E2E7E0' } }
            '建议保留' { @{ Fg = '#8A5750'; Bg = '#EDE0DD' } }
            default { @{ Fg = '#7A6B45'; Bg = '#EDE7D9' } }
        }
        $bd = New-Badge -Text $it.AdviceLevel -Fg $lvColor.Fg -Bg $lvColor.Bg
        $bd.Margin = New-Thick 8 0 0 0
        $head.Children.Add($bd) | Out-Null
        $sc = New-Badge -Text $it.Scope -Fg '#6E6B63' -Bg '#E8E7E2'
        $sc.Margin = New-Thick 4 0 0 0
        $head.Children.Add($sc) | Out-Null
        $sp.Children.Add($head) | Out-Null

        $adv = New-TextBlock -Text $it.AdviceText -Size 12 -Color '#6E6B63' -Wrap $true
        $adv.Margin = New-Thick 0 5 0 0
        $sp.Children.Add($adv) | Out-Null

        $cmd = New-TextBlock -Text $it.Command -Size 11 -Color '#6E6B63' -Wrap $true
        $cmd.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($cmd) | Out-Null

        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null
        $card.Child = $g
        $panel.Children.Add($card) | Out-Null
    }
    Set-Status ("共 {0} 个开机启动项" -f $items.Count)
}

# ---------------------------------------------------------------------
#  7.5 日常维护页
# ---------------------------------------------------------------------
function New-MaintainCard {
    <# 生成一个带标题和说明的卡片，返回卡片本身和可往里塞控件的容器 #>
    param([string]$Title, [string]$Desc)
    $card = New-Object System.Windows.Controls.Border
    $card.Background = Get-Brush '#F6F5F2'
    $card.BorderBrush = Get-Brush '#E0DED8'
    $card.BorderThickness = New-Thick 1
    $card.CornerRadius = New-Object System.Windows.CornerRadius 9
    $card.Padding = New-Thick 16 14 16 14
    $card.Margin = New-Thick 0 0 0 10

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((New-TextBlock -Text $Title -Size 14.5 -Bold $true)) | Out-Null
    if ($Desc) {
        $d = New-TextBlock -Text $Desc -Size 12 -Color '#6E6B63' -Wrap $true
        $d.Margin = New-Thick 0 6 0 0
        $sp.Children.Add($d) | Out-Null
    }
    $body = New-Object System.Windows.Controls.StackPanel
    $body.Margin = New-Thick 0 11 0 0
    $sp.Children.Add($body) | Out-Null
    $card.Child = $sp
    return @{ Card = $card; Body = $body }
}

function New-ToolButton {
    param([string]$Text, [scriptblock]$OnClick, $Tag = $null)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Margin = New-Thick 0 0 8 6
    # 不加这句的话，按钮放进竖排 StackPanel 会被拉成整行宽，非常难看
    $b.HorizontalAlignment = 'Left'
    if ($null -ne $Tag) { $b.Tag = $Tag }
    $b.Add_Click($OnClick)
    return $b
}

function Invoke-DailyMaintenance {
    <# 「一键日常维护」：清理 + 刷新DNS + 系统盘 TRIM，一条龙 #>
    $r = [System.Windows.MessageBox]::Show(
        "一键日常维护会依次做三件事：`r`n`r`n1. 清理「垃圾清理」页里所有推荐项（临时文件、缓存、日志…）`r`n2. 刷新 DNS 缓存`r`n3. 对系统盘执行 TRIM / 碎片整理`r`n`r`n全程不会改动任何性能设置，也不会碰你的文件。`r`n建议先关掉浏览器和游戏平台。`r`n`r`n现在开始吗？",
        '一键日常维护', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    Set-Busy $true
    $freed = 0
    foreach ($it in $Script:CleanItems) {
        if (-not $it.Recommended) { continue }
        Set-Status ("正在清理：{0}" -f $it.Name)
        Sync-UI
        $f = Invoke-CleanupItem $it
        $freed += $f
        if ($Script:CleanRows[$it.Id]) {
            $Script:CleanRows[$it.Id].Size.Text = if ($f -gt 0) { '已清理' } else { '无可清理' }
            $Script:CleanRows[$it.Id].Size.Foreground = Get-Brush '#556B54'
        }
        Sync-UI
    }

    Set-Status '正在刷新 DNS 缓存…'; Sync-UI
    Clear-DnsCacheNow | Out-Null

    $sysLetter = $env:SystemDrive.TrimEnd(':')
    $vol = @(Get-VolumesToOptimize | Where-Object { $_.Letter -eq $sysLetter })
    if ($vol.Count -gt 0) {
        Set-Status ("正在优化系统盘（{0}）…" -f $(if ($vol[0].IsSSD) { '固态 TRIM' } else { '机械碎片整理，可能较慢' })); Sync-UI
        Invoke-DiskOptimize -DriveLetter $sysLetter -IsSSD $vol[0].IsSSD | Out-Null
    }

    Set-Busy $false
    $msg = "日常维护完成。`r`n`r`n· 清理释放：$(Format-Size $freed)`r`n· DNS 缓存已刷新`r`n· 系统盘已优化"
    Set-Status ("日常维护完成，释放 {0}" -f (Format-Size $freed))
    Write-Log $msg '成功'
    [System.Windows.MessageBox]::Show($msg, '电脑调优助手') | Out-Null
}

function Invoke-SetRefresh {
    <#
      切刷新率，带 15 秒自动回滚的安全网。
      为什么必须有这个安全网：万一显示器不支持工具报上来的那个模式
      （线材带宽不够是最常见的原因，比如 HDMI 2.0 带不动 1080p 240Hz），
      切过去会直接黑屏 —— 那时候用户连「还原」按钮都看不见、点不了。
      所以做成「不主动确认就自动切回去」，用户什么都不用做也能救回来。
    #>
    param([int]$Hz)
    $before = Get-CurrentDisplayMode
    if (-not $before) { return }
    if (-not (Set-DisplayRefreshRate -Hz $Hz)) {
        [System.Windows.MessageBox]::Show("切换到 $Hz Hz 失败 —— 显卡驱动拒绝了这个模式。`r`n`r`n常见原因是线材带宽不够（HDMI 2.0 带不动 1080p 240Hz 这种），换根 DP 线试试。`r`n`r`n设置没有被改动。", '电脑调优助手') | Out-Null
        return
    }

    # 倒计时确认。用 DispatcherTimer 是因为要在界面线程上更新按钮文字。
    $win = New-Object System.Windows.Window
    $win.Title = '确认刷新率'
    $win.Width = 420; $win.SizeToContent = 'Height'
    $win.WindowStartupLocation = 'CenterScreen'
    $win.ResizeMode = 'NoResize'
    $win.Background = Get-Brush '#F6F5F2'
    $win.FontFamily = New-Object System.Windows.Media.FontFamily 'Microsoft YaHei UI, Segoe UI'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 22 20 22 18
    $sp.Children.Add((New-TextBlock -Text ("已切换到 {0} Hz" -f $Hz) -Size 16 -Bold $true)) | Out-Null
    $tip = New-TextBlock -Wrap $true -Size 12.5 -Color '#4A4842' -Text '画面正常吗？正常就点「保持」。如果黑屏或花屏，什么都不用做 —— 倒计时结束会自动切回去。'
    $tip.Margin = New-Thick 0 10 0 12
    $sp.Children.Add($tip) | Out-Null
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $keep = New-Object System.Windows.Controls.Button
    $keep.Content = '保持这个设置'
    try { $keep.Style = $Script:Window.FindResource('AccentButton') } catch { }
    $undo = New-Object System.Windows.Controls.Button
    $undo.Content = ("立即切回 {0} Hz" -f $before.Hz)
    $row.Children.Add($keep) | Out-Null
    $row.Children.Add($undo) | Out-Null
    $sp.Children.Add($row) | Out-Null
    $win.Content = $sp

    $Script:RefreshKept = $false
    $left = 15
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
            $script:left--
            $undo.Content = "立即切回 {0} Hz（{1} 秒后自动）" -f $before.Hz, $script:left
            if ($script:left -le 0) { $timer.Stop(); $win.Close() }
        })
    $keep.Add_Click({ $Script:RefreshKept = $true; $timer.Stop(); $win.Close() })
    $undo.Add_Click({ $timer.Stop(); $win.Close() })
    $undo.Content = "立即切回 {0} Hz（{1} 秒后自动）" -f $before.Hz, $left
    $timer.Start()
    $win.Owner = $Script:Window
    $win.ShowDialog() | Out-Null

    if ($Script:RefreshKept) {
        Set-Status ("刷新率已设为 {0} Hz" -f $Hz)
    } else {
        Set-DisplayRefreshRate -Hz $before.Hz | Out-Null
        Set-Status ("已切回 {0} Hz" -f $before.Hz)
    }
    Build-MaintainUI   # 重建这一页，按钮上的「当前」标记要跟着更新
}

function Export-DiagnosticReport {
    <#
      把硬件信息、体检结论、已应用的优化、弹窗排查结果打包成一个 txt。
      用途很实在：朋友电脑出问题，让他导一份发过来，比来回问十句话快得多。
    #>
    Set-Busy $true
    Set-Status '正在生成诊断报告…'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('===== 电脑调优助手 · 诊断报告 =====')
    [void]$sb.AppendLine(('工具版本：v{0} {1}（{2}）' -f $Script:AppVersion, $Script:AppVersionName, $Script:AppVersionDate))
    [void]$sb.AppendLine(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---------- 硬件信息 ----------')
    foreach ($r in (Get-SystemReport)) { [void]$sb.AppendLine(('{0}：{1}' -f $r.Key, $r.Value)) }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---------- 体检结论 ----------')
    foreach ($a in (Get-HealthAdvice)) {
        [void]$sb.AppendLine(('[{0}] {1}' -f $a.Level, $a.Title))
        [void]$sb.AppendLine($a.Text)
        [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine('---------- 帧数瓶颈诊断 ----------')
    foreach ($d in (Get-FpsDiagnosis)) {
        [void]$sb.AppendLine(('[{0}] {1}' -f $d.Level, $d.Title))
        [void]$sb.AppendLine($d.Text)
        [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine('---------- 优化项状态 ----------')
    foreach ($tw in $Script:Tweaks) {
        $row = $Script:TweakRows[$tw.Id]
        $st = if ($row) { $row.Badge.Text } else { '?' }
        [void]$sb.AppendLine(('{0,-10} {1}' -f $st, $tw.Name))
    }
    [void]$sb.AppendLine()
    if ($Script:Findings -and $Script:Findings.Count -gt 0) {
        [void]$sb.AppendLine('---------- 弹窗排查结果 ----------')
        foreach ($f in $Script:Findings) {
            [void]$sb.AppendLine(('[{0}]{1} {2} — {3}' -f $f.Level, $(if ($f.Flash) { '[会弹黑框]' } else { '' }), $f.Kind, $f.Name))
            if ($f.Command) { [void]$sb.AppendLine(('    ' + $f.Command)) }
        }
        [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine('---------- 本次操作日志 ----------')
    foreach ($l in $Script:LogLines) { [void]$sb.AppendLine($l) }

    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('电脑诊断报告-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmm'))
    try {
        [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Set-Busy $false
        Set-Status ('诊断报告已保存到桌面')
        Write-Log "诊断报告已导出：$path" '成功'
        $r = [System.Windows.MessageBox]::Show("报告已保存到桌面：`r`n$(Split-Path $path -Leaf)`r`n`r`n里面有硬件信息、体检结论、优化项状态和操作日志，可以直接发给别人看。`r`n`r`n现在打开它吗？", '电脑调优助手', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Start-Process notepad.exe -ArgumentList "`"$path`"" }
    } catch {
        Set-Busy $false
        [System.Windows.MessageBox]::Show("保存失败：$($_.Exception.Message)", '电脑调优助手') | Out-Null
    }
}

function Build-MaintainUI {
    $p = $Script:UI.MaintainPanel
    $p.Children.Clear()

    # ---------- 一键日常维护 ----------
    $c1 = New-MaintainCard -Title '一键日常维护' -Desc '平时每个月点一次就行：清垃圾 + 刷新 DNS + 优化系统盘，一条龙。不会改任何性能设置。'
    $bAll = New-ToolButton -Text '开始一键维护' -OnClick { Invoke-DailyMaintenance }
    try { $bAll.Style = $Script:Window.FindResource('AccentButton') } catch { }
    $bAll.Padding = New-Thick 22 10 22 10
    $bAll.HorizontalAlignment = 'Left'
    $c1.Body.Children.Add($bAll) | Out-Null
    $p.Children.Add($c1.Card) | Out-Null

    # ---------- 显示器刷新率 ----------
    # 买了高刷屏却还跑在 60Hz 非常常见（换线、重装驱动、接新屏都会退回去）。
    # 对 FPS 玩家来说这个差距比任何注册表优化都大，所以放在第二位。
    $cur = Get-CurrentDisplayMode
    $opts = @(Get-DisplayRefreshOptions)
    if ($cur -and $opts.Count -gt 0) {
        $maxHz = $opts[0]
        $desc = if ($cur.Hz -lt $maxHz) {
            "当前 $($cur.Hz)Hz，但这套「显示器 + 线 + 显卡」最高能跑 $maxHz Hz —— 没跑满。"
        } else {
            "当前 $($cur.Hz)Hz，已经是这套配置能跑的最高刷新率。"
        }
        $c15 = New-MaintainCard -Title '显示器刷新率' -Desc ("{0} x {1}   ·   {2}" -f $cur.Width, $cur.Height, $desc)
        $wrap15 = New-Object System.Windows.Controls.WrapPanel
        foreach ($hz in $opts) {
            $b = New-ToolButton -Text ("{0} Hz" -f $hz) -Tag $hz -OnClick { Invoke-SetRefresh $this.Tag }
            if ($hz -eq $cur.Hz) {
                $b.IsEnabled = $false
                $b.Content = "{0} Hz（当前）" -f $hz
            } elseif ($hz -eq $maxHz) {
                try { $b.Style = $Script:Window.FindResource('AccentButton') } catch { }
                $b.Content = "{0} Hz（最高）" -f $hz
            }
            $wrap15.Children.Add($b) | Out-Null
        }
        $c15.Body.Children.Add($wrap15) | Out-Null
        $t15 = New-TextBlock -Size 11.5 -Color '#6E6B63' -Wrap $true -Text '切换后会弹一个 15 秒倒计时确认框。万一切完黑屏或花屏，什么都别动，倒计时结束会自动切回原来的设置 —— 和 Windows 自己改分辨率时的行为一样。'
        $t15.Margin = New-Thick 0 8 0 0
        $c15.Body.Children.Add($t15) | Out-Null
        $p.Children.Add($c15.Card) | Out-Null
    }

    # ---------- 快捷小工具 ----------
    $c2 = New-MaintainCard -Title '快捷小工具' -Desc '一些偶尔会用到、但藏得很深的系统功能。'
    $wrap2 = New-Object System.Windows.Controls.WrapPanel
    $wrap2.Children.Add((New-ToolButton -Text '刷新 DNS 缓存' -OnClick {
                Clear-DnsCacheNow | Out-Null
                [System.Windows.MessageBox]::Show("DNS 缓存已刷新。`r`n`r`n什么时候用它：某个网站突然打不开但别的正常、刚换过 DNS、游戏登录服务器连不上但网页能开。", '电脑调优助手') | Out-Null
            })) | Out-Null
    $wrap2.Children.Add((New-ToolButton -Text '重启资源管理器' -OnClick {
                Restart-ExplorerShell
                Set-Status '资源管理器已重启'
            })) | Out-Null
    $wrap2.Children.Add((New-ToolButton -Text '打开系统磁盘清理' -OnClick {
                Start-Process 'cleanmgr.exe' -ArgumentList "/d $env:SystemDrive" -ErrorAction SilentlyContinue
            })) | Out-Null
    $wrap2.Children.Add((New-ToolButton -Text '打开存储设置' -OnClick {
                Start-Process 'ms-settings:storagesense' -ErrorAction SilentlyContinue
            })) | Out-Null
    $wrap2.Children.Add((New-ToolButton -Text '打开已安装程序' -OnClick {
                Start-Process 'ms-settings:appsfeatures' -ErrorAction SilentlyContinue
            })) | Out-Null
    $c2.Body.Children.Add($wrap2) | Out-Null
    $tip2 = New-TextBlock -Size 11.5 -Color '#6E6B63' -Wrap $true -Text '顺带一提：游戏里画面卡死、显卡驱动假死的时候，按 Win + Ctrl + Shift + B 可以直接重启显卡驱动，屏幕会黑一下然后恢复，不用重启电脑。这是 Windows 自带的快捷键。'
    $tip2.Margin = New-Thick 0 8 0 0
    $c2.Body.Children.Add($tip2) | Out-Null
    $p.Children.Add($c2.Card) | Out-Null

    # ---------- 磁盘优化 ----------
    $c3 = New-MaintainCard -Title '磁盘优化（固态 TRIM / 机械 碎片整理）' -Desc '工具会自动识别介质：固态盘做 TRIM（恢复写入速度），机械盘做碎片整理。不会对固态盘做碎片整理——那只会白白消耗寿命。半年做一次就够。'
    foreach ($v in (Get-VolumesToOptimize)) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Thick 0 0 0 6
        $lbl = New-TextBlock -Text ("{0}:  {1}   {2} / {3} 可用" -f $v.Letter, $(if ($v.IsSSD) { '固态' } else { '机械' }), (Format-Size $v.Free), (Format-Size $v.Size)) -Size 12.5
        $lbl.VerticalAlignment = 'Center'
        $lbl.Width = 260
        $row.Children.Add($lbl) | Out-Null
        $row.Children.Add((New-ToolButton -Text $(if ($v.IsSSD) { '执行 TRIM' } else { '碎片整理' }) -Tag $v -OnClick {
                    $vv = $this.Tag
                    Set-Status ("正在优化 {0} 盘，机械盘可能要几十分钟，请耐心等…" -f $vv.Letter)
                    Sync-UI
                    $ok = Invoke-DiskOptimize -DriveLetter $vv.Letter -IsSSD $vv.IsSSD
                    Set-Status $(if ($ok) { "$($vv.Letter) 盘优化完成" } else { "$($vv.Letter) 盘优化失败，详见日志" })
                })) | Out-Null
        $c3.Body.Children.Add($row) | Out-Null
    }
    $p.Children.Add($c3.Card) | Out-Null

    # ---------- 硬盘健康 ----------
    $c4 = New-MaintainCard -Title '硬盘健康与寿命' -Desc '读 SMART 数据。老机器最怕硬盘悄悄坏掉，这里能提前发现苗头。'
    foreach ($d in (Get-DiskHealthReport)) {
        $col = switch ($d.Level) { '严重' { '#8A5750' } '建议' { '#7A6B45' } default { '#556B54' } }
        $b = New-Object System.Windows.Controls.Border
        $b.BorderBrush = Get-Brush $col
        $b.BorderThickness = New-Thick 3 0 0 0
        $b.Background = Get-Brush '#FBFAF8'
        $b.CornerRadius = New-Object System.Windows.CornerRadius 4
        $b.Padding = New-Thick 11 8 11 9
        $b.Margin = New-Thick 0 0 0 6
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-TextBlock -Text ("{0}   {1}   {2}" -f $d.Name, $d.Media, $d.Size) -Size 12.5 -Bold $true -Wrap $true)) | Out-Null
        $extra = @()
        if ($null -ne $d.Temp -and $d.Temp -gt 0) { $extra += "温度 $($d.Temp)°C" }
        if ($null -ne $d.Hours) { $extra += "已通电 $($d.Hours) 小时" }
        if ($extra.Count -gt 0) {
            $e = New-TextBlock -Text ($extra -join '   ·   ') -Size 11.5 -Color '#6E6B63'
            $e.Margin = New-Thick 0 3 0 0
            $sp.Children.Add($e) | Out-Null
        }
        $vt = New-TextBlock -Text $d.Verdict -Size 12 -Color $col -Wrap $true
        $vt.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($vt) | Out-Null
        $b.Child = $sp
        $c4.Body.Children.Add($b) | Out-Null
    }
    $p.Children.Add($c4.Card) | Out-Null

    # ---------- 微信 / QQ 占用 ----------
    $c5 = New-MaintainCard -Title '微信 / QQ 占用多少空间' -Desc '这两个是国内 C 盘杀手的常客，几十个 GB 很常见。这里只统计不删——聊天图片和文件是你的资料，该不该删只有你自己知道。「垃圾清理」页里的微信/QQ 那一项只清纯缓存（小程序缓存等），绝不碰聊天内容。'
    $c5Body = $c5.Body
    $c5Body.Children.Add((New-ToolButton -Text '扫描占用（可能要一两分钟）' -Tag $c5Body -OnClick {
                $body = $this.Tag
                Set-Status '正在统计微信 / QQ 占用…'
                Sync-UI
                # 清掉上一次的结果，只留按钮
                while ($body.Children.Count -gt 1) { $body.Children.RemoveAt(1) }
                $rows = @(Get-ChatAppUsage)
                if ($rows.Count -eq 0) {
                    $body.Children.Add((New-TextBlock -Text '没有找到微信或 QQ 的数据目录（可能没装，或者装在非默认位置）。' -Size 12 -Color '#6E6B63' -Wrap $true)) | Out-Null
                } else {
                    foreach ($r in $rows) {
                        $t = New-TextBlock -Text ("{0}：{1}`r`n{2}" -f $r.App, (Format-Size $r.Size), $r.Path) -Size 12 -Color '#4A4842' -Wrap $true
                        $t.Margin = New-Thick 0 8 0 0
                        $body.Children.Add($t) | Out-Null
                    }
                    $h = New-TextBlock -Size 11.5 -Color '#7A6B45' -Wrap $true -Text '占用太大的话，用软件自带的清理功能挑着删：微信 → 设置 → 文件管理 → 清理微信存储空间；QQ → 设置 → 文件管理 → 清理。它们能按聊天对象和时间筛选，比无脑全删安全得多。'
                    $h.Margin = New-Thick 0 10 0 0
                    $body.Children.Add($h) | Out-Null
                }
                Set-Status '统计完成'
            })) | Out-Null
    $p.Children.Add($c5.Card) | Out-Null

    # ---------- 每周自动清理 ----------
    $c6 = New-MaintainCard -Title '每周自动清理' -Desc '开启后会建一个计划任务，每周日中午 12 点在后台静默跑一遍「垃圾清理」页的推荐项。不弹窗、不影响你用电脑、不碰任何性能设置。人不在电脑前的时候错过了，下次开机会自动补跑。'
    $cbAuto = New-Object System.Windows.Controls.CheckBox
    $cbAuto.Content = '开启每周自动清理'
    $cbAuto.FontSize = 13
    $cbAuto.IsChecked = (Test-AutoCleanEnabled)
    $cbAuto.Add_Click({
            if ($this.IsChecked) {
                $ok = Enable-AutoClean -ScriptPath $PSCommandPath
                if ($ok) { Set-Status '已开启每周自动清理（每周日 12:00）' }
                else { $this.IsChecked = $false; [System.Windows.MessageBox]::Show('创建计划任务失败，详见日志页。', '电脑调优助手') | Out-Null }
            } else {
                Disable-AutoClean | Out-Null
                Set-Status '已关闭每周自动清理'
            }
        })
    $c6.Body.Children.Add($cbAuto) | Out-Null
    $p.Children.Add($c6.Card) | Out-Null
}

function Build-BigFileDrives {
    $bar = $Script:UI.BigFileDrives
    $bar.Children.Clear()
    # 只列本机固定硬盘（DriveType=3）。U 盘、光驱、网络盘不扫，
    # 免得点错了对着网络盘跑半小时。
    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $root = $d.DeviceID + '\'
        $bar.Children.Add((New-ToolButton -Text ("扫描 " + $d.DeviceID) -Tag $root -OnClick {
                    Invoke-BigFileScan $this.Tag
                })) | Out-Null
    }
}

function Invoke-BigFileScan {
    param([string]$Root)
    $panel = $Script:UI.BigFilePanel
    $panel.Children.Clear()
    $panel.Children.Add((New-TextBlock -Text '正在扫描，请稍候…' -Size 12 -Color '#7A6B45')) | Out-Null
    Sync-UI

    $progress = {
        param($dir, $found)
        Set-Status ("正在扫描大文件… 已找到 {0} 个   当前：{1}" -f $found, $dir)
        Sync-UI
    }
    Set-Busy $true
    $files = @(Find-LargeFiles -Root $Root -MinMB 300 -Top 40 -OnProgress $progress)
    Set-Busy $false

    $panel.Children.Clear()
    if ($files.Count -eq 0) {
        $panel.Children.Add((New-TextBlock -Text ("{0} 里没有找到超过 300MB 的文件。" -f $Root) -Size 12 -Color '#6E6B63' -Wrap $true)) | Out-Null
        Set-Status '扫描完成'
        return
    }

    $hint = New-TextBlock -Size 11.5 -Color '#6E6B63' -Wrap $true -Text '点任意一项会在资源管理器里定位到它。删之前想清楚：大文件里有很多是系统必需的（pagefile.sys 虚拟内存、hiberfil.sys 休眠文件、install.wim 等），别乱删。游戏安装包、下载的视频、旧的备份文件才是该清的。'
    $hint.Margin = New-Thick 0 0 0 10
    $panel.Children.Add($hint) | Out-Null

    foreach ($f in $files) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = Get-Brush '#FBFAF8'
        $b.CornerRadius = New-Object System.Windows.CornerRadius 4
        $b.Padding = New-Thick 10 7 10 7
        $b.Margin = New-Thick 0 0 0 5
        $b.Cursor = 'Hand'
        $b.Tag = $f.Path
        $b.Add_MouseLeftButtonUp({
                try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $this.Tag) } catch { }
            })
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-TextBlock -Text (Format-Size $f.Size) -Size 12.5 -Bold $true -Color '#7A6B45')) | Out-Null
        $t = New-TextBlock -Text $f.Path -Size 11.5 -Color '#5E5B54' -Wrap $true
        $t.Margin = New-Thick 0 2 0 0
        $sp.Children.Add($t) | Out-Null
        $b.Child = $sp
        $panel.Children.Add($b) | Out-Null
    }
    Set-Status ("扫描完成，列出了 {0} 个大文件" -f $files.Count)
}

# ---------------------------------------------------------------------
#  7.6 弹窗排查页
# ---------------------------------------------------------------------
$Script:Findings = @()
$Script:InspectFilterOn = $false

function Get-LevelColor {
    param([string]$L)
    switch ($L) {
        '高危'     { return '#8A5750' }
        '可疑'     { return '#7A6B45' }
        '无用'     { return '#6E6B63' }
        '已知打扰' { return '#55606F' }
        default    { return '#6E6B63' }
    }
}

function Invoke-Inspect {
    $Script:UI.InspectPanel.Children.Clear()
    $Script:UI.InspectPanel.Children.Add((New-TextBlock -Text '正在扫描，请稍候…' -Size 12.5 -Color '#7A6B45')) | Out-Null
    Sync-UI
    Set-Busy $true
    $Script:Findings = @(Get-SuspiciousFindings -OnProgress { param($m) Set-Status $m; Sync-UI })
    Set-Busy $false
    Show-Findings
}

function Show-Findings {
    $p = $Script:UI.InspectPanel
    $p.Children.Clear()

    $list = $Script:Findings
    if ($Script:InspectFilterOn) { $list = @($list | Where-Object { $_.Flash -or $_.Level -eq '高危' }) }

    $n弹框 = @($Script:Findings | Where-Object { $_.Flash }).Count
    $n高危 = @($Script:Findings | Where-Object Level -eq '高危').Count
    $n可疑 = @($Script:Findings | Where-Object Level -eq '可疑').Count
    $n无用 = @($Script:Findings | Where-Object Level -eq '无用').Count
    $n打扰 = @($Script:Findings | Where-Object Level -eq '已知打扰').Count
    $Script:UI.InspectSummary.Text = ("⚡会弹黑框 {0} · 高危 {1} · 可疑 {2} · 无用 {3} · 已知打扰 {4}" -f $n弹框, $n高危, $n可疑, $n无用, $n打扰)

    if ($Script:Findings.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12.5 -Color '#556B54' -Text "扫描完成，没有发现可疑项。`r`n`r`n如果还是会弹黑框，用右边的「抓现行」：先点「开启运行记录」，等下次黑框出现之后马上点「刷新记录」，就能看到那一刻到底是哪个任务在跑。")) | Out-Null
        Set-Status '扫描完成，没有发现可疑项'
        return
    }
    if ($list.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12.5 -Color '#556B54' -Text '按当前筛选条件没有内容 —— 也就是说没有「高危」和「无用」项，这是好事。点「显示全部」可以看其余条目。')) | Out-Null
        return
    }

    foreach ($f in $list) {
        $col = Get-LevelColor $f.Level
        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#F6F5F2'
        # 会弹黑框的那条用暖橙光原色描边（纯装饰，不承载文字，可以用最亮的一档）
        $card.BorderBrush = Get-Brush $(if ($f.Flash) { '#A08161' } else { $col })
        $card.BorderThickness = New-Thick 3 0 0 0
        $card.CornerRadius = New-Object System.Windows.CornerRadius 6
        $card.Padding = New-Thick 14 11 14 12
        $card.Margin = New-Thick 0 0 0 8

        $sp = New-Object System.Windows.Controls.StackPanel

        $hdr = New-Object System.Windows.Controls.WrapPanel
        if ($f.Flash) { $hdr.Children.Add((New-Badge -Text '⚡ 会弹黑框' -Fg '#89694F' -Bg '#EDE2D6')) | Out-Null }
        $hdr.Children.Add((New-Badge -Text $f.Level -Fg $col -Bg (Get-TintBg $col))) | Out-Null
        $hdr.Children.Add((New-Badge -Text $f.Kind -Fg '#6E6B63' -Bg '#E8E7E2')) | Out-Null
        $sp.Children.Add($hdr) | Out-Null

        $nm = New-TextBlock -Text $f.Name -Size 13.5 -Bold $true -Wrap $true
        $nm.Margin = New-Thick 0 5 0 0
        $sp.Children.Add($nm) | Out-Null

        if ($f.Extra) {
            $ex = New-TextBlock -Text $f.Extra -Size 11.5 -Color '#6E6B63' -Wrap $true
            $ex.Margin = New-Thick 0 3 0 0
            $sp.Children.Add($ex) | Out-Null
        }

        if ($f.Command) {
            $cb = New-Object System.Windows.Controls.Border
            $cb.Background = Get-Brush '#E8E7E2'
            $cb.CornerRadius = New-Object System.Windows.CornerRadius 4
            $cb.Padding = New-Thick 9 6 9 6
            $cb.Margin = New-Thick 0 7 0 0
            $ct = New-TextBlock -Text $f.Command -Size 11 -Color '#5E5B54' -Wrap $true
            $ct.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, Microsoft YaHei UI'
            $cb.Child = $ct
            $sp.Children.Add($cb) | Out-Null
        }

        foreach ($r in $f.Reasons) {
            $rt = New-TextBlock -Text ('· ' + $r) -Size 12 -Color '#565349' -Wrap $true
            $rt.Margin = New-Thick 0 6 0 0
            $sp.Children.Add($rt) | Out-Null
        }

        $ad = New-TextBlock -Text $f.Advice -Size 12 -Color $col -Wrap $true
        $ad.Margin = New-Thick 0 8 0 0
        $sp.Children.Add($ad) | Out-Null

        # ---- 操作 ----
        if ($f.Target.Type -eq 'WmiConsumer') {
            $b = New-ToolButton -Text '删除这个 WMI 订阅' -Tag $f -OnClick {
                $ff = $this.Tag
                $r = [System.Windows.MessageBox]::Show("即将删除 WMI 事件订阅：`r`n$($ff.Name)`r`n`r`n注意：这一项删掉之后工具无法帮你恢复。`r`n而且删掉它只是切断了自动执行，真正的恶意文件还在硬盘上 ——`r`n删完请务必用 Windows Defender 做一次完全扫描。`r`n`r`n确定删除吗？", '确认删除', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return }
                if (Set-FindingEnabled -Finding $ff -Enabled $false) { $this.IsEnabled = $false; $this.Content = '已删除' }
            }
            $b.Margin = New-Thick 0 10 0 0
            $sp.Children.Add($b) | Out-Null
        } elseif ($f.Target.Type -ne 'None') {
            $cbx = New-Object System.Windows.Controls.CheckBox
            $cbx.Content = '保持启用（取消勾选 = 禁用它，随时可以再勾回来）'
            $cbx.FontSize = 12
            $cbx.Margin = New-Thick 0 10 0 0
            $cbx.IsChecked = [bool]$f.Enabled
            $cbx.Tag = $f
            $cbx.Add_Click({
                    $ff = $this.Tag
                    $want = [bool]$this.IsChecked
                    if (Set-FindingEnabled -Finding $ff -Enabled $want) {
                        Set-Status ("「{0}」已{1}" -f $ff.Name, $(if ($want) { '启用' } else { '禁用' }))
                    } else {
                        $this.IsChecked = -not $want
                    }
                })
            $sp.Children.Add($cbx) | Out-Null
        } else {
            $t = New-TextBlock -Text '这一项工具不会自动改动 —— 涉及系统核心设置，误改会开不了机。请先杀毒，确认之后手动处理。' -Size 11.5 -Color '#6E6B63' -Wrap $true
            $t.Margin = New-Thick 0 10 0 0
            $sp.Children.Add($t) | Out-Null
        }

        $card.Child = $sp
        $p.Children.Add($card) | Out-Null
    }
    Set-Status ("扫描完成：" + $Script:UI.InspectSummary.Text)
}

# ---- 抓现行：实时进程监控 ----
$Script:WatchTimer = $null

function New-ProcRow {
    <# 一条进程记录的卡片。会弹黑框的用醒目颜色标出来。 #>
    param([string]$Head, [string]$Sub, [string]$Cmd, [bool]$Hot)
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush $(if ($Hot) { '#F0E7DC' } else { '#FBFAF8' })
    $b.BorderBrush = Get-Brush $(if ($Hot) { '#7A6B45' } else { '#DDDBD5' })
    $b.BorderThickness = New-Thick $(if ($Hot) { 3 } else { 0 }) 0 0 0
    $b.CornerRadius = New-Object System.Windows.CornerRadius 4
    $b.Padding = New-Thick 10 7 10 8
    $b.Margin = New-Thick 0 0 0 5
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((New-TextBlock -Text $Head -Size 12 -Bold $true -Color $(if ($Hot) { '#89694F' } else { '#4A4842' }) -Wrap $true)) | Out-Null
    if ($Sub) {
        $t = New-TextBlock -Text $Sub -Size 11.5 -Color '#6E6B63' -Wrap $true
        $t.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($t) | Out-Null
    }
    if ($Cmd) {
        $t2 = New-TextBlock -Text $Cmd -Size 10.5 -Color '#6E6B63' -Wrap $true
        $t2.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($t2) | Out-Null
    }
    $b.Child = $sp
    return $b
}

function Start-LiveWatch {
    if (-not (Start-ProcWatch)) {
        [System.Windows.MessageBox]::Show("实时监控启动失败。`r`n`r`n这个功能需要管理员权限（正常双击「一键启动.bat」并在 UAC 弹窗点「是」即可）。`r`n`r`n如果还是不行，改用下面的「持续记录」，效果一样，而且关掉工具也在记。", '电脑调优助手') | Out-Null
        return
    }
    $Script:UI.RecentRunPanel.Children.Clear()
    $Script:UI.RecentRunPanel.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#6E6B63' -Text '监控已启动。现在正常用电脑，等黑框出现——出现的瞬间这里就会多出几条记录。带橙色标记的就是控制台进程（也就是黑框本身），看它的「父进程」是谁，那就是元凶。')) | Out-Null
    $Script:UI.BtnWatchStart.IsEnabled = $false
    $Script:UI.BtnWatchStop.IsEnabled = $true

    if (-not $Script:WatchTimer) {
        $Script:WatchTimer = New-Object System.Windows.Threading.DispatcherTimer
        $Script:WatchTimer.Interval = [TimeSpan]::FromMilliseconds(800)
        $Script:WatchTimer.Add_Tick({
                $new = @(Receive-ProcWatch)
                foreach ($r in $new) {
                    # 只关心你看得见的会话里的进程，系统后台会话(0)的不弹窗
                    if (-not $r.Visible) { continue }
                    $head = "{0}   {1}" -f $r.Time.ToString('HH:mm:ss'), $r.Name
                    $sub = "父进程：{0}    ← 这个才是真正的元凶" -f $r.Parent
                    if (-not $r.Console) { $sub = "父进程：{0}" -f $r.Parent }
                    $Script:UI.RecentRunPanel.Children.Insert(0, (New-ProcRow -Head $head -Sub $sub -Cmd $r.CommandLine -Hot ([bool]$r.Console)))
                    # 列表别无限长
                    while ($Script:UI.RecentRunPanel.Children.Count -gt 200) {
                        $Script:UI.RecentRunPanel.Children.RemoveAt($Script:UI.RecentRunPanel.Children.Count - 1)
                    }
                }
                $hot = @($Script:ProcWatchLog | Where-Object { $_.Console -and $_.Visible }).Count
                $Script:UI.WatchStatus.Text = "正在监控…  已捕获 {0} 个新建进程，其中 {1} 个是控制台进程（黑框）" -f $Script:ProcWatchLog.Count, $hot
            })
    }
    $Script:WatchTimer.Start()
    $Script:UI.WatchStatus.Text = '正在监控…'
    Set-Status '实时监控已启动 —— 等黑框出现'
}

function Stop-LiveWatch {
    if ($Script:WatchTimer) { $Script:WatchTimer.Stop() }
    Stop-ProcWatch
    $Script:UI.BtnWatchStart.IsEnabled = $true
    $Script:UI.BtnWatchStop.IsEnabled = $false
    $hot = @($Script:ProcWatchLog | Where-Object { $_.Console -and $_.Visible })
    if ($hot.Count -gt 0) {
        $who = ($hot | Group-Object Parent | Sort-Object Count -Descending | Select-Object -First 3 |
                ForEach-Object { "{0}（{1} 次）" -f $_.Name, $_.Count }) -join '、'
        $Script:UI.WatchStatus.Text = "监控已停止。期间弹出 {0} 个黑框，开出它们的是：{1}" -f $hot.Count, $who
    } else {
        $Script:UI.WatchStatus.Text = "监控已停止，期间没有捕获到任何黑框（共 {0} 个新建进程）。可以改用「持续记录」蹲久一点。" -f $Script:ProcWatchLog.Count
    }
    Set-Status '实时监控已停止'
}

function Show-ProcLog {
    $p = $Script:UI.RecentRunPanel
    $p.Children.Clear()
    if (-not (Test-ProcAuditEnabled)) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#7A6B45' -Text '「持续记录」还没开启，所以没有历史可查。先点上面的「开启持续记录」。')) | Out-Null
        return
    }
    Set-Busy $true
    Set-Status '正在读取进程创建记录…'
    $rows = @(Get-RecentProcessCreations -Minutes 180 -ConsoleOnly $true)
    Set-Busy $false
    if ($rows.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#6E6B63' -Text '最近 3 小时没有记录到控制台进程。如果刚开启记录，要等下次弹窗之后再来看。')) | Out-Null
        Set-Status '就绪'
        return
    }
    $h = New-TextBlock -Wrap $true -Size 11.5 -Color '#6E6B63' -Text '最近 3 小时内创建过的控制台进程（也就是黑框），按次数从多到少排。次数特别多的那条，基本就是你看到的规律性弹窗。重点看「父进程」——那是真正开出黑框的程序。'
    $h.Margin = New-Thick 0 0 0 10
    $p.Children.Add($h) | Out-Null
    foreach ($r in $rows) {
        $head = "{0}   ×{1} 次   最近 {2}" -f $r.Name, $r.Count, $r.Last.ToString('HH:mm:ss')
        $sub = "父进程：{0}" -f $r.Parent
        $p.Children.Add((New-ProcRow -Head $head -Sub $sub -Cmd $r.CommandLine -Hot ($r.Count -ge 5))) | Out-Null
    }
    Set-Status ("共 {0} 类控制台进程" -f $rows.Count)
}

function Build-RecentRuns {
    $p = $Script:UI.RecentRunPanel
    $p.Children.Clear()

    if (-not (Test-TaskLogEnabled)) {
        $t1 = New-TextBlock -Wrap $true -Size 12.5 -Color '#7A6B45' -Text '任务运行记录当前是【关闭】的，所以查不到历史。'
        $p.Children.Add($t1) | Out-Null
        $t2 = New-TextBlock -Wrap $true -Size 12 -Color '#565349' -Text @'
点上面的「开启运行记录」把它打开，然后：

1. 该干嘛干嘛，等下次黑框弹出来
2. 看到之后马上回到这里点「刷新记录」
3. 时间对得上的那一条，就是弹窗的元凶

这个记录只占几 MB，平时对性能没有影响。
'@
        $t2.Margin = New-Thick 0 10 0 0
        $p.Children.Add($t2) | Out-Null
        return
    }

    $runs = @(Get-RecentTaskRuns -Hours 24)
    if ($runs.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#6E6B63' -Text '过去 24 小时没有任务运行记录。如果刚刚才开启记录，那要等下次任务运行才会有内容。')) | Out-Null
        return
    }

    $h = New-TextBlock -Wrap $true -Size 11.5 -Color '#6E6B63' -Text '按最近运行时间排序。跑得特别频繁（次数很多）的那几条，最可能就是你看到的规律性弹窗。'
    $h.Margin = New-Thick 0 0 0 10
    $p.Children.Add($h) | Out-Null

    foreach ($r in $runs) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = Get-Brush '#FBFAF8'
        $b.CornerRadius = New-Object System.Windows.CornerRadius 4
        $b.Padding = New-Thick 10 7 10 8
        $b.Margin = New-Thick 0 0 0 5
        $sp = New-Object System.Windows.Controls.StackPanel
        $col = if ($r.Count -ge 10) { '#7A6B45' } else { '#4A4842' }
        $sp.Children.Add((New-TextBlock -Text ("{0}   ·   24 小时内跑了 {1} 次" -f $r.Last.ToString('MM-dd HH:mm:ss'), $r.Count) -Size 12 -Bold $true -Color $col)) | Out-Null
        $t1 = New-TextBlock -Text $r.TaskName -Size 11.5 -Color '#5E5B54' -Wrap $true
        $t1.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($t1) | Out-Null
        if ($r.Exe) {
            $t2 = New-TextBlock -Text $r.Exe -Size 10.5 -Color '#6E6B63' -Wrap $true
            $t2.Margin = New-Thick 0 2 0 0
            $sp.Children.Add($t2) | Out-Null
        }
        $b.Child = $sp
        $p.Children.Add($b) | Out-Null
    }
}

# ---------------------------------------------------------------------
#  8. 系统体检页
# ---------------------------------------------------------------------
$Script:LastReportText = ''

function Build-HealthUI {
    Set-Busy $true
    Set-Status '正在收集硬件信息…'
    $info = $Script:UI.InfoPanel
    $info.Children.Clear()
    $sb = New-Object System.Text.StringBuilder

    $t = New-TextBlock -Text '硬件信息' -Size 15 -Bold $true
    $t.Margin = New-Thick 0 0 0 12
    $info.Children.Add($t) | Out-Null

    foreach ($row in (Get-SystemReport)) {
        $k = New-TextBlock -Text $row.Key -Size 11.5 -Color '#55606F'
        $info.Children.Add($k) | Out-Null
        $v = New-TextBlock -Text $row.Value -Size 12.5 -Color '#3C3A34' -Wrap $true
        $v.Margin = New-Thick 0 1 0 11
        $info.Children.Add($v) | Out-Null
        [void]$sb.AppendLine("$($row.Key)：$($row.Value)")
    }

    Set-Status '正在做系统体检…'
    Sync-UI
    $ap = $Script:UI.AdvicePanel
    $ap.Children.Clear()
    $t2 = New-TextBlock -Text '体检结论（按性价比从高到低排序）' -Size 15 -Bold $true
    $t2.Margin = New-Thick 0 0 0 12
    $ap.Children.Add($t2) | Out-Null
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('===== 体检结论 =====')

    foreach ($a in (Get-HealthAdvice)) {
        $c = switch ($a.Level) {
            '严重' { @{ Line = '#8A5750'; Bg = '#EFE3E0' } }
            '建议' { @{ Line = '#7A6B45'; Bg = '#F0EADC' } }
            default { @{ Line = '#556B54'; Bg = '#E7EBE4' } }
        }
        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush $c.Bg
        $card.BorderBrush = Get-Brush $c.Line
        $card.BorderThickness = New-Thick 4 0 0 0
        $card.CornerRadius = New-Object System.Windows.CornerRadius 6
        $card.Padding = New-Thick 14 12 14 12
        $card.Margin = New-Thick 0 0 0 10

        $sp = New-Object System.Windows.Controls.StackPanel
        $h = New-Object System.Windows.Controls.StackPanel
        $h.Orientation = 'Horizontal'
        $h.Children.Add((New-Badge -Text $a.Level -Fg $c.Line -Bg (Get-TintBg $c.Line))) | Out-Null
        $sp.Children.Add($h) | Out-Null
        $ttl = New-TextBlock -Text $a.Title -Size 14 -Bold $true -Wrap $true
        $ttl.Margin = New-Thick 0 4 0 6
        $sp.Children.Add($ttl) | Out-Null
        $sp.Children.Add((New-TextBlock -Text (Format-Reflow $a.Text) -Size 12.5 -Color '#565349' -Wrap $true)) | Out-Null
        $card.Child = $sp
        $ap.Children.Add($card) | Out-Null

        [void]$sb.AppendLine()
        [void]$sb.AppendLine("[$($a.Level)] $($a.Title)")
        [void]$sb.AppendLine($a.Text)
    }
    $Script:LastReportText = $sb.ToString()
    Set-Busy $false
    Set-Status '体检完成'
}

# ---------------------------------------------------------------------
#  帧数瓶颈诊断 —— 回答「点了一堆优化，帧数怎么没变」
#  把右边那栏换成诊断结果；点「重新体检」就换回普通体检结论。
# ---------------------------------------------------------------------
function Build-FpsDiagUI {
    Set-Busy $true
    Set-Status '正在诊断帧数瓶颈…'
    Sync-UI

    $ap = $Script:UI.AdvicePanel
    $ap.Children.Clear()

    $t = New-TextBlock -Text '帧数瓶颈诊断' -Size 15 -Bold $true
    $t.Margin = New-Thick 0 0 0 4
    $ap.Children.Add($t) | Out-Null
    $sub = New-TextBlock -Size 12.5 -Color '#565349' -Wrap $true -Text (
        '按影响大小排序。标「瓶颈」的是真正卡住你帧数的东西，' +
        '标「已到顶」的说明这一环本来就是最优的 —— 点了也不会变，' +
        '那通常就是「感觉没用」的原因。')
    $sub.Margin = New-Thick 0 0 0 12
    $ap.Children.Add($sub) | Out-Null

    $diag = @(Get-FpsDiagnosis)
    foreach ($d in $diag) {
        $c = switch ($d.Level) {
            '瓶颈'   { @{ Line = '#8A5750'; Bg = '#EFE3E0' } }
            '待优化' { @{ Line = '#7A6B45'; Bg = '#F0EADC' } }
            '信息'   { @{ Line = '#55606F'; Bg = '#E7EAEF' } }
            default  { @{ Line = '#556B54'; Bg = '#E7EBE4' } }
        }
        $card = New-Object System.Windows.Controls.Border
        $card.Background      = Get-Brush $c.Bg
        $card.BorderBrush     = Get-Brush $c.Line
        $card.BorderThickness = New-Thick 4 0 0 0
        $card.CornerRadius    = New-Object System.Windows.CornerRadius 6
        $card.Padding         = New-Thick 14 12 14 12
        $card.Margin          = New-Thick 0 0 0 10

        $sp = New-Object System.Windows.Controls.StackPanel
        $h  = New-Object System.Windows.Controls.StackPanel
        $h.Orientation = 'Horizontal'
        $h.Children.Add((New-Badge -Text $d.Level -Fg $c.Line -Bg (Get-TintBg $c.Line))) | Out-Null
        $sp.Children.Add($h) | Out-Null
        $ttl = New-TextBlock -Text $d.Title -Size 14 -Bold $true -Wrap $true
        $ttl.Margin = New-Thick 0 4 0 6
        $sp.Children.Add($ttl) | Out-Null
        $sp.Children.Add((New-TextBlock -Text (Format-Reflow $d.Text) -Size 12.5 -Color '#565349' -Wrap $true)) | Out-Null
        $card.Child = $sp
        $ap.Children.Add($card) | Out-Null
    }

    $n = @($diag | Where-Object { $_.Level -eq '瓶颈' }).Count
    Set-Busy $false
    if ($n -gt 0) { Set-Status ("帧数诊断完成 —— 发现 {0} 个真正的瓶颈，看红色那几条" -f $n) }
    else          { Set-Status '帧数诊断完成 —— 没发现硬件层面的瓶颈，看「已到顶」那几条的说明' }
}

# ---------------------------------------------------------------------
#  9. 按钮事件
# ---------------------------------------------------------------------
$Script:UI.BtnPickRecommended.Add_Click({
        foreach ($tw in $Script:Tweaks) {
            $row = $Script:TweakRows[$tw.Id]
            if ($row -and $row.Check.IsEnabled) { $row.Check.IsChecked = [bool]$tw.Recommended }
        }
        Update-TweakSelCount
        Set-Status '已勾选所有推荐项（推荐项都是低风险、绝大多数机器都适用的）'
    })
$Script:UI.BtnPickNone.Add_Click({
        foreach ($row in $Script:TweakRows.Values) { $row.Check.IsChecked = $false }
        Update-TweakSelCount
        Set-Status '已取消全部勾选'
    })
$Script:UI.BtnRescan.Add_Click({ Update-TweakStates })
$Script:UI.TweakSearch.Add_TextChanged({ Update-TweakFilter })
$Script:UI.CleanSearch.Add_TextChanged({ Update-CleanFilter })
$Script:UI.BtnApplySelected.Add_Click({ Invoke-ApplyTweaks (Get-CheckedTweaks) })
$Script:UI.BtnRevertSelected.Add_Click({ Invoke-RevertTweaks (Get-CheckedTweaks) })
$Script:UI.BtnRevertAll.Add_Click({
        $applied = @($Script:Tweaks | Where-Object { (Test-TweakAvailable $_) -and (Test-TweakApplied $_) })
        if ($applied.Count -eq 0) {
            [System.Windows.MessageBox]::Show('当前没有任何已应用的优化项需要还原。', '电脑调优助手') | Out-Null
            return
        }
        Invoke-RevertTweaks $applied
    })

$Script:UI.BtnRestorePoint.Add_Click({
        Set-Status '正在创建系统还原点，可能需要 10~60 秒…'
        $ok = New-SystemRestorePoint -Description 'PC调优助手-手动创建'
        if ($ok) {
            [System.Windows.MessageBox]::Show('系统还原点创建成功。万一出问题，可以在「设置 → 系统 → 恢复」里回滚到这个时间点。', '电脑调优助手') | Out-Null
        } else {
            [System.Windows.MessageBox]::Show("创建还原点失败。`r`n`r`n最常见的原因是系统保护被关闭了。打开方法：`r`n控制面板 → 系统 → 系统保护 → 选中 C 盘 → 配置 → 启用系统保护。`r`n`r`n不影响本工具的使用（工具自己有完整的备份/还原机制）。", '电脑调优助手') | Out-Null
        }
        Set-Status '就绪'
    })

$Script:UI.BtnScanJunk.Add_Click({ Invoke-ScanJunk })
$Script:UI.BtnClean.Add_Click({ Invoke-CleanSelected })
$Script:UI.BtnPickCleanRec.Add_Click({
        foreach ($it in $Script:CleanItems) { $Script:CleanRows[$it.Id].Check.IsChecked = [bool]$it.Recommended }
        Update-CleanSelCount
    })
$Script:UI.BtnPickCleanNone.Add_Click({
        foreach ($row in $Script:CleanRows.Values) { $row.Check.IsChecked = $false }
        Update-CleanSelCount
    })

$Script:UI.BtnRefreshStartup.Add_Click({ Build-StartupUI })

$Script:UI.BtnInspect.Add_Click({ Invoke-Inspect })
$Script:UI.BtnInspectFilter.Add_Click({
        $Script:InspectFilterOn = -not $Script:InspectFilterOn
        $this.Content = if ($Script:InspectFilterOn) { '显示全部' } else { '只看会弹黑框的' }
        if ($Script:Findings.Count -gt 0) { Show-Findings }
    })
$Script:UI.BtnRecentRuns.Add_Click({ Build-RecentRuns; Set-Status '任务运行记录已刷新' })
$Script:UI.BtnWatchStart.Add_Click({ Start-LiveWatch })
$Script:UI.BtnWatchStop.Add_Click({ Stop-LiveWatch })
$Script:UI.BtnProcLog.Add_Click({ Show-ProcLog })
$Script:UI.BtnProcAudit.Add_Click({
        if (Test-ProcAuditEnabled) {
            $r = [System.Windows.MessageBox]::Show("「持续记录」当前是开启的。`r`n`r`n要关掉吗？`r`n（排查完建议关掉——开着的时候每创建一个进程都会写一条安全日志，量很大。）", '持续记录', 'YesNo', 'Question')
            if ($r -eq 'Yes') { Disable-ProcAudit | Out-Null; $this.Content = '开启持续记录'; Set-Status '持续记录已关闭' }
            return
        }
        $r = [System.Windows.MessageBox]::Show(@"
即将打开 Windows 自带的「进程创建审核」，之后系统会把每一次进程创建都记进安全日志，包含完整命令行和父进程。

【为什么要开】
黑框不定时出现、蹲不到的时候，靠这个事后回查最有效。

【会改什么】
· 审核策略：进程创建 → 记录成功事件
· 一个注册表值：让日志带上完整命令行
两处都已备份，点「关闭」或用「全部还原」随时能恢复原状。

【代价】
安全日志写入量会变大（每开一个程序一条）。排查完记得关掉。

现在开启吗？
"@, '开启持续记录', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        if (Enable-ProcAudit) {
            $this.Content = '关闭持续记录'
            [System.Windows.MessageBox]::Show("已开启。`r`n`r`n接下来正常用电脑，等黑框出现过几次之后，回到这一页点「查看进程记录」。`r`n`r`n排查完记得回来把它关掉。", '电脑调优助手') | Out-Null
            Set-Status '持续记录已开启'
        } else {
            [System.Windows.MessageBox]::Show('开启失败，详见日志页。', '电脑调优助手') | Out-Null
        }
    })
$Script:UI.BtnEnableTaskLog.Add_Click({
        if (Test-TaskLogEnabled) {
            [System.Windows.MessageBox]::Show('运行记录本来就是开着的，直接点「刷新记录」即可。', '电脑调优助手') | Out-Null
            return
        }
        if (Enable-TaskLog) {
            [System.Windows.MessageBox]::Show("已开启任务运行记录。`r`n`r`n接下来这样抓现行：`r`n1. 正常用电脑，等下次黑框弹出来`r`n2. 看到之后马上回到这一页点「刷新记录」`r`n3. 时间对得上的那一条就是元凶`r`n`r`n这个记录只占几 MB，不影响性能。", '电脑调优助手') | Out-Null
            Build-RecentRuns
        } else {
            [System.Windows.MessageBox]::Show('开启失败，详见日志页。', '电脑调优助手') | Out-Null
        }
    })
$Script:UI.BtnHealthScan.Add_Click({ Build-HealthUI })
$Script:UI.BtnFpsDiag.Add_Click({ Build-FpsDiagUI })
$Script:UI.BtnRefreshAppx.Add_Click({ Build-AppxUI })
$Script:UI.BtnUninstallAppx.Add_Click({ Invoke-AppxUninstall })
$Script:UI.BtnCheckAppxSafe.Add_Click({
        # 只勾「可以删」那一档；「看情况」的要用户自己看完说明再决定
        $n = 0
        foreach ($k in $Script:AppxRows.Keys) {
            $cb = $Script:AppxRows[$k]
            if (-not $cb.IsEnabled) { continue }
            if ($cb.Tag.Verdict -eq '可以删') { $cb.IsChecked = $true; $n++ }
        }
        Update-AppxCounter
        Set-Status "已勾选 $n 个「可以删」的应用"
    })

$Script:UI.BtnAddExclusion.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择游戏安装目录（例如 D:\Steam\steamapps\common）'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $path = $dlg.SelectedPath
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            Write-Log "已把 $path 加入 Windows Defender 扫描白名单" '成功'
            [System.Windows.MessageBox]::Show(
                "已添加白名单：`r`n$path`r`n`r`n作用：Windows Defender 以后不再实时扫描这个文件夹里的文件。游戏读取大量资源文件时不用每个都过一遍杀毒，加载速度和帧数稳定性都会改善。`r`n`r`n注意：白名单里的文件不再被保护，所以只加你信任的游戏目录，不要加下载文件夹。", '电脑调优助手') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show("添加失败：$($_.Exception.Message)`r`n`r`n如果你装了第三方杀毒软件（360/火绒/腾讯管家），Windows Defender 会被自动关闭，这个功能就用不了了 —— 请去那个杀毒软件里手动添加信任目录。", '电脑调优助手') | Out-Null
        }
    })

$Script:UI.BtnSfc.Add_Click({
        $r = [System.Windows.MessageBox]::Show(
            "将在新窗口里运行 sfc /scannow，它会扫描并自动修复损坏的系统文件。`r`n`r`n· 需要 5~20 分钟`r`n· 期间不要关掉那个黑窗口`r`n· 扫完如果提示「已修复」，建议重启一次`r`n`r`n什么时候该用：系统莫名其妙报错、某些功能打不开、蓝屏频繁。`r`n`r`n现在开始吗？", '检查系统文件', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Start-Process 'cmd.exe' -ArgumentList '/k', 'sfc /scannow' -Verb RunAs
        Write-Log '已启动 sfc /scannow 系统文件检查' '信息'
    })

$Script:UI.BtnCopyReport.Add_Click({
        if ([string]::IsNullOrWhiteSpace($Script:LastReportText)) { Build-HealthUI }
        try {
            Set-Clipboard -Value $Script:LastReportText
            [System.Windows.MessageBox]::Show('体检报告已复制到剪贴板，可以直接粘贴发给别人看。', '电脑调优助手') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show("复制失败：$($_.Exception.Message)", '电脑调优助手') | Out-Null
        }
    })

$Script:UI.BtnOpenBackup.Add_Click({ Start-Process explorer.exe -ArgumentList $Script:BackupDir })
$Script:UI.BtnExportReport.Add_Click({ Export-DiagnosticReport })

# ---- 快捷键 ----
# Ctrl+F 跳到当前页的搜索框，F5 重新检测。都是用惯了的习惯，省得去找鼠标。
$Script:Window.Add_PreviewKeyDown({
        $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
        if ($ctrl -and $_.Key -eq 'F') {
            switch ($Script:UI.Tabs.SelectedIndex) {
                0 { $Script:UI.TweakSearch.Focus() | Out-Null; $_.Handled = $true }
                1 { $Script:UI.CleanSearch.Focus() | Out-Null; $_.Handled = $true }
            }
        } elseif ($_.Key -eq 'F5') {
            switch ($Script:UI.Tabs.SelectedIndex) {
                0 { Update-TweakStates }
                1 { Invoke-ScanJunk }
                3 { Invoke-Inspect }
                4 { Build-StartupUI }
                5 { Build-HealthUI }
            }
            $_.Handled = $true
        } elseif ($_.Key -eq 'Escape') {
            # Esc 清空搜索，回到完整列表
            if ($Script:UI.Tabs.SelectedIndex -eq 0 -and $Script:UI.TweakSearch.Text) { $Script:UI.TweakSearch.Text = ''; $_.Handled = $true }
            if ($Script:UI.Tabs.SelectedIndex -eq 1 -and $Script:UI.CleanSearch.Text) { $Script:UI.CleanSearch.Text = ''; $_.Handled = $true }
        }
    })

# ---------------------------------------------------------------------
#  10. 启动
# ---------------------------------------------------------------------
$osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
# 套用上次选的皮肤（读不到就是默认的暖灰）
$Script:ColorRemap = @{}
$Script:ThemeImage = ''
$Script:ThemeOpacity = 0.88
try {
    $savedTheme = Get-ThemeSetting
    Set-AppTheme -Name $savedTheme.Name -Image $savedTheme.Image -Opacity $savedTheme.Opacity
    Apply-PanelOpacity
} catch { Write-Log "套用皮肤失败，用默认配色：$($_.Exception.Message)" '警告' }

$Script:Window.Title     = "电脑调优助手 v$Script:AppVersion"
$Script:UI.VerBadge.Text = "v$Script:AppVersion"
$Script:UI.SubTitle.Text = "v$Script:AppVersion $Script:AppVersionName  ·  管理员模式  ·  $osCaption  ·  改动全部可还原"

Write-Log '=== 电脑调优助手已启动（管理员模式）===' '信息'

Build-TweakUI
Build-PresetUI
Build-CleanUI
Update-CleanSelCount
Update-TweakStates -PreselectRecommended $true

# 启动项和体检比较慢，等窗口显示出来之后再在后台补上
$Script:Window.Add_ContentRendered({
        Build-StartupUI
        Build-MaintainUI
        Build-BigFileDrives
        Build-RecentRuns
        Build-ThemeUI
        if (Test-ProcAuditEnabled) { $Script:UI.BtnProcAudit.Content = '关闭持续记录' }
        Build-HealthUI
        Set-Status '就绪 —— 先看「系统体检」页（有 ACE 反作弊环境检测），再回来点「★ 三合一 FPS 通用」预设'
    })

# ---------------------------------------------------------------------
#  「自带软件」页按需构建
#
#  为什么不在开机时一起建：Get-AppxPackage 要扫几十个包，
#  在慢一点的机器上要好几秒，摊在启动里会让人以为程序卡死了。
#  改成第一次点进这一页时才扫，之后缓存着不重复扫。
#  （「刷新列表」按钮仍然可以手动重扫。）
#
#  ★ 注意 SelectionChanged 会冒泡 ★
#    页面里任何一个下拉框、列表变了选择都会触发到这里，
#    所以必须判断事件源是不是 TabControl 本身，否则会反复重扫。
# ---------------------------------------------------------------------
$Script:AppxBuilt = $false
$Script:UI.Tabs.Add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $Script:UI.Tabs) { return }
        $header = "$($Script:UI.Tabs.SelectedItem.Header)"
        if ($header -eq '自带软件' -and -not $Script:AppxBuilt) {
            $Script:AppxBuilt = $true
            Build-AppxUI
        }
    })

# 自检模式：把剩下两页也构建一遍，报告结果后退出，不显示窗口
if ($SelfTest) {
    Build-StartupUI
    Build-MaintainUI
    Build-BigFileDrives
    Build-RecentRuns
    Invoke-Inspect
    Build-ThemeUI
    $themeCards = $Script:UI.ThemePanel.Children.Count
    Build-AppxUI
    Build-FpsDiagUI
    $fpsCards = $Script:UI.AdvicePanel.Children.Count
    Build-HealthUI
    Write-Host ('自检通过：优化项 {0} / 预设 {1} / 清理项 {2} / 启动项 {3} / 维护卡片 {4} / 盘符 {5} / 排查结果 {6} / 运行记录 {7} / 体检卡片 {8} / 帧数诊断 {9} / 自带应用 {10} / 皮肤 {11}' -f `
            $Script:UI.TweakPanel.Children.Count, $Script:Presets.Count,
        $Script:UI.CleanPanel.Children.Count, $Script:UI.StartupPanel.Children.Count,
        $Script:UI.MaintainPanel.Children.Count, $Script:UI.BigFileDrives.Children.Count,
        $Script:UI.InspectPanel.Children.Count, $Script:UI.RecentRunPanel.Children.Count,
        $Script:UI.AdvicePanel.Children.Count, $fpsCards, $Script:UI.AppxPanel.Children.Count, $themeCards)
    exit 0
}

# 一切都加载成功了，把背后那个黑色控制台窗口藏起来，只留界面。
# （放在最后一步是故意的：万一前面任何一步出错，控制台会留在屏幕上，
#   错误信息看得见，方便排查。）
try {
    Add-Type -Name ConsoleWin -Namespace PCTuner -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    $h = [PCTuner.ConsoleWin]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [PCTuner.ConsoleWin]::ShowWindow($h, 0) | Out-Null }
} catch { }

$Script:Window.Add_Closed({ try { if ($Script:WatchTimer) { $Script:WatchTimer.Stop() }; Stop-ProcWatch } catch { } })
$Script:Window.ShowDialog() | Out-Null
