<#
=====================================================================
  PCTuner.ps1  ——  电脑调优助手  主程序
---------------------------------------------------------------------
  用法：双击同目录下的「电脑调优助手.exe」即可（会自动申请管理员权限）。

  十个页面（左侧边栏切换）：
    概览 / 性能优化 / 垃圾清理 / 日常维护 / 弹窗排查 /
    启动项管理 / 自带软件 / 个性化 / 系统体检 / 操作日志

  界面：v6.0 起是浅色扁平风格，控件库 MaterialDesignInXamlToolkit，
  设计规范见 design.md。

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
    [switch]$AutoClean,

    # 出图模式：把每一页各存一张 PNG 到指定目录，然后自动退出。
    # 用来更新 README 里的界面截图 —— 也是改完界面之后唯一靠谱的自查方式：
    # 程序会自己提权，外面的截图脚本发不进鼠标键盘、也拍不到提权窗口。
    [string]$Shot = '',

    # 只出某一页（页签序号，从 0 数）。不给就全出。
    [int]$ShotTab = -1,

    # 出图时临时把窗口拉到这么高，好把整页一次拍全。
    # 注意窗口高度会被显示器工作区卡住，拉不到任意高 —— 页面更长就配合 -ShotScroll。
    [int]$ShotH = 0,

    # 出图前把页面里的滚动区往下滚这么多像素，用来拍长页面的下半截。
    [int]$ShotScroll = 0,

    # 出图时模拟的显示缩放（125 / 150）。本机是 100% 时用它看高分屏下的样子：
    # 进程内把界面按这个缩放重新排版（VisualTreeHelper.SetRootDpi），再按对应像素出图 ——
    # 和真在 125% 屏上跑一样走「按设备像素取整」，不是把 100% 的图放大。
    [int]$ShotDpi = 0,

    # 出图前先把需要扫描才有内容的页扫一遍（弹窗排查）。
    [switch]$ShotScan,

    # 出图时把窗口留在屏幕上、不自动关。
    # 悬停、按下这些状态 RenderTargetBitmap 拍不到，
    # 得真把鼠标放上去拍屏幕才算验过。
    [switch]$ShotLive,

    # 测卡顿模式：自动把每一页切两遍、在概览页停几秒，记下每一帧的间隔、
    # 切页到出第一帧的时间、每次定时刷新在界面线程上占了多久，写成 JSON 后退出。
    # 和出图模式一样不提权、窗口放在屏幕外。改性能前后各跑一次，拿数字对比。
    [string]$Perf = ''
)

$ErrorActionPreference = 'Continue'

# ===== 版本号 =====
# 改版本号只改这一处，标题栏 / 副标题 / 诊断报告都从这里取。
$Script:AppVersion     = '6.2'
$Script:AppVersionDate = '2026-09-28'

# ---------------------------------------------------------------------
#  0.1 高分屏：声明「按显示器」DPI 感知（v6.2）—— 必须排在建任何窗口之前
# ---------------------------------------------------------------------
#  ★ 实测（2026-09-28）★ exe 启动壳 manifest 里声明的 per-monitor 只管它自己，
#    真正跑界面的 powershell.exe 由 WPF 设成「系统级」。系统级在两种情况下会被 Windows 按位图拉伸、字发虚：
#      · 改了缩放（比如 100% → 125%）但没注销重登 —— 系统级按「登录时」的缩放画
#      · 外接一块缩放不同的屏，窗口拖过去
#  所以在 WPF 之前先把进程声明成 Per-Monitor V2，并打开 WPF 自己的「跟着显示器缩放」开关
#  （powershell.exe 按 .NET 4.0 的老规矩跑，这个开关默认是关的 —— 不开的话换屏时窗口不会跟着缩放）。
#  声明失败（Win10 1703 以前没有 V2）就退回系统级，和 v6.1 一样。
try { [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false) } catch { }
try {
    . (Join-Path (Split-Path -Parent $PSCommandPath) 'Modules\Native.ps1')
    $api0 = Get-NativeApi
    if (-not $api0::SetProcessDpiAwarenessContext([IntPtr]::new(-4))) { [void]$api0::SetProcessDPIAware() }
} catch { }

# ---------------------------------------------------------------------
#  0. 加载 .NET 界面库
# ---------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------------
#  0.4 先解除「网络来源」锁定 —— 必须排在加载任何 DLL 之前
# ---------------------------------------------------------------------
#  从微信 / QQ / 浏览器拿到的压缩包，解压出来的**每一个文件**都带一条
#  叫 Zone.Identifier 的隐藏数据流（右键属性里那个「解除锁定」就是它）。
#    · 带着它的 .ps1，PowerShell 报「对路径的访问被拒绝」
#    · 带着它的 .dll，PowerShell 5.1 的 Add-Type 直接拒载
#      （FileLoadException 0x80131515，loadFromRemoteSources —— 2026-09-27 实测）
#  exe 启动壳已经先删过一遍了；这里再做一次，是给「诊断启动.bat」和
#  直接跑 .ps1 的人兜底。清不掉也没关系，下面的诊断会说清是什么情况。
try {
    Get-ChildItem -LiteralPath (Split-Path -Parent $PSCommandPath) -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
        }
} catch { }

# ---------------------------------------------------------------------
#  0.5 加载 MaterialDesignInXamlToolkit（界面控件库，MIT 协议，随包分发）
# ---------------------------------------------------------------------
#  v6.0 起界面控件库从 HandyControl 换成 MDIX（net462 版，跑在 5.1 的 .NET 4.x 上）。
#  DLL 放在 Lib\ 里，不安装、不进 GAC、不写注册表。三个文件缺一不可：
#    MaterialDesignThemes.Wpf.dll    控件样式、图标、切页动画
#    MaterialDesignColors.dll        调色板
#    Microsoft.Xaml.Behaviors.dll    前者的依赖
#
#  ★ 必须先 new 一个 Application ★
#    pack:// 这个 URI 协议是 Application 初始化时注册的，没有它连 DLL 里的资源都找不到。
#  主题字典本身写在窗口 XAML 里（见第 4 节），由 XAML 解析器去设 Source ——
#  在 PowerShell 里手写 $rd.Source = … 会被当成往字典里塞键，样式静默不生效。
$Script:MdLoaded = $false
try {
    $libDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Lib'
    foreach ($d in 'Microsoft.Xaml.Behaviors.dll', 'MaterialDesignColors.dll', 'MaterialDesignThemes.Wpf.dll') {
        $dp = Join-Path $libDir $d
        if (Test-Path -LiteralPath $dp) { Add-Type -Path $dp -ErrorAction Stop }
    }
    if ('MaterialDesignThemes.Wpf.PackIcon' -as [type]) {
        if (-not [System.Windows.Application]::Current) {
            $null = New-Object System.Windows.Application
        }
        $Script:MdLoaded = $true
    }
} catch {
    # 加载失败不直接崩，下面的文件检查会给出人话提示
    $Script:MdLoadError = "$($_.Exception.Message)"
}

# ---------------------------------------------------------------------
#  0.6 加载随包字体（MiSans，小米出品，免费商用）
# ---------------------------------------------------------------------
#  ★ 为什么非要自带字体 ★
#    不带的话界面用 Windows 自带的「微软雅黑 UI」。那是系统默认字，
#    字形偏宽、可用字重只有常规和粗体两档 —— 做不出报告单需要的
#    「表头半粗 / 结果常规 / 参考范围细」三层，一眼就是系统默认样子。
#
#  ★ 不安装到系统 ★
#    直接从 Fonts\ 目录按文件 URI 加载，注册表和系统字体目录一点不动，
#    删掉文件夹就干干净净，也不需要管理员权限。
#
#  ★ 授权 ★
#    MiSans 允许作为嵌入式字体随软件分发，但要求在软件中注明。
#    见 Fonts\字体说明.txt、README 和「使用说明」。
#
#  加载失败不影响功能，按 $Script:FontStack 一路退回去找。
$Script:FontLoaded = $false
$Script:FontStack = 'Microsoft YaHei UI, Segoe UI'
try {
    $fontDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Fonts'
    if (Test-Path -LiteralPath (Join-Path $fontDir 'MiSans-Regular.ttf')) {
        # ★ 基准 URI 必须以 / 结尾 ★ 少了斜杠，WPF 会把最后一段当文件名，
        #   拼出来的路径指向 Fonts 的上级目录，**静默**拿不到字体。
        # ★ 必须用 .Replace 不能用 -replace ★
        #   -replace 是**正则**替换，模式里单独一个反斜杠是非法转义，
        #   直接抛异常 —— 而这个 try 把异常吞了，结果就是「静默退回系统字体」，
        #   界面看起来一切正常，只是字不对，极难发现。
        #   .Replace 是普通字符串替换，没有转义这回事。
        $fontBase = 'file:///' + $fontDir.Replace('\', '/').Replace(' ', '%20') + '/'
        $probe = New-Object System.Windows.Media.FontFamily ([Uri]$fontBase), './#MiSans'
        if (@($probe.GetTypefaces()).Count -gt 0) {
            $Script:FontLoaded = $true
            $Script:FontStack = "$fontBase#MiSans, MiSans, Noto Sans SC, Microsoft YaHei UI, Segoe UI"
        }
    }
} catch { $Script:FontLoadError = "$($_.Exception.Message)" }
# 没加载上就是没加载上，记下来。自检会检查这个 ——
# 「静默退回系统字体」这种失败必须有人管，不然谁都发现不了。
if (-not $Script:FontLoaded -and -not $Script:FontLoadError) {
    $Script:FontLoadError = "Fonts\MiSans-Regular.ttf 不在，或 WPF 没能从它里面读出字族"
}

# ---------------------------------------------------------------------
#  1. 检查管理员权限，没有就重新以管理员身份启动自己
#     （修改注册表 HKLM、系统服务、电源计划都需要管理员）
# ---------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
# ★ 出图模式不提权 ★
#   它只把界面画出来拍一张，一个设置都不改。
#   为了拍张图弹一次 UAC 让人点「是」，那是拿打扰换方便。
#   代价：SMART、传感器温度这些要管理员才读得到的会显示「—」。
#   要拍带真实读数的图，从管理员终端里跑。
if (-not $SelfTest -and -not $AutoClean -and -not $Shot -and -not $Perf -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $exe = (Get-Process -Id $PID).Path
        $argv = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        # 提权是重开一个进程 —— 原来带的参数得跟着过去，否则出图模式一提权就没了
        if ($Shot) { $argv += @('-Shot', "`"$Shot`"") }
        if ($ShotTab -ge 0) { $argv += @('-ShotTab', "$ShotTab") }
        if ($ShotH -gt 0) { $argv += @('-ShotH', "$ShotH") }
        if ($ShotScroll -gt 0) { $argv += @('-ShotScroll', "$ShotScroll") }
        if ($ShotScan) { $argv += '-ShotScan' }
        if ($ShotLive) { $argv += '-ShotLive' }
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argv
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "这个工具需要管理员权限才能修改系统设置。`r`n`r`n请双击「电脑调优助手.exe」，并在弹出的「用户账户控制」里点「是」。",
            '电脑调优助手', 'OK', 'Warning') | Out-Null
    }
    exit
}

# ---------------------------------------------------------------------
#  2. 载入各个模块
# ---------------------------------------------------------------------
$Script:AppRoot = Split-Path -Parent $PSCommandPath
# 载入顺序有依赖：Engine 提供日志和注册表底座，其余模块都用得到，必须第一个
$Script:ModuleNames = @('Engine', 'Native', 'Tweaks', 'Games', 'Cleaner', 'Maintain', 'Inspect', 'SysInfo', 'Startup', 'Appx', 'Theme', 'Dash', 'Overclock', 'Motion')

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
# Lib 下的 DLL 也要查。
# 少了界面库，整个窗口的 XAML 都解析不了；
# 少了硬件监控库，概览页的温度和风扇会全变成「—」。
foreach ($d in 'MaterialDesignThemes.Wpf.dll', 'MaterialDesignColors.dll', 'Microsoft.Xaml.Behaviors.dll', 'LibreHardwareMonitorLib.dll', 'HidSharp.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:AppRoot "Lib\$d"))) { $missing += "Lib\$d" }
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
4. 双击里面的「电脑调优助手.exe」

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

    # .ps1 少了 UTF-8 BOM —— 报出来的错是「Unexpected token '淇℃伅'」这种
    # 完全看不懂的东西，不单独判一下的话，谁都想不到是编码问题
    if ($fi -and $fi.Extension -eq '.ps1') {
        try {
            $head = [byte[]]::new(3)
            $hs = [IO.File]::OpenRead($Path)
            $null = $hs.Read($head, 0, 3)
            $hs.Close()
            if (-not ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) {
                return @"
【原因】这个 .ps1 文件没有 UTF-8 BOM 标记。

PowerShell 5.1 读不带 BOM 的 UTF-8 文件时，会把中文当成
另一种编码来解析，于是满文件乱码、语法直接报错。
（报出来的是「Unexpected token '淇℃伅'」这种看不懂的东西。）

【怎么办】如果你没改过代码，说明文件在传输中被某个工具
「顺手转码」了（有些解压软件和同步网盘会干这事）。
重新下载一份原始的 zip 包，解压后直接用。

如果你改过代码：把这个文件另存为「UTF-8 with BOM」即可。
"@
            }
        } catch { }
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

# ---------- 1.2.9 编码自检（只在 -SelfTest 时做）----------
#
# ★ 这个坑踩过两次，所以做成自检的第一项 ★
#   .ps1 必须存成 UTF-8 **带 BOM**。少了 BOM，PowerShell 5.1 会把
#   文件当 ANSI 解析，中文全变乱码 —— 报出来的错是
#   「Unexpected token '淇℃伅'」这种完全看不懂的东西。
#
#   最坑的地方：用 PowerShell 7 单独 dot-source 那个文件是好的，
#   因为 7 默认按 UTF-8 读。只有正式启动（走 powershell.exe 5.1）才炸。
#   所以必须在这里查，不能等「反正我试过没问题」。
#
#   必须排在载入模块**之前** —— 排后面的话，模块自己先崩了，
#   这个检查根本轮不到跑。
if ($SelfTest) {
    $noBom = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Script:AppRoot -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)) {
        try {
            $head = [byte[]]::new(3)
            $hs = [IO.File]::OpenRead($f.FullName)
            $null = $hs.Read($head, 0, 3)
            $hs.Close()
            if (-not ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) {
                $noBom += $f.FullName.Substring($Script:AppRoot.Length + 1)
            }
        } catch { }
    }
    if ($noBom.Count -gt 0) {
        Write-Host ("自检失败：下面这些 .ps1 没有 UTF-8 BOM，PowerShell 5.1 会读成乱码" + [Environment]::NewLine + '  ' + ($noBom -join ([Environment]::NewLine + '  '))) -ForegroundColor Red
        exit 3
    }

    # ---------- 随包字体必须真的加载上 ----------
    #
    # ★ 这是一种「静默失败」，必须有人管 ★
    #   字体加载被 try/catch 包着，失败了就悄悄退回系统字体 ——
    #   程序照常运行、功能一切正常，只有字不对。
    #   实测踩过一次：$fontDir -replace '\' 在 PowerShell 里是非法正则转义，
    #   异常被吞掉，界面看着没毛病，其实整个界面都是微软雅黑。
    #   靠眼睛是发现不了的（谁记得 MiSans 的「验」字长什么样），只能靠自检。
    if (-not $Script:FontLoaded) {
        Write-Host ("自检失败：随包字体没有加载上，界面会退回系统默认字。" +
            [Environment]::NewLine + '  原因：' + $Script:FontLoadError) -ForegroundColor Red
        exit 4
    }
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

# =====================================================================
#  后台干活（v6.2）
# ---------------------------------------------------------------------
#  ★ 为什么要有这一节 ★
#    v6.1 之前所有读数都在界面线程上跑：概览页每秒一次的传感器刷新实测 130~210ms，
#    窗口出来之后还有一串体检 / 维护 / 硬件监控初始化要十几秒 —— 这段时间界面是死的，
#    朋友说的「运行起来一卡一卡的」就是它（测量方法见 -Perf）。
#
#  ★ 两条后台线 ★
#    · 传感器线：常驻，一秒读一次写进 $Script:Sensor（同步哈希表），界面只取现成的读数。
#      只在概览页可见时读 —— 切走就歇着，和原来「切走立刻停表」一个意思。
#    · 干活线：体检、硬盘健康、自带软件列表这类一次性的慢查询，读完回界面线程再画。
#  ★ 后台只读数据，不碰任何界面对象 ★ WPF 控件只能在建它的线程上动。
#  ★ 自检模式照旧同步跑 ★ 自检要数「建出来多少行」，异步回来之前它早就数完了。
# =====================================================================
$Script:BgLog = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Script:BgJobs = New-Object System.Collections.ArrayList
$Script:BgPool = $null
$Script:BgPoll = $null
$Script:BgModules = @('Engine', 'Native', 'Tweaks', 'Games', 'Cleaner', 'Maintain', 'Inspect', 'SysInfo', 'Startup', 'Appx', 'Theme', 'Dash', 'Overclock')

# 每条后台线开头都跑这一段：载入模块（每个后台线程只载一次），日志转回界面线程
$Script:BgBoot = @'
param($Root, $LogQ, $Mods, $WorkText, $Arg)
if (-not $Global:PctBgReady) {
    foreach ($m in $Mods) { . (Join-Path $Root "Modules\$m.ps1") }
    Initialize-Engine -RootPath $Root
    $Script:LogSink = { param($t, $l, $m) [void]$LogQ.Add(@($t, $l, $m)) }.GetNewClosure()
    $Global:PctBgReady = $true
}
if ($WorkText) { & ([scriptblock]::Create($WorkText)) $Arg }
'@

function Start-BgWork {
    <#
      在后台跑 $Work（纯读数据，别碰界面），跑完在界面线程上调 $OnDone，参数是 $Work 的返回值。
      自检模式下直接同步跑 —— 结果一样，只是不异步。
    #>
    param([string]$Name, [scriptblock]$Work, $Arg = $null, [scriptblock]$OnDone)
    if ($SelfTest) {
        $r = & $Work $Arg
        & $OnDone $r
        return
    }
    if (-not $Script:BgPool) {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $Script:BgPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2, $iss, $Host)
        $Script:BgPool.ApartmentState = 'STA'     # 有些 COM 查询（快捷方式、计划任务）要 STA
        $Script:BgPool.Open()
    }
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $Script:BgPool
    [void]$ps.AddScript($Script:BgBoot).AddArgument($Script:AppRoot).AddArgument($Script:BgLog).AddArgument($Script:BgModules).AddArgument($Work.ToString()).AddArgument($Arg)
    [void]$Script:BgJobs.Add(@{ Name = $Name; PS = $ps; H = $ps.BeginInvoke(); OnDone = $OnDone })
    Start-BgPoll
}

function Start-BgPoll {
    <# 60ms 看一眼后台有没有干完、有没有新日志。什么都不等了就停表。 #>
    if (-not $Script:BgPoll) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(80)
        $t.Add_Tick({
                Receive-BgLog
                foreach ($j in @($Script:BgJobs)) {
                    if (-not $j.H.IsCompleted) { continue }
                    [void]$Script:BgJobs.Remove($j)
                    $out = $null
                    try {
                        $res = $j.PS.EndInvoke($j.H)
                        if ($res.Count -gt 0) { $out = $res[$res.Count - 1] }
                        # ★ 别写 $out.BaseObject ★ 结果多半是哈希表，对哈希表点属性名 = 按这个名字取键，取出来是 $null
                        if ($out -is [System.Management.Automation.PSObject]) { $out = $out.psobject.BaseObject }
                        foreach ($e in $j.PS.Streams.Error) { Write-Log "后台任务「$($j.Name)」报错：$($e.Exception.Message)" '警告' }
                    } catch { Write-Log "后台任务「$($j.Name)」失败：$($_.Exception.Message)" '警告' }
                    try { $j.PS.Dispose() } catch { }
                    try { & $j.OnDone $out } catch { Write-Log "后台任务「$($j.Name)」回填界面失败：$($_.Exception.Message)" '警告' }
                }
                if ($Script:BgJobs.Count -eq 0 -and (-not $Script:SensorPs -or $Script:Sensor.Ready)) { Receive-BgLog; $this.Stop() }
            })
        $Script:BgPoll = $t
    }
    $Script:BgPoll.Start()
}

function Receive-BgLog {
    <# 后台线写的日志搬到界面的日志页（文件那边后台自己已经写过了，这里不重复写） #>
    while ($Script:BgLog.Count -gt 0) {
        $e = $Script:BgLog[0]
        $Script:BgLog.RemoveAt(0)
        [void]$Script:LogLines.Add(('[{0}] [{1}] {2}' -f $e[0], $e[1], $e[2]))
        [void]$Script:LogEntries.Add([PSCustomObject]@{ Time = $e[0]; Level = $e[1]; Message = $e[2] })
        if ($Script:LogSink) { try { & $Script:LogSink $e[0] $e[1] $e[2] } catch { } }
    }
}

# ---------------------------------------------------------------------
#  传感器线
# ---------------------------------------------------------------------
$Script:Sensor = [hashtable]::Synchronized(@{ Active = $false; Stop = $false; Ready = $false; LhmReady = $false; LhmError = $null; Snap = $null; Seq = 0; Ms = 0.0 })
$Script:SensorPs = $null

$Script:SensorLoop = @'
param($St)
Initialize-Dash
$St.LhmReady = [bool]$Script:LhmReady
$St.LhmError = $Script:LhmError
$St.Ready = $true
$tick = 0
while (-not $St.Stop) {
    if ($St.Active) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $Script:DashTick = $tick
        Update-DashSensors
        $St.Snap = @{ C = (Get-DashCpu); G = (Get-DashGpu); R = (Get-DashRam); D = (Get-DashDisk) }
        $St.Ms = $sw.Elapsed.TotalMilliseconds
        $St.Seq++
        $tick++
        $wait = 1000 - [int]$sw.ElapsedMilliseconds
        if ($wait -lt 100) { $wait = 100 }
    } else { $wait = 150 }
    Start-Sleep -Milliseconds $wait
}
Close-Dash
'@

function Start-SensorLoop {
    if ($Script:SensorPs) { return }
    if ($SelfTest) {
        # 自检不起线程：同步读一次，填一个快照就行
        Initialize-Dash
        Update-DashSensors
        $Script:Sensor.LhmReady = [bool]$Script:LhmReady
        $Script:Sensor.Ready = $true
        $Script:Sensor.Snap = @{ C = (Get-DashCpu); G = (Get-DashGpu); R = (Get-DashRam); D = (Get-DashDisk) }
        $Script:Sensor.Seq++
        return
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host)
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script:BgBoot).AddArgument($Script:AppRoot).AddArgument($Script:BgLog).AddArgument($Script:BgModules).AddArgument($Script:SensorLoop).AddArgument($Script:Sensor)
    $Script:SensorPs = $ps
    $Script:SensorH = $ps.BeginInvoke()
    Start-BgPoll
}

function Stop-SensorLoop {
    $Script:Sensor.Stop = $true
    # 不等它：后台线最多再睡 1 秒就自己退出；窗口关了进程就结束了
}

# ---------------------------------------------------------------------
#  3. 界面小工具
# ---------------------------------------------------------------------
function Get-Brush {
    <#
      拿一支画笔。参数写**色槽名**（'TextMain'、'Card'、'Stroke'……，见 design.md 1.1），
      或者语义色号（'#8A5750' 这类，见 design.md 1.3）。

      色槽按当前皮肤取值；语义色按当前皮肤只换明暗、不换色相 ——「高危」永远是红的。
      换肤之后 Redraw-AllPages 会把代码画的页面整个重画，所以这里返回的是一支普通画笔就够了。
    #>
    #  v6.2：按「实际色号」缓存冻结的画笔。原来每次都新 new 一支 —— 概览页每秒刷新时
    #  每张读数卡都换一支新画笔，WPF 就得重画那一块，哪怕颜色根本没变。
    #  按实际色号（不是色槽名）做键，换肤之后色槽指向别的色号，自然取到别的画笔。
    #  冻结的画笔不能做动画 —— 要做颜色过渡的地方（Start-ColorFade）自己会另建一支。
    param([string]$Hex)
    if ($Hex -eq 'Transparent') { return [System.Windows.Media.Brushes]::Transparent }
    $real = Get-ThemeHex $Hex
    $b = $Script:BrushCache[$real]
    if ($null -eq $b) {
        $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($real))
        $b.Freeze()
        $Script:BrushCache[$real] = $b
    }
    return $b
}
$Script:BrushCache = @{}
function New-Thick {
    param($L, $T, $R, $B)
    if ($null -eq $T) { return (New-Object System.Windows.Thickness $L) }
    return (New-Object System.Windows.Thickness $L, $T, $R, $B)
}
function New-Corner { param([double]$R) New-Object System.Windows.CornerRadius $R }
function Find-Descendants {
    <# 在可视树里找出某个类型的所有后代。出图模式滚页面用。 #>
    param($Root, [Type]$Type)
    $out = @()
    if ($null -eq $Root) { return $out }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
    for ($i = 0; $i -lt $n; $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)
        if ($c -is $Type) { $out += $c }
        $out += Find-Descendants $c $Type
    }
    return $out
}

function Sync-UI {
    <# WPF 版的 DoEvents：长任务执行时让界面还能刷新，不至于「假死」 #>
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $cb = [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $cb, $frame) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
# --- 测卡顿用的计数（-Perf 模式才记，平时一个判断就返回）---
$Script:PerfOn = [bool]$Perf
$Script:PerfTicks = @{}
$Script:PerfSteps = [ordered]@{}
function Add-PerfTick {
    param([string]$K, [double]$Ms)
    if (-not $Script:PerfOn) { return }
    if (-not $Script:PerfTicks.ContainsKey($K)) { $Script:PerfTicks[$K] = New-Object System.Collections.Generic.List[double] }
    $Script:PerfTicks[$K].Add($Ms)
}
function Invoke-Step {
    <# 跑一步并记下耗时（启动那一串 Build-* 用）。平时也记，开销就是一个秒表。 #>
    param([string]$Name, [scriptblock]$Do)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { . $Do } finally { $Script:PerfSteps[$Name] = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
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
        # v6.2：不忙的时候连动画一起停 —— 收起来的不确定进度条，它那条循环动画照样在跑，
        # 界面线程就一直按 60 帧在画一个看不见的东西
        $Script:UI.BusyBar.IsIndeterminate = $On
    }
    Sync-UI
}

# --- 列表行的配色（色槽名）。悬停 / 选中要有反馈，否则点了不知道自己点的是哪一条 ---
$Script:CARD_BG      = 'Card'
$Script:CARD_BORDER  = 'Stroke'
$Script:CARD_HOVER   = 'CardHover'
$Script:CARD_SEL_BG  = 'AccentTint'
$Script:SelectedCard = $null

# =====================================================================
#  动画开关
# ---------------------------------------------------------------------
#  补间和弹簧都在 Modules\Motion.ps1。这里只管「开不开」和右栏换内容时的进场。
#
#  ★ 只认本软件「个性化」页里的开关，不看 Windows 的「显示动画」★（老板拍板，2026-09-27）
#    老板自己的电脑关着系统动画；v6.0 那套「系统关了就减弱」在他那边等于少一截动画。
# =====================================================================
$Script:AnimEnabled = $true          # 用户在「个性化」页的开关

function Test-AnimOn { return (Test-MotionOn) }

function Sync-TransitionSwitch {
    <# 动画开关同步给 MDIX：关掉时它自带的过渡（输入框提示字上浮这类）瞬间完成 #>
    try {
        [MaterialDesignThemes.Wpf.TransitionAssist]::SetDisableTransitions($Script:Window, (-not (Test-AnimOn)))
    } catch { }
}

function Get-PageBlocks {
    <#
      一个页面由哪些「区块」组成 —— 切页时依次进场的就是它们。

      规则：Grid 和 ScrollViewer 只是排版骨架，往里钻；其余东西（卡片 Border、工具栏
      WrapPanel、说明文字、概览页的摘要行）各算一块，不再往里钻。
      按 XAML 里的先后顺序排 —— 页面都是按「从上到下、从左到右」写的，正好是阅读顺序。

      ★ 用逻辑树不用可视树 ★ 切页那一刻新页面还没排版，可视树可能还没建；
        但 TabItem.Content 这棵逻辑树在窗口加载时就全建好了，拿得到、而且能立刻设初值，不闪。
    #>
    param($Root)
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($el, $depth)
        if ($null -eq $el -or $depth -gt 6) { return }
        if ($el -is [System.Windows.UIElement] -and $el.Visibility -ne 'Visible') { return }
        if ($el -is [System.Windows.Controls.ScrollViewer]) { & $walk $el.Content ($depth + 1); return }
        if ($el -is [System.Windows.Controls.Grid] -and $null -eq $el.Background) {
            foreach ($c in $el.Children) { & $walk $c ($depth + 1) }
            return
        }
        [void]$out.Add($el)
    }
    & $walk $Root 0
    return $out.ToArray()
}

function Start-PageEnter {
    <#
      切页过场（design.md 5.3）：新页面的区块依次进场 ——
      淡入（ease-out, Base）+ 从下方 12px 弹到位（弹簧），每块晚 Stagger（40ms），最多错开 6 档。

      ★ 过场就是依次进场本身 ★ 不再另叠一层整页淡入：两层一起动就是「一团在动」。
      ★ 可打断 ★ 连点侧边栏：旧页面已经离开可视树，它身上的动画无所谓；
        回到一个动画没播完的页面，每块从当前透明度 / 位置接着走（Start-EnterIn 从当前值起步）。
      返回最后一块开始进场的时刻（毫秒），后面的接力动画（健康度计数）从这之后开始。
    #>
    param($Page)
    if ($null -eq $Page) { return 0 }
    $blocks = @(Get-PageBlocks $Page)
    if (-not (Test-AnimOn)) {
        foreach ($b in $blocks) { Start-EnterIn $b }
        return 0
    }
    # 先把所有块压到起点（立刻，不然新页面会先整页露一帧）……
    foreach ($b in $blocks) {
        $b.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $b.Opacity = 0
    }
    # ……等新页面排完版再开跑。
    # ★ 为什么要等 ★ 「性能优化」这种页第一次进来要建 65 行，界面线程卡约 190ms（实测）。
    #   立刻开跑的话动画时钟在卡的那段里空转，界面一恢复前几块直接蹦到终点 —— 等于没有过场。
    #   排到 Loaded 优先级（排版之后）再开，时钟从页面真正能画的那一刻起算。
    $Script:PendingEnter = $blocks
    $null = $Script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action] {
            $bl = $Script:PendingEnter
            $Script:PendingEnter = $null
            $sw = [Diagnostics.Stopwatch]::StartNew()
            if ($bl) { Start-StaggerIn $bl 12 }
            Add-PerfTick 'PageEnter' $sw.Elapsed.TotalMilliseconds
        })
    return ([math]::Min($blocks.Count, $Script:StaggerMax) * $Script:Dur.Stagger)
}

function Start-PageWarmup {
    <#
      v6.2：启动后趁空闲把没打开过的页面「预排一遍版」。
      ★ 为什么 ★ TabControl 只在第一次切到某页时才给它套模板、排版 ——
        「性能优化」页 65 行，第一次点进去界面线程要卡 230ms 左右（实测），之后再进只要 10ms。
        这笔账省不掉，但可以挪到用户没在操作的空闲时间里付：每次空闲排一页。
      ★ 用逻辑树量 ★ 页面还没挂到可视树上，但它的逻辑父级（TabItem）在，样式和资源都找得到。
    #>
    $q = New-Object System.Collections.Queue
    foreach ($ti in $Script:UI.Tabs.Items) { if ($ti -ne $Script:UI.Tabs.SelectedItem -and $ti.Content) { $q.Enqueue($ti.Content) } }
    $Script:WarmQueue = $q
    $t = New-Object System.Windows.Threading.DispatcherTimer ([System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $t.Interval = [TimeSpan]::FromMilliseconds(120)
    $t.Add_Tick({
            if ($Script:WarmQueue.Count -eq 0) { $this.Stop(); return }
            $pg = $Script:WarmQueue.Dequeue()
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                $w = [math]::Max(600, $Script:UI.Tabs.ActualWidth); $h = [math]::Max(400, $Script:UI.Tabs.ActualHeight)
                $pg.Measure((New-Object System.Windows.Size $w, $h))
                # Arrange 也要做：勾选框 / 开关首次排版时要对齐一次外观（Install-ToggleMotion 挂在 SizeChanged 上），
                # 65 个勾选框在第一次切进来时一起对齐，本身就要几十毫秒
                $pg.Arrange((New-Object System.Windows.Rect 0, 0, $w, $h))
            } catch { }
            Add-PerfTick 'Warmup(空闲时)' $sw.Elapsed.TotalMilliseconds
        })
    $t.Start()
}

function Start-ListEnter {
    <#
      页面内的内容换了（刷新列表、扫描出结果、体检右栏切换）：面板里的前 6 项依次进场，
      行程 8px（比切页的 12px 小一档 —— 这是页面内的小变化，不是换页）。
      第 7 项以后直接出现：它们多半在可视区外，错开下去只会让最后一行等半天。

      ★ 只在用户操作触发时调 ★ 启动时建表、换肤重画都不调 —— 那不是「内容刚换了」，
        而且会和切页过场撞在一起（design.md 5.3：同一时刻只有一个主角在动）。
    #>
    param($Panel)
    if ($null -eq $Panel) { return }
    $kids = @($Panel.Children | Where-Object { $_.Visibility -eq 'Visible' })
    if ($kids.Count -eq 0) { return }
    $head = @($kids | Select-Object -First $Script:StaggerMax)
    foreach ($k in $head) { $k.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $k.Opacity = 0 }
    $Script:PendingList = $head
    $null = $Script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action] {
            $l = $Script:PendingList
            $Script:PendingList = $null
            if ($l) { Start-StaggerIn $l 8 }
        })
}

function Start-FadeSlideIn {
    <#
      内容换新时的进场：淡入（ease-out）+ 从下方 8px 弹到位（弹簧）。
      用在右栏这种「点了左边、右边整块换内容」的地方 —— 它回答的是「右边刚换了」。
      连点左边几行：每次都从当前透明度 / 位置接着走，不会闪回 0 再来。
    #>
    param($Element, [double]$SlideY = 8)
    Start-EnterIn $Element 0 $SlideY
}

# =====================================================================
#  弹窗与提示
# ---------------------------------------------------------------------
#  Win32 原生的灰底方框一弹出来，界面做得再干净也露馅。
#  这里自绘一个扁平模态窗：白卡、圆角 12、左上一个语义图标、主按钮在右。
#  「做完了」这种不用点确定的，走 MDIX 的 Snackbar，3 秒自己消失。
#
#  ★ 保留原生作为兜底 ★
#    界面库没载入、窗口还没建好的时候也得能弹窗报错 ——
#    那种时刻恰恰最需要告诉用户到底出了什么事。
# =====================================================================
function Show-FlatDialog {
    <#
      Kind: Info / Success / Warning / Error / Ask / AskWarn
      Ask / AskWarn 返回 'Yes' / 'No'，其余返回 'OK'
    #>
    param([string]$Text, [string]$Title, [string]$Kind = 'Info')
    $ask = ($Kind -eq 'Ask' -or $Kind -eq 'AskWarn')
    $spec = switch ($Kind) {
        'Success' { @{ Icon = 'CheckCircleOutline'; Color = '#556B54' } }
        'Warning' { @{ Icon = 'AlertOutline'; Color = '#7A6B45' } }
        'AskWarn' { @{ Icon = 'AlertOutline'; Color = '#7A6B45' } }
        'Error'   { @{ Icon = 'CloseCircleOutline'; Color = '#8A5750' } }
        'Ask'     { @{ Icon = 'HelpCircleOutline'; Color = 'TextMid' } }
        default   { @{ Icon = 'InformationOutline'; Color = 'TextMid' } }
    }

    $w = New-Object System.Windows.Window
    $w.Title = $Title
    $w.WindowStyle = 'None'
    $w.AllowsTransparency = $true
    $w.Background = [System.Windows.Media.Brushes]::Transparent
    $w.ResizeMode = 'NoResize'
    $w.SizeToContent = 'Height'
    $w.Width = 460
    $w.ShowInTaskbar = $false
    $w.FontFamily = New-Object System.Windows.Media.FontFamily $Script:FontStack
    # 样式和色槽都挂在 Application 上，子窗口自动拿到，不用再抄一份
    if ($Script:Window -and $Script:Window.IsVisible) {
        $w.Owner = $Script:Window
        $w.WindowStartupLocation = 'CenterOwner'
    } else { $w.WindowStartupLocation = 'CenterScreen' }

    $card = New-Object System.Windows.Controls.Border
    $card.Background = Get-Brush 'Card'
    $card.BorderBrush = Get-Brush 'StrokeStrong'
    $card.BorderThickness = New-Thick 1
    $card.CornerRadius = New-Corner 12
    $card.Padding = New-Thick 24 20 24 20
    $card.Add_MouseLeftButtonDown({ try { $this.Parent.DragMove() } catch { } })

    $root = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    $ic = New-Object MaterialDesignThemes.Wpf.PackIcon
    $ic.Kind = $spec.Icon
    $ic.Width = 24; $ic.Height = 24
    $ic.Foreground = Get-Brush $spec.Color
    $ic.VerticalAlignment = 'Center'
    $head.Children.Add($ic) | Out-Null
    $tt = New-TextBlock -Text $Title -Size 16 -Bold $true
    $tt.VerticalAlignment = 'Center'
    $tt.Margin = New-Thick 12 0 0 0
    $head.Children.Add($tt) | Out-Null
    $root.Children.Add($head) | Out-Null

    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.MaxHeight = 440
    $sv.Margin = New-Thick 0 16 0 0
    $body = New-TextBlock -Text $Text -Size 13 -Color 'TextMid' -Wrap $true
    $sv.Content = $body
    $root.Children.Add($sv) | Out-Null

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.HorizontalAlignment = 'Right'
    $bar.Margin = New-Thick 0 24 0 0
    $w.Tag = 'No'
    if ($ask) {
        $bNo = New-Object System.Windows.Controls.Button
        $bNo.Content = '取消'
        $bNo.IsCancel = $true
        $bNo.Add_Click({ $win = [System.Windows.Window]::GetWindow($this); $win.Tag = 'No'; $win.Close() })
        $bar.Children.Add($bNo) | Out-Null
    }
    $bOk = New-Object System.Windows.Controls.Button
    $bOk.Content = $(if ($ask) { '确定' } else { '知道了' })
    $bOk.IsDefault = $true
    if (-not $ask) { $bOk.IsCancel = $true }
    try { $bOk.Style = $Script:Window.FindResource($(if ($Kind -eq 'AskWarn') { 'ButtonDanger' } else { 'ButtonPrimary' })) } catch { }
    $bOk.Margin = New-Thick 0
    $bOk.Add_Click({ $win = [System.Windows.Window]::GetWindow($this); $win.Tag = 'Yes'; $win.Close() })
    $bar.Children.Add($bOk) | Out-Null
    $root.Children.Add($bar) | Out-Null

    $card.Child = $root
    $w.Content = $card
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($w, 'Display')
    $w.UseLayoutRounding = $true        # 同主窗口：描边落在整像素上，高分屏不发毛
    $w.ShowDialog() | Out-Null
    if ($ask) { return "$($w.Tag)" }
    return 'OK'
}

function Show-Msg {
    <# Kind: Info / Success / Warning / Error / Ask / AskWarn。Ask 返回 'Yes'/'No'，其余返回 'OK' #>
    param([string]$Text, [string]$Title = '电脑调优助手', [string]$Kind = 'Info')
    try {
        if ($Script:MdLoaded -and $Script:Window) { return (Show-FlatDialog -Text $Text -Title $Title -Kind $Kind) }
    } catch { }
    if ($Kind -eq 'Ask' -or $Kind -eq 'AskWarn') {
        return "$([System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Question'))"
    }
    $icon = switch ($Kind) { 'Warning' { 'Warning' } 'Error' { 'Error' } default { 'Information' } }
    [System.Windows.MessageBox]::Show($Text, $Title, 'OK', $icon) | Out-Null
    return 'OK'
}

function Show-Toast {
    <#
      右下角弹一条提示（D6），Hold（2800ms）后自己淡出。
      用在「做完了」这种不需要点确定的场合 —— 每做完一件事都弹个模态框逼人点一下，很烦。

        进场  从下方 24px 弹到位（弹簧）+ 淡入（Base）
        停留  底部 2px 强调色细线匀速走完 —— 告诉人它还会待多久
        退场  淡出（Quick）+ 下沉 8px，和进场同一个方向（从哪来回哪去）
      ★ 新提示来了从当前位置接着弹 ★ 不排队、不叠罗汉：换字、重置倒计时，就地再弹一下。
      Kind 决定小圆点的语义色：Success 绿 / Warning 卡其 / Error 红 / Info 灰。
    #>
    param([string]$Text, [string]$Kind = 'Success')
    $hostB = $Script:UI.ToastHost
    if ($null -eq $hostB) { try { Set-Status $Text } catch { }; return }
    try {
        $Script:UI.ToastText.Text = $Text
        $Script:UI.ToastDot.Fill = Get-Brush $(switch ($Kind) { 'Warning' { '#7A6B45' } 'Error' { '#8A5750' } 'Info' { 'TextDim' } default { '#556B54' } })
        $yP = [System.Windows.Media.TranslateTransform]::YProperty
        $wasHidden = ($hostB.Visibility -ne 'Visible' -or $hostB.Opacity -lt 0.05)
        $hostB.Visibility = 'Visible'
        if ($wasHidden) { $Script:UI.ToastY.BeginAnimation($yP, $null); $Script:UI.ToastY.Y = 24 }
        Start-Fade $hostB 1 $Script:Dur.Base
        Start-Spring $Script:UI.ToastY $yP 0
        # 倒计时细线：每条新提示从满格重新走
        Start-Prop $Script:UI.ToastTimerScale ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 0 $Script:Dur.Hold @(0, 0, 1, 1)
        if ($Script:ToastTimer) { $Script:ToastTimer.Stop() }
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($Script:Dur.Hold)
        $t.Add_Tick({
                $this.Stop()
                Start-Fade $Script:UI.ToastHost 0 $Script:Dur.Quick
                Start-Prop $Script:UI.ToastY ([System.Windows.Media.TranslateTransform]::YProperty) $null 8 $Script:Dur.Quick $Script:Ease.Out
            })
        $Script:ToastTimer = $t
        $t.Start()
    } catch { try { Set-Status $Text } catch { } }
}

# =====================================================================
#  卡片与列表（design.md 4.4）
# =====================================================================
function New-Card {
    <#
      一张白卡：Card 底 + 1px Stroke 描边 + 圆角 12 + 内边距 20，零阴影。
      返回 @{ Card; Body }：往 Body 里加内容，把 Card 加进页面。
    #>
    param([string]$Title = '', [string]$Aside = '', [double]$Pad = 20, [string]$Icon = '')
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush 'Card'
    $b.BorderBrush = Get-Brush 'Stroke'
    $b.BorderThickness = New-Thick 1
    $b.CornerRadius = New-Corner 12
    $b.Padding = New-Thick $Pad
    $sp = New-Object System.Windows.Controls.StackPanel
    if ($Title) { $sp.Children.Add((New-RptSection -Title $Title -Aside $Aside -Icon $Icon)) | Out-Null }
    $b.Child = $sp
    return @{ Card = $b; Body = $sp }
}

function New-ListCard {
    <#
      列表里可点的一行。
      圆角 8 的行，不画分隔线：悬停浮出 CardHover，选中铺 AccentTint。
      （带圆角的行再画底边线，线会跟着圆角弯上去 —— 所以列表行不画线，靠留白分开。）
    #>
    $c = New-Object System.Windows.Controls.Border
    $c.Background = [System.Windows.Media.Brushes]::Transparent
    $c.CornerRadius = New-Corner 8
    $c.Padding = New-Thick 12 12 12 12
    $c.Cursor = 'Hand'
    Add-Interactive $c -BgNormal 'Transparent' -BgHover $Script:CARD_HOVER
    return $c
}

function Select-Card {
    <# 把某一行标成「当前选中」（AccentTint 底），上一行恢复原样 #>
    param($Card)
    if ($Script:SelectedCard) {
        try {
            $m = $Script:SelectedCard.Resources['__motion']
            $Script:SelectedCard.Background = Get-Brush $(if ($m) { $m.BgN } else { 'Transparent' })
        } catch { }
    }
    $Script:SelectedCard = $Card
    if ($Card) { $Card.Background = Get-Brush $Script:CARD_SEL_BG }
}
function Format-Reflow {
    <#
      把说明文字里「为了源码好读而手动折的行」重新接回整段，让 WPF 自己按栏宽折行。
      不能无脑全合并 —— 列表项、编号、小标题、缩进的命令行本来就该独立成行。
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $keep = '^(\s{2,}|[·•\-—>|☆✓✗⚠※]|【|\d+[\.\)、]|第[一二三四五六七八九十]|[A-Da-d][\.\)]\s)'
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
            $sep = ''
            if ($prev -match '[A-Za-z0-9)]$' -and $t -match '^[A-Za-z0-9(]') { $sep = ' ' }
            $out[$out.Count - 1] = $prev + $sep + $t.TrimStart()
        }
    }
    return ($out -join "`r`n")
}

function New-TextBlock {
    <#
      说明文字里用 **这样** 标记重点。TextBlock 不认 Markdown ——
      这里把文本按 ** 切开拼成一串 Run，奇数段加粗。
      Color 传色槽名或语义色号。
    #>
    param([string]$Text, [double]$Size = 13, [string]$Color = 'TextMain', [bool]$Bold = $false, [bool]$Wrap = $false)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontSize = $Size
    $tb.Foreground = Get-Brush $Color
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    if ($Wrap) { $tb.TextWrapping = 'Wrap'; $tb.LineHeight = [math]::Round($Size * 1.6) }

    if ($Text -and $Text.Contains('**')) {
        $isBold = $false
        foreach ($seg in ($Text -split '\*\*')) {
            if ($seg -ne '') {
                $run = New-Object System.Windows.Documents.Run $seg
                if ($isBold) { $run.FontWeight = 'SemiBold'; $run.Foreground = Get-Brush 'TextMain' }
                $tb.Inlines.Add($run)
            }
            $isBold = -not $isBold
        }
    } else {
        $tb.Text = $Text
    }
    return $tb
}

function New-Icon {
    <# 一个 MDIX 图标。Kind 是 Material Design Icons 的名字，Color 传色槽名或语义色号 #>
    param([string]$Kind, [double]$Size = 20, [string]$Color = 'TextDim')
    $ic = New-Object MaterialDesignThemes.Wpf.PackIcon
    $ic.Kind = $Kind
    $ic.Width = $Size; $ic.Height = $Size
    $ic.Foreground = Get-Brush $Color
    $ic.VerticalAlignment = 'Center'
    return $ic
}

function Get-TintBg {
    <# 按前景色给徽章配一个同色系的底（前景 / 底成对，见 design.md 1.3） #>
    param([string]$Fg)
    switch ($Fg) {
        '#556B54' { return '#E7EBE4' }   # 绿：良好 / 必做 / 低风险
        '#7A6B45' { return '#EDE7D9' }   # 卡其：需实测 / 中风险 / 可疑
        '#89694F' { return '#EDE2D6' }   # 陶：会弹黑框
        '#8A5750' { return '#EDE0DD' }   # 玫瑰红：高危 / 高风险
        default   { return 'SurfaceSunken' }   # 中性、推荐：灰底
    }
}

# =====================================================================
#  读数与表格的排版原语
# ---------------------------------------------------------------------
#  v5 的「检验报告单」语法里有用的部分留下了：
#    · 「安全范围」这一栏 —— 同一个值对不同用途，合格线本来就不一样
#    · 标记 ↑ / ↓ / ↑↑ / —：只有超出安全范围的那几行上红色，满页平静
#  换掉的是长相：卡片装表格、圆角量程条、MiSans Semibold 读数。
# =====================================================================

# 报告表的列轨。★ 这是模数，别在调用处手填宽度 ★
$Script:RptCol = @{ Result = 72; Mark = 24; Bar = 160; Ref = 80; Unit = 40 }
$Script:BarW = 160      # 量程条总宽（含右边百分比）

function New-Meter {
    <#
      一条圆角量程条（design.md 4.7）。返回 @{ Host; Fill; Line; C0; C1; L0; L1 }
      宽度跟着父容器走：填充和安全线都用星号列按比例摆，不写死像素。
    #>
    param([string]$Track = 'SurfaceSunken', [string]$FillColor = 'TextMid', [string]$LineColor = 'TextMain')
    $g = New-Object System.Windows.Controls.Grid
    $g.Height = 12
    $g.VerticalAlignment = 'Center'

    $tr = New-Object System.Windows.Controls.Border
    $tr.Height = 6
    $tr.CornerRadius = New-Corner 3
    $tr.Background = Get-Brush $Track
    $tr.VerticalAlignment = 'Center'
    $g.Children.Add($tr) | Out-Null

    $fg = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = New-Object System.Windows.GridLength 0, ([System.Windows.GridUnitType]::Star)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $fg.ColumnDefinitions.Add($c0); $fg.ColumnDefinitions.Add($c1)
    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 6
    $fill.CornerRadius = New-Corner 3
    $fill.Background = Get-Brush $FillColor
    $fill.VerticalAlignment = 'Center'
    $fg.Children.Add($fill) | Out-Null
    $g.Children.Add($fg) | Out-Null

    $lg = New-Object System.Windows.Controls.Grid
    $l0 = New-Object System.Windows.Controls.ColumnDefinition
    $l1 = New-Object System.Windows.Controls.ColumnDefinition
    $lg.ColumnDefinitions.Add($l0); $lg.ColumnDefinitions.Add($l1)
    $line = New-Object System.Windows.Shapes.Rectangle
    $line.Width = 2
    $line.Height = 12
    $line.RadiusX = 1; $line.RadiusY = 1
    $line.Fill = Get-Brush $LineColor
    $line.HorizontalAlignment = 'Right'
    $line.Visibility = 'Collapsed'
    $lg.Children.Add($line) | Out-Null
    $g.Children.Add($lg) | Out-Null

    return @{ Host = $g; Fill = $fill; Line = $line; C0 = $c0; C1 = $c1; L0 = $l0; L1 = $l1 }
}

function Set-Meter {
    <#
      刷一条量程条。Value 为 $null = 读不到，条子留空 —— 不画一个假的长度。
      Mark = 安全线位置（$null 不画：没有阈值的项画了就等于承诺了一个不存在的标准）。
    #>
    param($M, $Value, [double]$Max = 100, $Mark = $null, [string]$FillColor = 'TextMid')
    if ($null -eq $M) { return }
    if ($Max -le 0) { $Max = 100 }
    $star = [System.Windows.GridUnitType]::Star
    if ($null -eq $Value) {
        $M.C0.Width = New-Object System.Windows.GridLength 0, $star
        $M.C1.Width = New-Object System.Windows.GridLength 1, $star
        $M.Fill.Visibility = 'Collapsed'
    } else {
        $v = [math]::Max(0, [math]::Min([double]$Value, $Max))
        $M.C0.Width = New-Object System.Windows.GridLength $v, $star
        $M.C1.Width = New-Object System.Windows.GridLength ($Max - $v), $star
        $M.Fill.Visibility = $(if ($v -gt 0) { 'Visible' } else { 'Collapsed' })
        $M.Fill.Background = Get-Brush $FillColor
    }
    if ($null -eq $Mark) {
        $M.Line.Visibility = 'Collapsed'
    } else {
        $mk = [math]::Max(0, [math]::Min([double]$Mark, $Max))
        $M.L0.Width = New-Object System.Windows.GridLength ([math]::Max($mk, 0.001)), $star
        $M.L1.Width = New-Object System.Windows.GridLength ([math]::Max($Max - $mk, 0.001)), $star
        $M.Line.Visibility = 'Visible'
    }
}

function New-RangeBar {
    <#
      表格行里的量程条 + 右边百分比。返回 @{ Host; Meter; Pct }
      越线时整条换高危红 —— 不是只红超出的那一段，那要读者去比两段颜色的长度。
    #>
    $g = New-Object System.Windows.Controls.Grid
    $g.Width = $Script:BarW
    $g.HorizontalAlignment = 'Left'
    $g.VerticalAlignment = 'Center'
    $cA = New-Object System.Windows.Controls.ColumnDefinition
    $cA.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $cB = New-Object System.Windows.Controls.ColumnDefinition
    $cB.Width = New-Object System.Windows.GridLength 44
    $g.ColumnDefinitions.Add($cA); $g.ColumnDefinitions.Add($cB)

    $m = New-Meter
    $g.Children.Add($m.Host) | Out-Null

    # 百分比。★ 表格数位 ★ 每秒刷新时不加这句整列会左右抖
    $pct = New-TextBlock -Text '' -Size 12 -Color 'TextDim'
    $pct.HorizontalAlignment = 'Right'
    $pct.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($pct, 'Tabular')
    [System.Windows.Controls.Grid]::SetColumn($pct, 1)
    $g.Children.Add($pct) | Out-Null

    return @{ Host = $g; Meter = $m; Pct = $pct }
}

function Set-RangeBar {
    <#
      刷一条量程条。
        Value  当前值（$null = 读不到，条子留空、百分比写「—」）
        Max    满量程
        Lo/Hi  安全线。Lo = 低于它就不合格（刷新率、剩余空间）；Hi = 高于它就不合格（温度、占用率）
        Abnormal 越线了 —— 整条换高危红
    #>
    param($Bar, $Value, [double]$Max = 100, $Lo = $null, $Hi = $null, [bool]$Abnormal = $false)
    if ($null -eq $Bar) { return }
    if ($Max -le 0) { $Max = 100 }
    $mark = if ($null -ne $Hi) { [double]$Hi } elseif ($null -ne $Lo) { [double]$Lo } else { $null }
    Set-Meter $Bar.Meter $Value $Max $mark $(if ($Abnormal) { '#8A5750' } else { 'TextMid' })
    if ($null -eq $Value) {
        $Bar.Pct.Text = '—'
        $Bar.Pct.Foreground = Get-Brush 'TextDim'
        return
    }
    $v = [math]::Max(0, [math]::Min([double]$Value, $Max))
    $Bar.Pct.Text = ('{0}%' -f [math]::Round(100 * $v / $Max))
    $Bar.Pct.Foreground = Get-Brush $(if ($Abnormal) { '#8A5750' } else { 'TextDim' })
    $Bar.Pct.FontWeight = $(if ($Abnormal) { 'SemiBold' } else { 'Normal' })
}

# =====================================================================
#  读数卡（概览页，design.md 4.7）
# ---------------------------------------------------------------------
#  v5 的半圆指针仪表换成扁平读数卡：图标 + 标签 / 大数字 + 小单位 / 量程条 / 附注。
#  函数名保留 New-Gauge / Set-Gauge，调用处不用改。
# =====================================================================
function New-Gauge {
    <# 返回 @{ Host; Value; Unit; Mark; Label; Sub; Meter } —— Host 就是往卡片里放的那一块 #>
    param([string]$Label, [string]$Icon = 'Gauge')
    $sp = New-Object System.Windows.Controls.StackPanel

    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    $head.Children.Add((New-Icon -Kind $Icon -Size 20 -Color 'TextDim')) | Out-Null
    $lb = New-TextBlock -Text $Label -Size 12 -Color 'TextDim'
    $lb.VerticalAlignment = 'Center'
    $lb.Margin = New-Thick 8 0 0 0
    $head.Children.Add($lb) | Out-Null
    $sp.Children.Add($head) | Out-Null

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Thick 0 12 0 0
    $val = New-TextBlock -Text ([string][char]0x2014) -Size 28 -Bold $true
    [System.Windows.Documents.Typography]::SetNumeralAlignment($val, 'Tabular')
    $row.Children.Add($val) | Out-Null
    $unit = New-TextBlock -Text '' -Size 11 -Color 'TextDim'
    $unit.VerticalAlignment = 'Bottom'
    $unit.Margin = New-Thick 4 0 0 6
    $row.Children.Add($unit) | Out-Null
    $mk = New-TextBlock -Text '' -Size 14 -Color '#8A5750' -Bold $true
    $mk.VerticalAlignment = 'Bottom'
    $mk.Margin = New-Thick 8 0 0 5
    $row.Children.Add($mk) | Out-Null
    $sp.Children.Add($row) | Out-Null

    $m = New-Meter
    $m.Host.Margin = New-Thick 0 12 0 0
    $sp.Children.Add($m.Host) | Out-Null

    $sub = New-TextBlock -Text '' -Size 12 -Color 'TextDim' -Wrap $true
    $sub.Margin = New-Thick 0 8 0 0
    $sp.Children.Add($sub) | Out-Null

    return @{ Host = $sp; Value = $val; Unit = $unit; Mark = $mk; Label = $lb; Sub = $sub; Meter = $m }
}

function Set-Gauge {
    <#
      刷一张读数卡。
        Value  当前值（$null = 读不到：数字写「—」、量程条不填 —— 绝不编数字）
        Max    满量程
        Lo/Hi  合格区间
    #>
    param($G, $Value, [double]$Max = 100, $Lo = $null, $Hi = $null,
        [int]$Decimals = 0, [string]$Unit = '', [string]$Sub = '')
    if ($null -eq $G) { return }
    if ($Max -le 0) { $Max = 100 }
    # v6.2：和上一秒一模一样就不动 —— 温度、内存大多数秒是不变的，没必要重画、重跑数字滚动
    $sig = "$Value|$Max|$Unit|$Sub"
    if ($G.Last -eq $sig) { return }
    $G.Last = $sig
    $G.Unit.Text = $Unit
    $G.Sub.Text = $Sub
    $mark = if ($null -ne $Hi) { [double]$Hi } elseif ($null -ne $Lo) { [double]$Lo } else { $null }

    if ($null -eq $Value) {
        $G.Value.Text = [string][char]0x2014
        $G.Value.Foreground = Get-Brush 'TextDim'
        $G.Unit.Text = ''          # 「— °C」读起来像「有个读数只是没写」，破折号后面不挂单位
        $G.Mark.Text = ''
        Set-Meter $G.Meter $null $Max $mark
        return
    }

    $bad = $false
    if ($null -ne $Hi -and [double]$Value -gt [double]$Hi) { $bad = $true }
    if ($null -ne $Lo -and [double]$Value -lt [double]$Lo) { $bad = $true }
    $ink = if ($bad) { '#8A5750' } else { 'TextMain' }
    $G.Value.Foreground = Get-Brush $ink
    $G.Mark.Text = $(if ($bad) { $(if ($null -ne $Hi) { [string][char]0x2191 } else { [string][char]0x2193 }) } else { '' })
    Set-Meter $G.Meter ([double]$Value) $Max $mark $(if ($bad) { '#8A5750' } else { 'TextMid' })

    $old = "$($G.Value.Text)" -replace '[^\d.\-]', ''
    $changed = $true
    if ($old -and [double]::TryParse($old, [ref]$null)) {
        $changed = ([math]::Round([double]$old, $Decimals) -ne [math]::Round([double]$Value, $Decimals))
    }
    Start-CountUp -Target $G.Value -To ([double]$Value) -Decimals $Decimals -Ms $Script:Dur.Draw
    if ($changed) { Start-ValueFlash $G.Value }
}

function New-RptGrid {
    <# 造一个符合列轨的 Grid：项目(*) 结果 标记 量程 参考范围 单位 #>
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in @(0, $Script:RptCol.Result, $Script:RptCol.Mark, $Script:RptCol.Bar, $Script:RptCol.Ref, $Script:RptCol.Unit)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq 0) {
            New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        } else {
            New-Object System.Windows.GridLength ([double]$w)
        }
        $g.ColumnDefinitions.Add($cd)
    }
    return $g
}

function Add-RptAct {
    <# 往一行的处置位里塞一个控件，顺手把处置位显形 #>
    param($Row, $Control)
    if ($null -eq $Row -or $null -eq $Control) { return }
    if ($Control -is [System.Windows.Controls.Control]) { $Control.Margin = New-Thick 0 0 8 8 }
    $Row.Act.Children.Add($Control) | Out-Null
    $Row.Act.Visibility = 'Visible'
}

function New-ActRow {
    <#
      一行处置项：左边名字 + 一行小字说明，右边动作。返回 @{ Row; Slot; Note; Name }
      放在卡片里，行与行之间一条 Stroke 细线（最后一行由 Close-CardRows 收掉）。
    #>
    param([string]$Name, [string]$Note = '')
    $wrap = New-Object System.Windows.Controls.Border
    $wrap.Padding = New-Thick 0 12 0 12
    $wrap.BorderBrush = Get-Brush 'Stroke'
    $wrap.BorderThickness = New-Thick 0 0 0 1

    $g = New-Object System.Windows.Controls.Grid
    $cd0 = New-Object System.Windows.Controls.ColumnDefinition
    $cd0.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions.Add($cd0)
    $cd1 = New-Object System.Windows.Controls.ColumnDefinition
    $cd1.Width = New-Object System.Windows.GridLength -1, ([System.Windows.GridUnitType]::Auto)
    $g.ColumnDefinitions.Add($cd1)

    $left = New-Object System.Windows.Controls.StackPanel
    $left.VerticalAlignment = 'Center'
    $nm = New-TextBlock -Text $Name -Size 14 -Bold $true -Wrap $true
    $left.Children.Add($nm) | Out-Null
    $nt = New-TextBlock -Text $Note -Size 12 -Color 'TextDim' -Wrap $true
    $nt.Margin = New-Thick 0 4 0 0
    if (-not $Note) { $nt.Visibility = 'Collapsed' }
    $left.Children.Add($nt) | Out-Null
    $g.Children.Add($left) | Out-Null

    $slot = New-Object System.Windows.Controls.StackPanel
    $slot.Orientation = 'Horizontal'
    $slot.VerticalAlignment = 'Center'
    $slot.Margin = New-Thick 24 0 0 0
    [System.Windows.Controls.Grid]::SetColumn($slot, 1)
    $g.Children.Add($slot) | Out-Null

    $wrap.Child = $g
    return @{ Row = $wrap; Slot = $slot; Note = $nt; Name = $nm }
}

function Close-CardRows {
    <# 卡片里最后一行不画底线 —— 卡片自己的描边就是边界，两条线叠在一起显脏 #>
    param($Panel)
    if ($null -eq $Panel -or $Panel.Children.Count -eq 0) { return }
    $last = $Panel.Children[$Panel.Children.Count - 1]
    if ($last -is [System.Windows.Controls.Border] -and $last.BorderThickness.Bottom -eq 1 -and $last.BorderThickness.Top -eq 0) {
        $last.BorderThickness = New-Thick 0
    }
}

function New-RptHeader {
    <# 表头行：项目 / 结果 / 占了多少 / 安全范围 / 单位，下面一条 StrokeMed 线。Bar 是量程那一列的列名 #>
    param([string]$First = '项目', [string]$Bar = '占了多少')
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 0 4 0 0

    $g = New-RptGrid
    $g.Margin = New-Thick 0 0 0 8
    $cells = @(
        @{ T = $First; Col = 0; Align = 'Left' },
        @{ T = '结果'; Col = 1; Align = 'Right' },
        @{ T = $Bar; Col = 3; Align = 'Left' },
        @{ T = '安全范围'; Col = 4; Align = 'Right' },
        @{ T = '单位'; Col = 5; Align = 'Right' })
    foreach ($c in $cells) {
        $t = New-TextBlock -Text $c.T -Size 11 -Color 'TextDim'
        $t.HorizontalAlignment = $c.Align
        [System.Windows.Controls.Grid]::SetColumn($t, $c.Col)
        $g.Children.Add($t) | Out-Null
    }
    $sp.Children.Add($g) | Out-Null

    $rule = New-Object System.Windows.Shapes.Rectangle
    $rule.Height = 1
    $rule.Fill = Get-Brush 'StrokeMed'
    $sp.Children.Add($rule) | Out-Null
    return $sp
}

function New-RptRow {
    <#
      一行读数。返回 @{ Row; Name; Result; Mark; Ref; Unit; Note; Bar; Act }
      Mark：'' / '*' / '↑' / '↓' / '↑↑' / '—'。只有 ↑ ↓ ↑↑ 上高危红并加粗；其余一律安静。
    #>
    param(
        [string]$Name = '', [string]$Result = '', [string]$Mark = '', [string]$Ref = '',
        [string]$Unit = '', [string]$Note = '', [bool]$Zebra = $false, [bool]$NoBar = $false
    )
    $wrap = New-Object System.Windows.Controls.Border
    $wrap.Padding = New-Thick 0 12 0 12
    $wrap.BorderBrush = Get-Brush 'Stroke'
    $wrap.BorderThickness = New-Thick 0 0 0 1
    if ($Zebra) { $wrap.Background = Get-Brush 'SurfaceAlt' }

    $outer = New-Object System.Windows.Controls.StackPanel
    $g = New-RptGrid

    $nm = New-TextBlock -Text $Name -Size 14 -Wrap $true
    $nm.VerticalAlignment = 'Center'
    $g.Children.Add($nm) | Out-Null

    # 结果：MiSans Semibold + 表格数位，右对齐
    $rs = New-TextBlock -Text $Result -Size 16 -Bold $true
    $rs.HorizontalAlignment = 'Right'
    $rs.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($rs, 'Tabular')
    [System.Windows.Controls.Grid]::SetColumn($rs, 1)
    $g.Children.Add($rs) | Out-Null

    $mk = New-TextBlock -Text $Mark -Size 14 -Color 'TextDim'
    $mk.HorizontalAlignment = 'Center'
    $mk.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($mk, 2)
    $g.Children.Add($mk) | Out-Null

    $bar = New-RangeBar
    $bar.Host.Margin = New-Thick 16 0 0 0
    $bar.Host.Width = $Script:BarW - 16
    # 没有量程可言的项不画空槽 —— 画一条永远空着的量程，等于承诺了一个不存在的测量
    if ($NoBar) { $bar.Host.Visibility = 'Collapsed' }
    [System.Windows.Controls.Grid]::SetColumn($bar.Host, 3)
    $g.Children.Add($bar.Host) | Out-Null

    $rf = New-TextBlock -Text $Ref -Size 12 -Color 'TextDim'
    $rf.HorizontalAlignment = 'Right'
    $rf.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($rf, 'Tabular')
    [System.Windows.Controls.Grid]::SetColumn($rf, 4)
    $g.Children.Add($rf) | Out-Null

    $un = New-TextBlock -Text $Unit -Size 11 -Color 'TextDim'
    $un.HorizontalAlignment = 'Right'
    $un.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($un, 5)
    $g.Children.Add($un) | Out-Null

    $outer.Children.Add($g) | Out-Null

    $nt = New-TextBlock -Text $Note -Size 12 -Color 'TextDim' -Wrap $true
    $nt.Margin = New-Thick 0 4 0 0
    if (-not $Note) { $nt.Visibility = 'Collapsed' }
    $outer.Children.Add($nt) | Out-Null

    # 处置位：能对这一项做的操作排在它的附注下面。
    # ★ WrapPanel ★ 刷新率那一行有八个档位按钮，横排会顶出行宽。
    $act = New-Object System.Windows.Controls.WrapPanel
    $act.Margin = New-Thick 0 12 0 0
    $act.Visibility = 'Collapsed'
    $outer.Children.Add($act) | Out-Null

    $wrap.Child = $outer
    $r = @{ Row = $wrap; Name = $nm; Result = $rs; Mark = $mk; Ref = $rf; Unit = $un; Note = $nt; Bar = $bar; Act = $act }
    Set-RptMark $r $Mark
    return $r
}

function Set-RptMark {
    <# 设置一行的标记，并按标记决定结果值的颜色。正常值不标色 —— 满页平静，只有真出问题的那几行跳出来。 #>
    param($Row, [string]$Mark)
    if ($null -eq $Row) { return }
    $Row.Mark.Text = $Mark
    $abnormal = ($Mark -eq '↑' -or $Mark -eq '↓' -or $Mark -eq '↑↑' -or $Mark -eq '↓↓')
    if ($abnormal) {
        $Row.Result.Foreground = Get-Brush '#8A5750'
        $Row.Mark.Foreground = Get-Brush '#8A5750'
        $Row.Mark.FontWeight = 'SemiBold'
    } else {
        $Row.Result.Foreground = Get-Brush 'TextMain'
        $Row.Mark.Foreground = Get-Brush 'TextDim'
        $Row.Mark.FontWeight = 'Normal'
    }
}

function New-RptSection {
    <# 卡片标题：section 16 Semibold（可带一个图标）+ 右边一行灰字 #>
    param([string]$Title, [string]$Aside = '', [string]$Icon = '')
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = New-Thick 0 0 0 12
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = 'Horizontal'
    if ($Icon) {
        $ic = New-Icon -Kind $Icon -Size 20 -Color 'TextDim'
        $ic.Margin = New-Thick 0 0 8 0
        $left.Children.Add($ic) | Out-Null
    }
    $t = New-TextBlock -Text $Title -Size 16 -Bold $true
    $t.VerticalAlignment = 'Center'
    $left.Children.Add($t) | Out-Null
    $row.Children.Add($left) | Out-Null
    if ($Aside) {
        $a = New-TextBlock -Text $Aside -Size 12 -Color 'TextDim'
        $a.HorizontalAlignment = 'Right'
        $a.VerticalAlignment = 'Center'
        $row.Children.Add($a) | Out-Null
    }
    return $row
}

function Add-ColHeader {
    <#
      在列表容器顶部插一行列名 + 一条 StrokeMed 线。
      ★ 宽度必须和行里的列轨完全一致 ★ 否则列名对不上下面的数。
      Indent 是第一列文字的左缩进（列表行有 12 的内边距 + 勾选框）。
    #>
    param($Panel, [string]$First = '检验项目', $Cols = @(), [double]$Indent = 38)
    if ($null -eq $Panel) { return }

    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Thick 0 0 0 8

    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Thick 0 4 12 8
    $cd0 = New-Object System.Windows.Controls.ColumnDefinition
    $cd0.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions.Add($cd0)
    foreach ($c in $Cols) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength ([double]$c.W)
        $g.ColumnDefinitions.Add($cd)
    }

    $t0 = New-TextBlock -Text $First -Size 11 -Color 'TextDim'
    $t0.Margin = New-Thick $Indent 0 0 0
    $g.Children.Add($t0) | Out-Null

    $i = 1
    foreach ($c in $Cols) {
        $t = New-TextBlock -Text $c.T -Size 11 -Color 'TextDim'
        $t.TextAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetColumn($t, $i)
        $g.Children.Add($t) | Out-Null
        $i++
    }
    $wrap.Children.Add($g) | Out-Null

    $rule = New-Object System.Windows.Shapes.Rectangle
    $rule.Height = 1
    $rule.Fill = Get-Brush 'StrokeMed'
    $wrap.Children.Add($rule) | Out-Null

    $Panel.Children.Add($wrap) | Out-Null
}

function New-Badge {
    <#
      一个小徽章（design.md 4.9）：label 11 字号、圆角 6、语义前景 + 语义底成对。
      中性的（分类名、大小）用 TextDim 压 SurfaceSunken。
    #>
    param([string]$Text, [string]$Fg, [string]$Bg)
    $isSemantic = $Fg -in @('#556B54', '#7A6B45', '#8A5750', '#89694F')
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = New-Corner 6
    $b.Padding = New-Thick 8 2 8 2
    $b.Margin = New-Thick 0 0 8 4
    $b.VerticalAlignment = 'Center'
    $b.Background = Get-Brush $(if ($isSemantic) { Get-TintBg $Fg } else { 'SurfaceSunken' })
    $tb = New-TextBlock -Text $Text -Size 11 -Color $(if ($isSemantic) { $Fg } else { 'TextMid' })
    $b.Child = $tb
    return $b
}
# 风险等级 -> 颜色
function Get-RiskColors {
    param([string]$Risk)
    switch ($Risk) {
        '低' { return @{ Fg = '#556B54'; Bg = '#E7EBE4' } }
        '中' { return @{ Fg = '#7A6B45'; Bg = '#EDE7D9' } }
        '高' { return @{ Fg = '#8A5750'; Bg = '#EDE0DD' } }
        default { return @{ Fg = 'TextDim'; Bg = 'SurfaceSunken' } }
    }
}

# ---------------------------------------------------------------------
#  4. 界面布局（XAML）
# ---------------------------------------------------------------------
#  两份 XAML：
#    ① 全局样式字典 —— MDIX 主题 + 我们把它压扁平的那几个样式。挂在 Application 上，
#       主窗口和所有弹窗都拿得到
#    ② 主窗口 —— 侧边栏 + 顶栏 + 页面容器 + 状态栏
#
#  ★ MDIX 的主题字典写在 XAML 里，由 XAML 解析器去设 Source ★
#    在 PowerShell 里写 $rd.Source = … 会被当成往字典里塞一个叫 Source 的键，
#    样式静默不生效（v4 时以为是 HandyControl 的 bug，其实就是这个）。
# ---------------------------------------------------------------------
$appStylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                    xmlns:md="http://materialdesigninxaml.net/winfx/xaml/themes">
  <ResourceDictionary.MergedDictionaries>
    <!-- 主色 = Accent #5B5FD6。深浅由 Set-AppTheme 调 set_BaseTheme 切 -->
    <md:CustomColorTheme BaseTheme="Light" PrimaryColor="#5B5FD6" SecondaryColor="#5B5FD6"/>
    <!-- 选 MaterialDesign3 而不是 2：M3 的按钮默认不转大写、圆角更大、控件更轻，
         离「扁平、干净」更近；2 的按钮是 Material 早期那种浮起来的方块。 -->
    <ResourceDictionary Source="pack://application:,,,/MaterialDesignThemes.Wpf;component/Themes/MaterialDesign3.Defaults.xaml"/>
  </ResourceDictionary.MergedDictionaries>

  <!-- 色槽默认值（浅色）。运行时由 Set-AppTheme 整体替换，见 design.md 1.1 -->
  <SolidColorBrush x:Key="Canvas" Color="#F4F5FA"/>
  <SolidColorBrush x:Key="Sidebar" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="Card" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="CardHover" Color="#F7F8FC"/>
  <SolidColorBrush x:Key="SurfaceAlt" Color="#F7F8FC"/>
  <SolidColorBrush x:Key="SurfaceSunken" Color="#EEF0F6"/>
  <SolidColorBrush x:Key="Stroke" Color="#ECEEF4"/>
  <SolidColorBrush x:Key="StrokeMed" Color="#E2E5EE"/>
  <SolidColorBrush x:Key="StrokeStrong" Color="#C9CDE0"/>
  <SolidColorBrush x:Key="TextMain" Color="#1E2046"/>
  <SolidColorBrush x:Key="TextMid" Color="#4A4E6D"/>
  <SolidColorBrush x:Key="TextDim" Color="#666A88"/>
  <SolidColorBrush x:Key="Accent" Color="#5B5FD6"/>
  <SolidColorBrush x:Key="AccentHover" Color="#7478E0"/>
  <SolidColorBrush x:Key="AccentPressed" Color="#4B53B8"/>
  <SolidColorBrush x:Key="AccentTint" Color="#EEEFFC"/>
  <SolidColorBrush x:Key="OnAccent" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="HeroFill" Color="#4B53B8"/>
  <SolidColorBrush x:Key="OnHero" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="OnHeroDim" Color="#D4D6F7"/>
  <SolidColorBrush x:Key="OnHeroTrack" Color="#6B72C9"/>
  <SolidColorBrush x:Key="SemBad" Color="#8A5750"/>
  <SolidColorBrush x:Key="SemBadBg" Color="#EDE0DD"/>
  <SolidColorBrush x:Key="OnSemBad" Color="#FFFFFF"/>

  <!-- 键盘焦点：1px 实线框，不是系统的黑点线（键盘操作的人全靠它） -->
  <Style x:Key="AppFocusVisual">
    <Setter Property="Control.Template">
      <Setter.Value>
        <ControlTemplate>
          <Rectangle Margin="-2" StrokeThickness="1" RadiusX="8" RadiusY="8" SnapsToDevicePixels="True"
                     Stroke="{DynamicResource StrokeStrong}"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ================================================================
       按钮（design.md 4.3）—— 把 MDIX 的按钮压扁平：
         · ElevationAssist = Dp0：没有 Material 那种浮起来的阴影
         · 圆角 8、高 36、字号 12
         · 水波纹留着，颜色在 Set-AppTheme 里压淡
       ================================================================ -->
  <!-- 次按钮 = 默认按钮：白底 + 1px 边 -->
  <Style TargetType="Button" BasedOn="{StaticResource MaterialDesignOutlinedButton}">
    <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
    <Setter Property="Background" Value="{DynamicResource Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrokeMed}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Height" Value="36"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="Normal"/>
    <Setter Property="Margin" Value="0,0,8,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
    <Setter Property="md:ButtonAssist.CornerRadius" Value="8"/>
    <Setter Property="md:ElevationAssist.Elevation" Value="Dp0"/>
    <Setter Property="md:RippleAssist.Feedback" Value="{DynamicResource Accent}"/>
    <Setter Property="md:RippleAssist.RippleSizeMultiplier" Value="1"/>
  </Style>

  <!-- 主按钮：强调色实底。一屏只许一个 -->
  <Style x:Key="ButtonPrimary" TargetType="Button" BasedOn="{StaticResource MaterialDesignRaisedButton}">
    <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Height" Value="36"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,0,8,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
    <Setter Property="md:ButtonAssist.CornerRadius" Value="8"/>
    <Setter Property="md:ElevationAssist.Elevation" Value="Dp0"/>
    <Setter Property="md:RippleAssist.Feedback" Value="#FFFFFF"/>
  </Style>

  <!-- 危险按钮：高危红实底（语义色，换肤只换明暗） -->
  <Style x:Key="ButtonDanger" TargetType="Button" BasedOn="{StaticResource ButtonPrimary}">
    <Setter Property="Background" Value="{DynamicResource SemBad}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource SemBad}"/>
    <Setter Property="Foreground" Value="{DynamicResource OnSemBad}"/>
  </Style>

  <!-- 图标按钮：顶栏的换肤切换 -->
  <Style x:Key="ButtonIcon" TargetType="Button" BasedOn="{StaticResource MaterialDesignIconButton}">
    <Setter Property="Foreground" Value="{DynamicResource TextMid}"/>
    <Setter Property="Width" Value="36"/>
    <Setter Property="Height" Value="36"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="md:RippleAssist.Feedback" Value="{DynamicResource Accent}"/>
  </Style>

  <!-- ================================================================
       勾选框（D2 画勾）：方框 18、圆角 5；勾上时底色淡入、方框从 0.85 弹回 1、对勾一笔画出。
       动画在 Modules\Motion.ps1 的 Install-ToggleMotion 里（类级注册 Checked / Unchecked），
       模板只管长相。对勾路径长 13px、描边 2.2 → 虚线单位 6（StrokeDashArray 按线宽计）。
       ================================================================ -->
  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid x:Name="BoxHost" Width="18" Height="18" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                  RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform>
                <ScaleTransform x:Name="BoxScale" ScaleX="1" ScaleY="1"/>
              </Grid.RenderTransform>
              <Border x:Name="Box" CornerRadius="5" BorderThickness="1.5" BorderBrush="{DynamicResource StrokeStrong}" Background="{DynamicResource Card}"/>
              <Border x:Name="Fill" CornerRadius="5" Background="{DynamicResource Accent}" Opacity="0"/>
              <Path x:Name="Tick" Data="M 4.5,9.2 L 7.6,12.2 L 13.5,5.8" Stroke="{DynamicResource OnAccent}" StrokeThickness="2.2"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" StrokeDashCap="Flat"
                    StrokeDashArray="6 6" StrokeDashOffset="6"/>
            </Grid>
            <ContentPresenter x:Name="Cp" Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                              RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource TextDim}"/>
            </Trigger>
            <Trigger Property="Content" Value="{x:Null}">
              <Setter TargetName="Cp" Property="Margin" Value="0"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.45"/>
              <Setter Property="Cursor" Value="Arrow"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- ================================================================
       开关（D1 弹簧开关）：只给「设置」性质的开关用（开 / 关一件事），
       选东西的列表（优化项、清理项、自带软件）仍然是勾选框。
       轨道 36×20；圆点 14，弹簧滑过去；按住时圆点拉长 4px。动画同样在 Install-ToggleMotion。
       ================================================================ -->
  <Style x:Key="SwitchBox" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid Width="36" Height="20" VerticalAlignment="{TemplateBinding VerticalContentAlignment}">
              <Border x:Name="Track" CornerRadius="10" Background="{DynamicResource StrokeStrong}"/>
              <Border x:Name="TrackOn" CornerRadius="10" Background="{DynamicResource Accent}" Opacity="0"/>
              <Border x:Name="Knob" Width="14" Height="14" CornerRadius="7" Background="#FFFFFF"
                      HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,0,0">
                <Border.RenderTransform>
                  <TranslateTransform x:Name="KnobX" X="0"/>
                </Border.RenderTransform>
              </Border>
            </Grid>
            <ContentPresenter x:Name="Cp" Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                              RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="Content" Value="{x:Null}">
              <Setter TargetName="Cp" Property="Margin" Value="0"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.45"/>
              <Setter Property="Cursor" Value="Arrow"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 搜索框：描边输入框，前置放大镜，占位字不浮动（design.md 4.10） -->
  <Style x:Key="SearchBox" TargetType="TextBox" BasedOn="{StaticResource MaterialDesignOutlinedTextBox}">
    <Setter Property="Height" Value="36"/>
    <Setter Property="Padding" Value="8,0,8,0"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Background" Value="{DynamicResource Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource TextMain}"/>
    <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="md:HintAssist.IsFloating" Value="False"/>
    <Setter Property="md:HintAssist.Foreground" Value="{DynamicResource Accent}"/>
    <Setter Property="md:TextFieldAssist.TextFieldCornerRadius" Value="8"/>
    <Setter Property="md:TextFieldAssist.HasLeadingIcon" Value="True"/>
    <Setter Property="md:TextFieldAssist.LeadingIcon" Value="Magnify"/>
    <Setter Property="md:TextFieldAssist.LeadingIconSize" Value="18"/>
    <Setter Property="md:TextFieldAssist.HasClearButton" Value="True"/>
  </Style>


  <!-- ================================================================
       滚动条（design.md 4.10）：8px 细条、圆角、没有上下箭头。
       系统默认那种带箭头的粗灰条，一出现整页就不像同一套东西了。
       ================================================================ -->
  <Style x:Key="ThinThumb" TargetType="Thumb">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="T" CornerRadius="4" Background="{DynamicResource StrokeStrong}"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="T" Property="Background" Value="{DynamicResource TextDim}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="T" Property="Background" Value="{DynamicResource TextMid}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="ThinPage" TargetType="RepeatButton">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
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
  <Style TargetType="ScrollBar">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="8"/>
    <Setter Property="MinWidth" Value="8"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton>
                <RepeatButton Style="{StaticResource ThinPage}" Command="ScrollBar.PageUpCommand"/>
              </Track.DecreaseRepeatButton>
              <Track.Thumb>
                <Thumb Style="{StaticResource ThinThumb}" Margin="1,2"/>
              </Track.Thumb>
              <Track.IncreaseRepeatButton>
                <RepeatButton Style="{StaticResource ThinPage}" Command="ScrollBar.PageDownCommand"/>
              </Track.IncreaseRepeatButton>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="8"/>
        <Setter Property="MinHeight" Value="8"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Grid Background="Transparent">
                <Track x:Name="PART_Track" IsDirectionReversed="False">
                  <Track.DecreaseRepeatButton>
                    <RepeatButton Style="{StaticResource ThinPage}" Command="ScrollBar.PageLeftCommand"/>
                  </Track.DecreaseRepeatButton>
                  <Track.Thumb>
                    <Thumb Style="{StaticResource ThinThumb}" Margin="2,1"/>
                  </Track.Thumb>
                  <Track.IncreaseRepeatButton>
                    <RepeatButton Style="{StaticResource ThinPage}" Command="ScrollBar.PageRightCommand"/>
                  </Track.IncreaseRepeatButton>
                </Track>
              </Grid>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>

  <!-- 卡片：Card 底 + 1px Stroke + 圆角 12 + 内边距 20，零阴影（design.md 4.4） -->
  <Style x:Key="CardBorder" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Stroke}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Padding" Value="20"/>
  </Style>
  <!-- 列表卡：内边距 8，里面的行自己带 12 的内边距 -->
  <Style x:Key="ListCardBorder" TargetType="Border" BasedOn="{StaticResource CardBorder}">
    <Setter Property="Padding" Value="8"/>
  </Style>

  <Style x:Key="Hint" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{DynamicResource TextDim}"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="LineHeight" Value="20"/>
  </Style>

  <!-- ================================================================
       页面容器：TabControl 收起页签条，只留内容区
       页签条的活交给左侧边栏；TabControl 留着是因为全程序几十处代码
       靠它的 SelectedIndex / SelectedItem 判断当前在哪一页，出图模式也靠它按页拍。

       切页过场不在模板里：由 SelectionChanged 调 Start-PageEnter，
       让新页面的区块依次进场（design.md 5.3 的编排）。
       v6.0 用的 MDIX TransitioningContent 拆掉了 —— 它要反射调 protected 方法才能重播，
       而且只能整页一起淡入，编排不了「依次进场」。
       ================================================================ -->
  <Style x:Key="PageHost" TargetType="TabControl">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TabControl">
          <Grid>
            <TabPanel x:Name="HeaderPanel" IsItemsHost="True" Visibility="Collapsed"/>
            <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent"/>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

$Script:AppStyles = $null
if ($Script:MdLoaded) {
    try {
        $Script:AppStyles = [Windows.Markup.XamlReader]::Parse($appStylesXaml)
        [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($Script:AppStyles)
        # 换深浅时要调它的 set_BaseTheme
        $Script:MdTheme = $Script:AppStyles.MergedDictionaries[0]
    } catch { $Script:MdLoadError = "界面样式加载失败：$($_.Exception.Message)" }
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:md="http://materialdesigninxaml.net/winfx/xaml/themes"
        Title="电脑调优助手" Height="820" Width="1280" MinHeight="640" MinWidth="1080"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Canvas}" Foreground="{DynamicResource TextMain}"
        FontSize="13" TextElement.Foreground="{DynamicResource TextMain}"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        UseLayoutRounding="True">
  <!-- v6.2 UseLayoutRounding：所有尺寸和位置按「设备像素」取整。不开的话 125% / 150% 下一条 1px 描边
       会落在半个像素上，被抗锯齿糊成两像素宽的灰线，圆角卡片边缘发毛 —— 朋友说的「毛边」之一 -->
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextMain}"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="232"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ================================================================
         侧边栏（design.md 4.5）：白底、右侧一条淡描边
         导航项由 Build-NavUI 按分组画出来
         ================================================================ -->
    <Border Grid.Column="0" x:Name="SidebarBox" Background="{DynamicResource Sidebar}"
            BorderBrush="{DynamicResource Stroke}" BorderThickness="0,0,1,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="24,24,16,8">
          <Border Width="36" Height="36" CornerRadius="8" Background="{DynamicResource Accent}">
            <md:PackIcon Kind="SpeedometerMedium" Width="22" Height="22" Foreground="{DynamicResource OnAccent}"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="电脑调优助手" FontSize="16" FontWeight="SemiBold"/>
            <TextBlock x:Name="AppVerText" Text="" FontSize="11" Foreground="{DynamicResource TextDim}" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="NavPanel" Margin="16,8,16,16"/>
        </ScrollViewer>
        <StackPanel Grid.Row="2" Margin="28,12,16,20">
          <TextBlock x:Name="RptNo" Text="" FontSize="11" Foreground="{DynamicResource TextDim}" Typography.NumeralAlignment="Tabular"/>
          <TextBlock x:Name="RptDate" Text="" FontSize="11" Foreground="{DynamicResource TextDim}" Margin="0,4,0,0" Typography.NumeralAlignment="Tabular"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- ================================================================
           顶栏（design.md 4.6）：页面标题 + 受检机器；右边全局动作和换肤
           ================================================================ -->
      <Border Grid.Row="0" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Stroke}"
              BorderThickness="0,0,0,1" Padding="24,16,24,16" MinHeight="72">
        <Grid>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="PageTitle" Text="概览" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock x:Name="SubTitle" Text="" FontSize="12" Foreground="{DynamicResource TextDim}" Margin="0,4,0,0"
                       TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <CheckBox x:Name="ChkRestorePoint" Style="{DynamicResource SwitchBox}" Content="动手前自动创建系统还原点" IsChecked="True"
                      Foreground="{DynamicResource TextMid}" FontSize="12" Margin="0,0,16,0" VerticalAlignment="Center"/>
            <Button x:Name="BtnRestorePoint" Content="立即创建还原点"/>
            <Button x:Name="BtnThemeToggle" Style="{DynamicResource ButtonIcon}" ToolTip="切换浅色 / 深色" Margin="4,0,0,0">
              <md:PackIcon x:Name="ThemeIcon" Kind="WeatherNight" Width="20" Height="20"/>
            </Button>
          </StackPanel>
        </Grid>
      </Border>

      <TabControl Grid.Row="1" x:Name="Tabs" Style="{DynamicResource PageHost}">

        <!-- ============================================================
             概览：卡片网格（design.md 5.1）
             第一行 主角卡（健康度）+ 两张温度卡；第二行 内存 / 系统盘 / 实时占用；
             第三行 检验结论（宽）+ 受检类别
             温度 / 风扇 / 频率来自 LibreHardwareMonitorLib，读不到一律「—」
             ============================================================ -->
        <TabItem Header="概览">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <Grid Margin="24">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="16"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="16"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <StackPanel x:Name="DashSummary" Grid.Row="0" Grid.ColumnSpan="5"/>
              <Border x:Name="DashHero" Grid.Row="1" Grid.Column="0" Background="{DynamicResource HeroFill}" CornerRadius="12" Padding="24"/>
              <Border x:Name="DashCell1" Grid.Row="1" Grid.Column="2" Style="{DynamicResource CardBorder}"/>
              <Border x:Name="DashCell2" Grid.Row="1" Grid.Column="4" Style="{DynamicResource CardBorder}"/>
              <Border x:Name="DashCell3" Grid.Row="3" Grid.Column="0" Style="{DynamicResource CardBorder}"/>
              <Border x:Name="DashCell4" Grid.Row="3" Grid.Column="2" Style="{DynamicResource CardBorder}"/>
              <Border x:Name="DashCell5" Grid.Row="3" Grid.Column="4" Style="{DynamicResource CardBorder}"/>
              <Border Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="3" Style="{DynamicResource CardBorder}">
                <StackPanel x:Name="DashVerdict"/>
              </Border>
              <Border Grid.Row="5" Grid.Column="4" Style="{DynamicResource CardBorder}">
                <StackPanel>
                  <StackPanel x:Name="DashPickHead"/>
                  <StackPanel x:Name="DashQuickPick" Margin="0,4,0,0"/>
                  <StackPanel x:Name="DashSignOff" Margin="0,24,0,0"/>
                </StackPanel>
              </Border>
            </Grid>
          </ScrollViewer>
        </TabItem>

        <!-- 性能优化：左边预设 + 列表，右边说明 -->
        <TabItem Header="性能优化">
          <Grid Margin="24">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="400"/>
            </Grid.ColumnDefinitions>
            <Grid Grid.Column="0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <!-- ============================================================
                   预设区。【必须可以收起】12 个预设全展开会把下面的列表挤成 0 高度。
                   常驻的只有「按用途选」一行，其余两组点「更多」展开。
                   ============================================================ -->
              <Border Grid.Row="0" Style="{DynamicResource CardBorder}" Padding="16,12">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                      <md:PackIcon Kind="TuneVariant" Width="20" Height="20" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center"/>
                      <TextBlock Text="按用途选" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center" Margin="8,0,0,0"/>
                    </StackPanel>
                    <StackPanel x:Name="PresetPrimary" Grid.Column="1" VerticalAlignment="Center"/>
                    <StackPanel x:Name="PresetHeader" Grid.Column="2" Orientation="Horizontal"
                                Cursor="Hand" Background="Transparent" VerticalAlignment="Center" Margin="16,0,0,0">
                      <TextBlock x:Name="PresetMoreHint" Text="更多" Foreground="{DynamicResource TextDim}" FontSize="12" VerticalAlignment="Center"/>
                      <TextBlock x:Name="PresetToggle" Text="展开" FontSize="12" FontWeight="SemiBold"
                                 Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="8,0,0,0"/>
                    </StackPanel>
                  </Grid>
                  <StackPanel x:Name="PresetBody" Margin="0,12,0,0" Visibility="Collapsed">
                    <StackPanel x:Name="PresetBar"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <WrapPanel Grid.Row="1" Margin="0,16,0,16">
                <TextBox x:Name="TweakSearch" Style="{DynamicResource SearchBox}" Width="200" Margin="0,0,8,0"
                         md:HintAssist.Hint="搜索优化项…"/>
                <Button x:Name="BtnPickRecommended" Content="勾选通用推荐项"/>
                <Button x:Name="BtnPickNone" Content="全部不选"/>
                <Button x:Name="BtnRescan" Content="重新检测状态"/>
              </WrapPanel>
              <Border Grid.Row="2" Style="{DynamicResource ListCardBorder}">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                  </Grid.RowDefinitions>
                  <!-- 列名。没有它，右边那三列就是三串没名字的东西 -->
                  <StackPanel Grid.Row="0">
                    <Grid Margin="0,4,24,8">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="72"/>
                        <ColumnDefinition Width="24"/>
                        <ColumnDefinition Width="80"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Text="检验项目" Grid.Column="0" FontSize="11" Foreground="{DynamicResource TextDim}" Margin="38,0,0,0"/>
                      <!-- v6.2：激进优化排在列表最下面，朋友往下拉了半天才找到。第一屏给个跳转入口（激进项本身不动：默认不勾、不进预设） -->
                      <StackPanel x:Name="JumpAggressive" Grid.Column="0" Orientation="Horizontal" HorizontalAlignment="Right"
                                  Margin="0,0,16,0" Cursor="Hand" Background="Transparent" ToolTip="跳到列表最下面的「激进优化」一组">
                        <md:PackIcon Kind="LightningBolt" Width="14" Height="14" Foreground="{DynamicResource Accent}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="JumpAggressiveText" Text="激进优化" FontSize="12" FontWeight="SemiBold"
                                   Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="4,0,0,0"/>
                        <md:PackIcon Kind="ChevronDown" Width="14" Height="14" Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="2,0,0,0"/>
                      </StackPanel>
                      <TextBlock Text="结果" Grid.Column="1" FontSize="11" Foreground="{DynamicResource TextDim}" TextAlignment="Right"/>
                      <TextBlock Text="安全范围" Grid.Column="3" FontSize="11" Foreground="{DynamicResource TextDim}" TextAlignment="Right"/>
                    </Grid>
                    <Rectangle Height="1" Fill="{DynamicResource StrokeMed}" Margin="12,0,12,4"/>
                  </StackPanel>
                  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel x:Name="TweakPanel" Margin="0,0,4,0"/>
                  </ScrollViewer>
                </Grid>
              </Border>
              <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,16,0,0">
                <Button x:Name="BtnApplySelected" Content="应用选中的优化" Style="{DynamicResource ButtonPrimary}"/>
                <Button x:Name="BtnRevertSelected" Content="还原选中的优化"/>
                <Button x:Name="BtnRevertAll" Content="全部还原为系统默认" Style="{DynamicResource ButtonDanger}"/>
                <TextBlock x:Name="TweakSelCount" Text="" Foreground="{DynamicResource TextDim}" FontSize="12"
                           VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Grid>
            <Border Grid.Column="2" Style="{DynamicResource CardBorder}" Padding="0">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="TweakDetail" Margin="20"/>
              </ScrollViewer>
            </Border>
          </Grid>
        </TabItem>

        <!-- 垃圾清理 -->
        <TabItem Header="垃圾清理">
          <Grid Margin="24">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="400"/>
            </Grid.ColumnDefinitions>
            <Grid Grid.Column="0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <WrapPanel Grid.Row="0" Margin="0,0,0,16">
                <TextBox x:Name="CleanSearch" Style="{DynamicResource SearchBox}" Width="180" Margin="0,0,8,0"
                         md:HintAssist.Hint="搜索清理项…"/>
                <Button x:Name="BtnScanJunk" Content="扫描可清理的垃圾"/>
                <Button x:Name="BtnPickCleanRec" Content="勾选推荐项"/>
                <Button x:Name="BtnPickCleanNone" Content="全部不选"/>
                <TextBlock x:Name="TotalJunkText" Text="还没扫描" Foreground="{DynamicResource TextDim}" FontSize="12"
                           VerticalAlignment="Center" Margin="8,10,0,0"/>
              </WrapPanel>
              <Border Grid.Row="1" Style="{DynamicResource ListCardBorder}">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel x:Name="CleanPanel" Margin="0,0,4,0"/>
                </ScrollViewer>
              </Border>
              <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,16,0,0">
                <Button x:Name="BtnClean" Content="开始清理选中项" Style="{DynamicResource ButtonPrimary}"/>
                <TextBlock x:Name="CleanSelCount" Text="" Foreground="{DynamicResource TextDim}" FontSize="12"
                           VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Grid>
            <Border Grid.Column="2" Style="{DynamicResource CardBorder}" Padding="0">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="CleanDetail" Margin="20"/>
              </ScrollViewer>
            </Border>
          </Grid>
        </TabItem>

        <!-- 日常维护：左边一摞处置卡，右边大文件查找 -->
        <TabItem Header="日常维护">
          <Grid Margin="24">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="400"/>
            </Grid.ColumnDefinitions>
            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="MaintainPanel" Margin="0,0,4,0"/>
            </ScrollViewer>
            <Border Grid.Column="2" Style="{DynamicResource CardBorder}">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0">
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                    <md:PackIcon Kind="FileSearchOutline" Width="20" Height="20" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center"/>
                    <TextBlock Text="大文件查找" FontSize="16" FontWeight="SemiBold" Margin="8,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock Style="{DynamicResource Hint}"
                             Text="「我的 C 盘到底被什么占满了」—— 点一个盘符开始扫描，列出最大的 40 个文件。只列出来给你看，不会自动删任何东西。扫描要一两分钟。"/>
                  <WrapPanel x:Name="BigFileDrives" Margin="0,12,0,8"/>
                </StackPanel>
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,8,0,0">
                  <StackPanel x:Name="BigFilePanel"/>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>
        </TabItem>

        <!-- 弹窗排查：左边扫自启位置，右边抓现行 -->
        <TabItem Header="弹窗排查">
          <Grid Margin="24">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="440"/>
            </Grid.ColumnDefinitions>
            <Grid Grid.Column="0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="16"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Grid.Row="0" Style="{DynamicResource CardBorder}">
                <StackPanel>
                  <TextBlock TextWrapping="Wrap" FontSize="13" LineHeight="21" Foreground="{DynamicResource TextMid}"
                             Text="黑框一闪而过、一次弹好几个 —— 那是有程序在后台调用命令行但没把窗口藏好。这里会把所有「会在后台执行命令」的地方扫一遍，按可疑程度排序。"/>
                  <WrapPanel Margin="0,16,0,0">
                    <Button x:Name="BtnInspect" Content="开始扫描" Style="{DynamicResource ButtonPrimary}"/>
                    <Button x:Name="BtnInspectFilter" Content="只看会弹黑框的"/>
                    <TextBlock x:Name="InspectSummary" Text="还没扫描" Foreground="{DynamicResource TextDim}"
                               VerticalAlignment="Center" Margin="8,10,0,0" FontSize="12"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Grid.Row="2" Style="{DynamicResource ListCardBorder}">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel x:Name="InspectPanel" Margin="12,4,12,4"/>
                </ScrollViewer>
              </Border>
            </Grid>
            <Border Grid.Column="2" Style="{DynamicResource CardBorder}">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0">
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                    <md:PackIcon Kind="ConsoleLine" Width="20" Height="20" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center"/>
                    <TextBlock Text="抓现行" FontSize="16" FontWeight="SemiBold" Margin="8,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock Style="{DynamicResource Hint}"
                             Text="左边扫的是「开机会自动跑什么」。但弹窗也可能来自某个已经在运行的程序定期开的子进程 —— 那种情况扫任何自启位置都找不到。这里直接盯「新建进程」，不管它藏在哪都跑不掉。"/>

                  <TextBlock Text="实时监控" FontSize="14" FontWeight="SemiBold" Margin="0,24,0,0"/>
                  <TextBlock Style="{DynamicResource Hint}" Margin="0,4,0,0"
                             Text="最快，立等可取。点「开始监控」后正常用电脑，等黑框出现 —— 出现的瞬间就会记下是谁开的、它的父进程是谁。"/>
                  <WrapPanel Margin="0,12,0,0">
                    <Button x:Name="BtnWatchStart" Content="开始监控"/>
                    <Button x:Name="BtnWatchStop" Content="停止" IsEnabled="False"/>
                  </WrapPanel>

                  <Rectangle Height="1" Fill="{DynamicResource Stroke}" Margin="0,20,0,0"/>
                  <TextBlock Text="持续记录" FontSize="14" FontWeight="SemiBold" Margin="0,20,0,0"/>
                  <TextBlock Style="{DynamicResource Hint}" Margin="0,4,0,0"
                             Text="打开系统自带的进程创建审核，关掉本工具也在记，之后随时回来查，带完整命令行。适合「弹窗不定时、蹲不到」的情况。"/>
                  <WrapPanel Margin="0,12,0,0">
                    <Button x:Name="BtnProcAudit" Content="开启持续记录" Margin="0,0,8,8"/>
                    <Button x:Name="BtnProcLog" Content="查看进程记录" Margin="0,0,8,8"/>
                    <Button x:Name="BtnEnableTaskLog" Content="开启任务记录" Margin="0,0,8,8"/>
                    <Button x:Name="BtnRecentRuns" Content="查看任务记录" Margin="0,0,8,8"/>
                  </WrapPanel>
                  <TextBlock x:Name="WatchStatus" Text="" FontSize="12" Foreground="{DynamicResource TextMid}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                </StackPanel>
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,12,0,0">
                  <StackPanel x:Name="RecentRunPanel"/>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>
        </TabItem>

        <!-- 启动项管理 -->
        <TabItem Header="启动项管理">
          <Grid Margin="24">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,16">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="BtnRefreshStartup" Content="刷新列表" VerticalAlignment="Top"/>
              <TextBlock Grid.Column="1" Style="{DynamicResource Hint}" VerticalAlignment="Center" Margin="8,0,0,0"
                         Text="关掉开关 = 禁止开机自启（立即生效，随时能勾回来，不删除任何文件）。标「看情况」的自己判断：认得、且需要它开机就在，就留着；完全没印象的可以先关一天试试。"/>
            </Grid>
            <Border Grid.Row="1" Style="{DynamicResource ListCardBorder}">
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="StartupPanel" Margin="0,0,4,0"/>
              </ScrollViewer>
            </Border>
          </Grid>
        </TabItem>

        <!-- 自带软件：微软预装的 UWP 应用，哪些能删哪些不能 -->
        <TabItem Header="自带软件">
          <Grid Margin="24">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <WrapPanel Grid.Row="0" Margin="0,0,0,16">
              <Button x:Name="BtnRefreshAppx" Content="刷新列表"/>
              <Button x:Name="BtnCheckAppxSafe" Content="勾选「可以删」的"/>
              <Button x:Name="BtnUninstallAppx" Content="卸载勾选的应用" Style="{DynamicResource ButtonPrimary}"/>
              <TextBlock x:Name="AppxCounter" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="8,10,0,0" FontSize="12"/>
            </WrapPanel>
            <!-- 提示条（design.md 4.4）：全页只此一条 -->
            <Border Grid.Row="1" Background="{DynamicResource AccentTint}" CornerRadius="8" Padding="16,12" Margin="0,0,0,16">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <md:PackIcon Kind="InformationOutline" Width="20" Height="20" Foreground="{DynamicResource Accent}" VerticalAlignment="Top"/>
                <TextBlock Grid.Column="1" TextWrapping="Wrap" FontSize="12" LineHeight="20" Foreground="{DynamicResource TextMid}" Margin="12,0,0,0"
                           Text="卸载只针对当前用户，不动系统镜像 —— 任何一个删错了，都能去 Microsoft Store 搜名字原样装回来。标「必须留」的项勾不上，那些是删了会让系统出毛病的（应用商店、安全中心界面、运行库、解码器）。标「看情况」的先点开说明看完再决定，拿不准就别删。"/>
              </Grid>
            </Border>
            <Border Grid.Row="2" Style="{DynamicResource ListCardBorder}">
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="AppxPanel" Margin="0,0,4,0"/>
              </ScrollViewer>
            </Border>
          </Grid>
        </TabItem>

        <!-- 个性化：换肤 -->
        <TabItem Header="个性化">
          <Grid Margin="24">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" TextWrapping="Wrap" FontSize="13" LineHeight="21" Foreground="{DynamicResource TextMid}" Margin="0,0,0,16" MaxWidth="804" HorizontalAlignment="Left"
                       Text="换肤只改界面的底色、卡片和主色。表示危险程度的那一种墨色是故意不跟着变的 —— 「高危」永远是红的，不能因为换了皮肤看错。选好立刻生效，下次打开自动记住。"/>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="ThemePanel" MaxWidth="820" HorizontalAlignment="Left" Margin="0,0,4,0"/>
            </ScrollViewer>
          </Grid>
        </TabItem>

        <!-- 系统体检 -->
        <TabItem Header="系统体检">
          <Grid Margin="24">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- ★ 一屏只能有一个主按钮 ★ WrapPanel：窗口拉窄时按钮换行，不会被顶出可视区 -->
            <WrapPanel Grid.Row="0" Margin="0,0,0,8">
              <Button x:Name="BtnHealthScan" Content="重新体检" Style="{DynamicResource ButtonPrimary}" Margin="0,0,8,8"/>
              <Button x:Name="BtnFpsDiag" Content="为什么我帧数没变？" Margin="0,0,8,8"/>
              <Button x:Name="BtnOcCoach" Content="我能超频吗？" Margin="0,0,8,8"/>
              <Button x:Name="BtnVendor" Content="该装哪个厂商工具" Margin="0,0,8,8"/>
              <Button x:Name="BtnAddExclusion" Content="游戏目录加白名单" ToolTip="把游戏文件夹加入 Windows Defender 扫描白名单" Margin="0,0,8,8"/>
              <Button x:Name="BtnSfc" Content="检查系统文件" ToolTip="运行 sfc /scannow，扫描并修复损坏的系统文件" Margin="0,0,8,8"/>
              <Button x:Name="BtnCopyReport" Content="复制报告" ToolTip="把体检报告复制到剪贴板，可以直接粘贴发给别人" Margin="0,0,8,8"/>
              <Button x:Name="BtnExportReport" Content="导出诊断报告" ToolTip="把硬件信息、体检结论、日志打成一个文件放到桌面" Margin="0,0,8,8"/>
            </WrapPanel>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="420"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Style="{DynamicResource CardBorder}" Padding="0">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="InfoPanel" Margin="20"/>
                </ScrollViewer>
              </Border>
              <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="AdvicePanel" Margin="0,0,4,0"/>
              </ScrollViewer>
            </Grid>
          </Grid>
        </TabItem>

        <!-- 操作日志 -->
        <TabItem Header="操作日志">
          <Grid Margin="24">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <WrapPanel Grid.Row="0" Margin="0,0,0,16">
              <Button x:Name="BtnOpenBackup" Content="打开备份 / 日志文件夹"/>
              <Button x:Name="BtnCopyLog" Content="复制全部日志"/>
              <TextBlock Text="所有修改的原始值都保存在备份文件夹里，「还原」功能依赖它，请不要删除。"
                         Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="8,10,0,0" FontSize="12"/>
            </WrapPanel>
            <Border Grid.Row="1" Style="{DynamicResource ListCardBorder}">
              <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="LogPanel" Margin="12,4,12,4"/>
              </ScrollViewer>
            </Border>
          </Grid>
        </TabItem>
      </TabControl>

      <!-- ========== 状态栏 ========== -->
      <Border Grid.Row="2" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Stroke}" BorderThickness="0,1,0,0"
              Padding="24,0" Height="32">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" x:Name="StatusText" Text="就绪" Foreground="{DynamicResource TextDim}" FontSize="12"
                     TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
          <ProgressBar Grid.Column="1" x:Name="BusyBar" Width="160" Height="4" IsIndeterminate="False"
                       Visibility="Collapsed" VerticalAlignment="Center" Margin="16,0,0,0"/>
        </Grid>
      </Border>
    </Grid>

    <!-- ================================================================
         做完了的提示（D6）：右下角白卡，从下方弹入，底部一条强调色细线倒计时，走完自己淡出。
         动画在 Show-Toast。平时 Collapsed，不占位、不吃点击。
         ================================================================ -->
    <Border x:Name="ToastHost" Grid.ColumnSpan="2" HorizontalAlignment="Right" VerticalAlignment="Bottom"
            Margin="0,0,24,48" Width="320" Visibility="Collapsed" Opacity="0" IsHitTestVisible="False"
            Background="{DynamicResource Card}" BorderBrush="{DynamicResource StrokeStrong}" BorderThickness="1" CornerRadius="12">
      <Border.RenderTransform>
        <TranslateTransform x:Name="ToastY" Y="24"/>
      </Border.RenderTransform>
      <Grid>
        <StackPanel Orientation="Horizontal" Margin="16,12,16,16">
          <Ellipse x:Name="ToastDot" Width="8" Height="8" Fill="{DynamicResource SemOk}" VerticalAlignment="Top" Margin="0,6,12,0"/>
          <TextBlock x:Name="ToastText" Text="" FontSize="13" TextWrapping="Wrap" MaxWidth="260" LineHeight="20"
                     Foreground="{DynamicResource TextMain}"/>
        </StackPanel>
        <Border ClipToBounds="True" VerticalAlignment="Bottom" CornerRadius="0,0,12,12" Height="2" Margin="1,0,1,0">
          <Rectangle x:Name="ToastTimer" Height="2" Fill="{DynamicResource Accent}" RenderTransformOrigin="0,0.5">
            <Rectangle.RenderTransform>
              <ScaleTransform x:Name="ToastTimerScale" ScaleX="1"/>
            </Rectangle.RenderTransform>
          </Rectangle>
        </Border>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

# 把随包字体套到整个窗口。字体路径是运行时算出来的（取决于程序被解压到哪儿），XAML 里写不了。
try {
    $Script:Window.FontFamily = New-Object System.Windows.Media.FontFamily $Script:FontStack
} catch { }

# 把所有命名控件收集到 $Script:UI
$Script:UI = @{}
foreach ($n in @(
        'SubTitle', 'PageTitle', 'AppVerText', 'RptNo', 'RptDate', 'ChkRestorePoint', 'BtnRestorePoint', 'BtnThemeToggle', 'ThemeIcon',
        'Tabs', 'NavPanel',
        'DashSummary', 'DashHero', 'DashCell1', 'DashCell2', 'DashCell3', 'DashCell4', 'DashCell5',
        'DashVerdict', 'DashPickHead', 'DashQuickPick', 'DashSignOff',
        'TweakPanel', 'TweakDetail', 'JumpAggressive', 'JumpAggressiveText', 'BtnPickRecommended', 'BtnPickNone', 'BtnRescan', 'PresetBar',
        'PresetHeader', 'PresetToggle', 'PresetBody', 'PresetPrimary', 'PresetMoreHint',
        'BtnApplySelected', 'BtnRevertSelected', 'BtnRevertAll',
        'CleanPanel', 'CleanDetail', 'BtnScanJunk', 'BtnPickCleanRec', 'BtnPickCleanNone', 'BtnClean', 'TotalJunkText',
        'TweakSearch', 'TweakSelCount', 'CleanSearch', 'CleanSelCount',
        'StartupPanel', 'BtnRefreshStartup',
        'AppxPanel', 'BtnRefreshAppx', 'BtnCheckAppxSafe', 'BtnUninstallAppx', 'AppxCounter',
        'ThemePanel',
        'MaintainPanel', 'BigFileDrives', 'BigFilePanel',
        'InspectPanel', 'BtnInspect', 'BtnInspectFilter', 'InspectSummary',
        'RecentRunPanel', 'BtnRecentRuns', 'BtnEnableTaskLog',
        'BtnWatchStart', 'BtnWatchStop', 'BtnProcAudit', 'BtnProcLog', 'WatchStatus',
        'InfoPanel', 'AdvicePanel', 'BtnHealthScan', 'BtnFpsDiag', 'BtnOcCoach', 'BtnVendor', 'BtnAddExclusion', 'BtnSfc', 'BtnCopyReport', 'BtnExportReport',
        'LogPanel', 'LogScroll', 'BtnOpenBackup', 'BtnCopyLog', 'StatusText', 'BusyBar')) {
    $Script:UI[$n] = $Script:Window.FindName($n)
}

foreach ($n in 'ToastHost', 'ToastY', 'ToastDot', 'ToastText', 'ToastTimerScale') { $Script:UI[$n] = $Script:Window.FindName($n) }

# =====================================================================
#  侧边栏导航（design.md 4.5）
# ---------------------------------------------------------------------
#  分组顺序是给人看的，和 TabItem 的顺序（出图 -ShotTab 的序号）无关 ——
#  点哪一项就按页名去找对应的 TabItem。
# =====================================================================
$Script:NavGroups = @(
    @{ G = '总览'; Items = @(@{ T = '概览'; I = 'ViewDashboardOutline' }) },
    @{ G = '优化'; Items = @(
            @{ T = '性能优化'; I = 'RocketLaunchOutline' },
            @{ T = '垃圾清理'; I = 'Broom' },
            @{ T = '日常维护'; I = 'WrenchOutline' }) },
    @{ G = '排查'; Items = @(
            @{ T = '弹窗排查'; I = 'ConsoleLine' },
            @{ T = '启动项管理'; I = 'PowerSettings' },
            @{ T = '自带软件'; I = 'PackageVariantClosed' }) },
    @{ G = '系统'; Items = @(
            @{ T = '系统体检'; I = 'Stethoscope' },
            @{ T = '操作日志'; I = 'ClipboardTextClockOutline' },
            @{ T = '个性化'; I = 'PaletteOutline' }) }
)
$Script:NavItems = @{}

function Select-TabByHeader {
    param([string]$Header)
    $tabs = $Script:UI.Tabs
    for ($i = 0; $i -lt $tabs.Items.Count; $i++) {
        if ("$($tabs.Items[$i].Header)" -eq $Header) { $tabs.SelectedIndex = $i; return }
    }
}

function Build-NavUI {
    $p = $Script:UI.NavPanel
    if ($null -eq $p) { return }
    $p.Children.Clear()
    $Script:NavItems = @{}
    $first = $true
    foreach ($grp in $Script:NavGroups) {
        $gt = New-TextBlock -Text $grp.G -Size 11 -Color 'TextDim'
        $gt.Margin = New-Thick 12 $(if ($first) { 8 } else { 24 }) 0 8
        $p.Children.Add($gt) | Out-Null
        $first = $false
        foreach ($it in $grp.Items) {
            $b = New-Object System.Windows.Controls.Border
            $b.Height = 40
            $b.CornerRadius = New-Corner 8
            $b.Padding = New-Thick 12 0 12 0
            $b.Margin = New-Thick 0 0 0 4
            $b.Background = [System.Windows.Media.Brushes]::Transparent
            $b.Cursor = 'Hand'
            $b.Tag = $it.T
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $sp.VerticalAlignment = 'Center'
            $ic = New-Icon -Kind $it.I -Size 20 -Color 'TextDim'
            $sp.Children.Add($ic) | Out-Null
            $tx = New-TextBlock -Text $it.T -Size 13 -Color 'TextMid'
            $tx.VerticalAlignment = 'Center'
            $tx.Margin = New-Thick 12 0 0 0
            $sp.Children.Add($tx) | Out-Null
            $b.Child = $sp
            Add-Interactive $b -BgNormal 'Transparent' -BgHover 'CardHover'
            $b.Add_MouseLeftButtonUp({ Select-TabByHeader "$($this.Tag)" })
            # 图标微动（D7）：悬停播一次，动作跟页面含义有关
            $nudge = switch ($it.T) { '垃圾清理' { 'Wiggle' } '日常维护' { 'Wiggle' } '系统体检' { 'Wiggle' } '性能优化' { 'Zap' } default { 'Pop' } }
            $b.Resources['__nudgeIcon'] = $ic
            $b.Resources['__nudgeStyle'] = $nudge
            $b.Add_MouseEnter({ Start-IconNudge $this.Resources['__nudgeIcon'] $this.Resources['__nudgeStyle'] })
            $p.Children.Add($b) | Out-Null
            $Script:NavItems[$it.T] = @{ Box = $b; Icon = $ic; Text = $tx }
        }
    }
    Update-NavSelection
}

function Update-NavSelection {
    <# 当前页：AccentTint 底 + Accent 图标和字；其余恢复。顶栏标题跟着换。 #>
    $cur = "$($Script:UI.Tabs.SelectedItem.Header)"
    foreach ($k in $Script:NavItems.Keys) {
        $n = $Script:NavItems[$k]
        $on = ($k -eq $cur)
        $n.Box.Resources['__sel'] = $on
        $n.Box.Background = Get-Brush $(if ($on) { 'AccentTint' } else { 'Transparent' })
        $n.Icon.Foreground = Get-Brush $(if ($on) { 'Accent' } else { 'TextDim' })
        $n.Text.Foreground = Get-Brush $(if ($on) { 'Accent' } else { 'TextMid' })
        $n.Text.FontWeight = $(if ($on) { 'SemiBold' } else { 'Normal' })
    }
    if ($Script:UI.PageTitle -and $cur) { $Script:UI.PageTitle.Text = $cur }
}

function Update-ThemeToggleIcon {
    <# 浅色时显示月亮（点了去深色），深色时显示太阳 #>
    try { $Script:UI.ThemeIcon.Kind = $(if ($Script:ThemeIsDark) { 'WhiteBalanceSunny' } else { 'WeatherNight' }) } catch { }
}
# ---------------------------------------------------------------------
#  操作日志表
# ---------------------------------------------------------------------
function Add-LogRow {
    <#
      一行日志。错误 ↑↑、警告 ↑，信息和成功不标不上墨 ——
      和全app同一套判读语法：满页平静，出事的那几行自己跳出来。
    #>
    param([string]$Time, [string]$Level, [string]$Message)
    $p = $Script:UI.LogPanel
    if ($null -eq $p) { return }

    $mark = switch ($Level) { '错误' { '↑↑' } '警告' { '↑' } default { '' } }
    $abn = [bool]$mark

    $b = New-Object System.Windows.Controls.Border
    $b.BorderBrush = Get-Brush $Script:CARD_BORDER
    $b.BorderThickness = New-Thick 0 0 0 1
    $b.Padding = New-Thick 0 8 0 8

    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in @(28.0, 80.0, 56.0, 0.0)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq 0) {
            New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        } else {
            New-Object System.Windows.GridLength $w
        }
        $g.ColumnDefinitions.Add($cd)
    }

    $mk = New-TextBlock -Text $mark -Size 13 -Color $(if ($abn) { '#8A5750' } else { 'TextDim' })
    if ($abn) { $mk.FontWeight = 'SemiBold' }
    $mk.VerticalAlignment = 'Top'
    $g.Children.Add($mk) | Out-Null

    # ★ 表格数位 ★ 时间列不加这句，1 比 8 窄，整列时间对不齐
    $tm = New-TextBlock -Text $Time -Size 12 -Color 'TextDim'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($tm, 'Tabular')
    $tm.VerticalAlignment = 'Top'
    [System.Windows.Controls.Grid]::SetColumn($tm, 1)
    $g.Children.Add($tm) | Out-Null

    $lv = New-TextBlock -Text $Level -Size 12 -Color $(if ($abn) { '#8A5750' } else { 'TextDim' })
    if ($abn) { $lv.FontWeight = 'SemiBold' }
    $lv.VerticalAlignment = 'Top'
    [System.Windows.Controls.Grid]::SetColumn($lv, 2)
    $g.Children.Add($lv) | Out-Null

    $ms = New-TextBlock -Text $Message -Size 13 -Color 'TextMain' -Wrap $true
    if ($abn) { $ms.FontWeight = 'SemiBold' }
    [System.Windows.Controls.Grid]::SetColumn($ms, 3)
    $g.Children.Add($ms) | Out-Null

    $b.Child = $g
    $p.Children.Add($b) | Out-Null
}

function Build-LogUI {
    <# 按 LogEntries 重画整张日志表。换肤和首次建表都走这儿。 #>
    $p = $Script:UI.LogPanel
    if ($null -eq $p) { return }
    $p.Children.Clear()
    Add-ColHeader -Panel $p -First '内容' -Cols @() -Indent 164
    # ★ 列名要和行里的列轨对齐 ★ 前三列 28+80+56 = 164
    $hdr = $p.Children[0].Children[0]
    $hdr.Margin = New-Thick 0 4 0 8
    foreach ($c in @(@{ T = '时间'; X = 28.0 }, @{ T = '类别'; X = 108.0 })) {
        $t = New-TextBlock -Text $c.T -Size 11 -Color 'TextDim'
        $t.Margin = New-Thick $c.X 0 0 0
        $t.HorizontalAlignment = 'Left'
        $hdr.Children.Add($t) | Out-Null
    }

    foreach ($en in $Script:LogEntries) {
        Add-LogRow -Time $en.Time -Level $en.Level -Message $en.Message
    }
}

# 日志出口切到这张表；之前已经记下的几条会在 Build-LogUI 里补画出来
$Script:LogBox = $null
$Script:LogSink = {
    param($t, $l, $m)
    Add-LogRow -Time $t -Level $l -Message $m
    try { $Script:UI.LogScroll.ScrollToEnd() } catch { }
}

# ---------------------------------------------------------------------
#  5. 性能优化页
# ---------------------------------------------------------------------
$Script:Tweaks = Get-AllTweaks
$Script:TweakRows = @{}     # Id -> @{ Check; Badge; Tweak }
$Script:GameNotes = Get-GameNotes
$Script:Presets = Get-GamePresets

# =====================================================================
#  概览页
# ---------------------------------------------------------------------
#  ★ 轮询只在这一页可见时跑 ★
#    全量刷新一次传感器实测 100ms 左右。每秒一次 = 持续吃掉约 10% 的
#    一个核心。用户切到别的页面还在后台烧，那就成了
#    「优化工具自己是最大的后台负担」—— 所以切走立刻停表。
# =====================================================================
$Script:DashTimer = $null
$Script:DashRows = @{}
$Script:DashScoreCache = $null






$Script:DashSeq = -1
function Start-DashTimer {
    <#
      v6.2：读传感器挪到后台线（Start-SensorLoop），这里 200ms 看一眼有没有新读数，
      有才刷界面。界面线程上只剩「写数字、挪量程条」这点活。
    #>
    $Script:Sensor.Active = $true
    Start-SensorLoop
    if ($Script:DashTimer) { $Script:DashTimer.Start(); return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(200)
    $t.Add_Tick({
            $seq = $Script:Sensor.Seq
            if ($seq -eq $Script:DashSeq) { return }
            $Script:DashSeq = $seq
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { Update-DashUI } catch { }
            Add-PerfTick 'DashTick' $sw.Elapsed.TotalMilliseconds
            Add-PerfTick 'SensorRead(后台)' $Script:Sensor.Ms
            # 第一份读数到了、健康度还没算：现在算（温度那一项要等传感器）
            if ($null -eq $Script:DashScoreCache -and -not $Script:DashScoreBusy) { Update-DashScore }
        })
    $Script:DashTimer = $t
    $t.Start()
}

function Stop-DashTimer {
    $Script:Sensor.Active = $false
    if ($Script:DashTimer) { $Script:DashTimer.Stop() }
}

# =====================================================================
#  预设卡片
# ---------------------------------------------------------------------
#  以前这里是一排排小方块按钮，字小、挤在一起、没有层次 ——
#  整个界面最廉价的地方就是它。现在改成卡片：
#    左侧一道彩色竖条（分组色）+ 标题 + 一行副标题
#
#  ★ 为什么不用 emoji 图标 ★
#    试过，在深色/战术风皮肤下那些彩色小图案很跳，像贴纸。
#    一道细色条反而更「贵」，而且跟着皮肤走不会脏。
# =====================================================================

# 预设 Id -> 副标题（卡片第二行）。标题里已经有的信息不重复。
$Script:PresetSubtitle = @{
    FPS3   = '三个 FPS 都受益，不确定就选这个'
    CS2    = '三合一 + CPU 调度'
    VAL    = '三合一 + ACE 反作弊兼容'
    DF     = '三合一 + 画面稳定'
    SAFE   = '只做零风险项，不碰安全设置'
    AAA    = '黑神话 / 艾尔登法环，要的是不卡顿'
    MMO    = '梦幻 / 剑网3 / 原神，重点在延迟'
    OFFICE = '办公上网，只想电脑别这么卡'
    OLDPC  = '内存小 / 机械盘，避开帮倒忙的项'
    BROW1  = '零代价，只关后台常驻'
    BROW2  = '再关一批没人用的功能'
    BROW3  = '有代价：同站标签页共用进程'
}

$Script:SelectedPresetCard = $null
$Script:PresetCardList = New-Object System.Collections.ArrayList


function Get-RptRange {
    <#
      一个检验项目的参考范围。返回 @{ Text; Lo; Hi }

      【这些阈值必须有出处，不许拍脑袋】
        参考范围是这个产品唯一无法被抄的东西，写错了整套就失去意义。
          显卡温度 83  —— NVIDIA 消费级显卡默认温度墙就是 83°C，超过开始降频
          处理器温度 95 —— AMD/Intel 移动端 Tjmax 约 100~105°C，
                            长期贴到 95 以上基本处在降频区
          内存占用 85  —— 超过之后 Windows 开始大量换页，体感就是「卡一下」
          系统盘可用 20 GB —— Windows 功能更新需要的临时空间下限
        占用率这类瞬时读数**不设参考范围**（显示「—」）：
        某一秒 100% 不说明任何问题，给个范围反而是误导。
    #>
    #  Max 是区间条的满量程，也要有出处：
    #    温度轴到 110 —— 移动端 Tjmax 约 100~105，留一点余量
    #    占用率轴到 100 —— 它本来就是百分比
    #    系统盘的满量程是这块盘的实际容量，由调用处传进来
    param([string]$Key)
    switch ($Key) {
        'CpuTemp' { return @{ Text = '< 95'; Lo = $null; Hi = 95; Max = 110 } }
        'GpuTemp' { return @{ Text = '< 83'; Lo = $null; Hi = 83; Max = 110 } }
        'Ram' { return @{ Text = '< 85'; Lo = $null; Hi = 85; Max = 100 } }
        'Disk' { return @{ Text = '> 20'; Lo = 20; Hi = $null; Max = 100 } }
        default { return @{ Text = [string][char]0x2014; Lo = $null; Hi = $null; Max = 100 } }
    }
}

function Get-RptMarkFor {
    <#
      按值和参考范围算标记。
        在范围内            -> ''      （不标色、不加粗，和别的行一样）
        超出 / 低于         -> '↑' '↓'
        超出上限 10% 以上   -> '↑↑'    （显著异常）
        读不到              -> '—'
    #>
    param($Value, $Range)
    if ($null -eq $Value) { return '—' }
    if ($null -ne $Range.Hi -and $Value -gt $Range.Hi) {
        if ($Value -gt ($Range.Hi * 1.1)) { return '↑↑' }
        return '↑'
    }
    if ($null -ne $Range.Lo -and $Value -lt $Range.Lo) {
        if ($Value -lt ($Range.Lo * 0.5)) { return '↓↓' }
        return '↓'
    }
    return ''
}

function Build-DashUI {
    <#
      概览页 = 卡片网格（design.md 5.1）。
        第一行  主角卡（健康度，Update-DashScore 画）+ 处理器温度 + 显卡温度
        第二行  内存占用 + 系统盘可用 + 实时占用
        第三行  检验结论（宽）+ 受检类别
      读数卡的长相见 New-Gauge；读不到一律「—」，绝不编数字。
    #>
    $Script:DashRows = @{}

    $sum = $Script:UI.DashSummary
    $sum.Children.Clear()
    $sum.Children.Add((New-RptSection -Title '本次检验摘要' -Aside '实时读数，每秒刷新')) | Out-Null

    $Script:DashGauges = @{}
    $defs = @(
        @{ K = 'CpuTemp'; N = '处理器温度'; I = 'Thermometer'; C = 'DashCell1' },
        @{ K = 'GpuTemp'; N = '显卡温度'; I = 'ExpansionCard'; C = 'DashCell2' },
        @{ K = 'Ram'; N = '内存占用'; I = 'Memory'; C = 'DashCell3' },
        @{ K = 'Disk'; N = '系统盘可用'; I = 'Harddisk'; C = 'DashCell4' })
    foreach ($d in $defs) {
        $g = New-Gauge -Label $d.N -Icon $d.I
        $Script:DashGauges[$d.K] = $g
        $Script:UI[$d.C].Child = $g.Host
    }

    # 占用率这两项没有合格阈值 —— 瞬时读数某一秒 100% 不说明任何问题，
    # 画安全线就等于编一个不存在的标准。所以只报数、只画填充。
    $Script:DashPlain = @{}
    $Script:DashLoadMeters = @{}
    $Script:DashLoadLast = @{}
    $box = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    $head.Children.Add((New-Icon -Kind 'ChartLine' -Size 20 -Color 'TextDim')) | Out-Null
    $hl = New-TextBlock -Text '实时占用' -Size 12 -Color 'TextDim'
    $hl.VerticalAlignment = 'Center'
    $hl.Margin = New-Thick 8 0 0 0
    $head.Children.Add($hl) | Out-Null
    $box.Children.Add($head) | Out-Null
    $two = New-Object System.Windows.Controls.Grid
    $two.Margin = New-Thick 0 12 0 0
    foreach ($ci in 0, 1, 2) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($ci -eq 1) { New-Object System.Windows.GridLength 16 } else { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
        $two.ColumnDefinitions.Add($cd)
    }
    $col = 0
    foreach ($d in @(@{ K = 'CpuLoad'; N = '处理器占用' }, @{ K = 'GpuLoad'; N = '显卡占用' })) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $v = New-TextBlock -Text ([string][char]0x2014) -Size 28 -Bold $true
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        $row.Children.Add($v) | Out-Null
        $u = New-TextBlock -Text '%' -Size 11 -Color 'TextDim'
        $u.VerticalAlignment = 'Bottom'
        $u.Margin = New-Thick 4 0 0 8
        $row.Children.Add($u) | Out-Null
        $sp.Children.Add($row) | Out-Null
        $m = New-Meter
        $m.Host.Margin = New-Thick 0 12 0 0
        $sp.Children.Add($m.Host) | Out-Null
        $l = New-TextBlock -Text $d.N -Size 12 -Color 'TextDim'
        $l.Margin = New-Thick 0 8 0 0
        $sp.Children.Add($l) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, $col)
        $two.Children.Add($sp) | Out-Null
        $Script:DashPlain[$d.K] = $v
        $Script:DashLoadMeters[$d.K] = $m
        $col += 2
    }
    $box.Children.Add($two) | Out-Null
    $Script:UI.DashCell5.Child = $box

    # 主角卡先放一个壳，分数算出来之前显示「—」
    Build-DashHero $null

    # ---------- 按用途选（右栏）----------
    $ph = $Script:UI.DashPickHead
    $ph.Children.Clear()
    $ph.Children.Add((New-RptSection -Title '受检类别')) | Out-Null
    $hint = New-TextBlock -Size 12 -Color 'TextDim' -Wrap $true -Text (
        '选一类，下面整张表的参考范围和推荐项都会按这一类给 —— ' +
        '同一项对不同用途，合格线本来就不一样。')
    $hint.Margin = New-Thick 0 0 0 4
    $ph.Children.Add($hint) | Out-Null

    $qp = $Script:UI.DashQuickPick
    $qp.Children.Clear()
    foreach ($ps in ($Script:Presets | Where-Object { $_.Group -eq '按用途选' })) {
        $card = New-PresetCard -Preset $ps -Big $true
        $card.Add_MouseLeftButtonUp({ $Script:UI.Tabs.SelectedIndex = 1 })
        $qp.Children.Add($card) | Out-Null
    }

    # ---------- 签发区 ----------
    #   报告单右下角那一块：谁检的、什么时候、盖章。
    #   这里它同时是主操作的位置 —— 「签发」就是「应用改动」。
    $so = $Script:UI.DashSignOff
    $so.Children.Clear()
    $rule = New-Object System.Windows.Shapes.Rectangle
    $rule.Height = 1
    $rule.Fill = Get-Brush $Script:CARD_BORDER
    $rule.Margin = New-Thick 0 0 0 12
    $so.Children.Add($rule) | Out-Null
    foreach ($ln in @(
            @{ L = '检验'; V = "电脑调优助手 v$Script:AppVersion" },
            @{ L = '依据'; V = '本机原始值备份' },
            @{ L = '日期'; V = (Get-Date).ToString('yyyy-MM-dd') })) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Thick 0 0 0 4
        $cd1 = New-Object System.Windows.Controls.ColumnDefinition
        $cd1.Width = New-Object System.Windows.GridLength 44
        $cd2 = New-Object System.Windows.Controls.ColumnDefinition
        $cd2.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $g.ColumnDefinitions.Add($cd1); $g.ColumnDefinitions.Add($cd2)
        $a = New-TextBlock -Text $ln.L -Size 11 -Color 'TextDim'
        $b = New-TextBlock -Text $ln.V -Size 12 -Color 'TextMid' -Wrap $true
        [System.Windows.Controls.Grid]::SetColumn($b, 1)
        $g.Children.Add($a) | Out-Null
        $g.Children.Add($b) | Out-Null
        $so.Children.Add($g) | Out-Null
    }
}

function Build-DashHero {
    <#
      主角卡（design.md 4.8）：整张填 HeroFill、白字。全应用只有这一张。
        左边  健康度  分数（hero 44）+「分」，下面三个计数 已核对 / 合格 / 超差
        右边  圆环    分数在 0~100 里画到哪（D4：和数字共用一个时钟，一起滚、一起画满）
      $S 是 Get-DashScore 的结果；$null = 还没算出来，数字写「—」、圆环空着。
    #>
    param($S, [switch]$NoCount)
    $h = $Script:UI.DashHero
    if ($null -eq $h) { return }
    $root = New-Object System.Windows.Controls.Grid     # 外层留给光斑（C2）叠一层
    $content = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::Auto
    $content.ColumnDefinitions.Add($c0); $content.ColumnDefinitions.Add($c1)
    $sp = New-Object System.Windows.Controls.StackPanel

    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    $head.Children.Add((New-Icon -Kind 'HeartPulse' -Size 20 -Color 'OnHeroDim')) | Out-Null
    $hl = New-TextBlock -Text '健康度' -Size 12 -Color 'OnHeroDim'
    $hl.VerticalAlignment = 'Center'
    $hl.Margin = New-Thick 8 0 0 0
    $head.Children.Add($hl) | Out-Null
    $sp.Children.Add($head) | Out-Null

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Thick 0 8 0 0
    $num = New-TextBlock -Text ([string][char]0x2014) -Size 44 -Color 'OnHero' -Bold $true
    [System.Windows.Documents.Typography]::SetNumeralAlignment($num, 'Tabular')
    $row.Children.Add($num) | Out-Null
    $un = New-TextBlock -Text '分' -Size 11 -Color 'OnHeroDim'
    $un.VerticalAlignment = 'Bottom'
    $un.Margin = New-Thick 4 0 0 12
    $row.Children.Add($un) | Out-Null
    $sp.Children.Add($row) | Out-Null
    $Script:DashHeroValue = $num

    $total = @($Script:Tweaks).Count
    $bad = if ($S) { @($S.Items).Count } else { $null }
    $tally = New-Object System.Windows.Controls.Grid
    $tally.Margin = New-Thick 0 16 0 0
    foreach ($ci in 0..2) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $tally.ColumnDefinitions.Add($cd)
    }
    $dash = [string][char]0x2014
    $cells = @(
        @{ L = '已核对'; V = "$total" },
        @{ L = '合格'; V = $(if ($null -ne $bad) { "$([math]::Max(0, $total - $bad))" } else { $dash }) },
        @{ L = '超差'; V = $(if ($null -ne $bad) { "$bad" } else { $dash }) })
    $ci = 0
    foreach ($c in $cells) {
        $cs = New-Object System.Windows.Controls.StackPanel
        $v = New-TextBlock -Text $c.V -Size 16 -Color 'OnHero' -Bold $true
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        $cs.Children.Add($v) | Out-Null
        $l = New-TextBlock -Text $c.L -Size 11 -Color 'OnHeroDim'
        $l.Margin = New-Thick 0 4 0 0
        $cs.Children.Add($l) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($cs, $ci)
        $tally.Children.Add($cs) | Out-Null
        $ci++
    }
    $sp.Children.Add($tally) | Out-Null
    $content.Children.Add($sp) | Out-Null

    # ---- 圆环（D4）----
    #   直径 88、线宽 8：半径 40，周长 251.3px。StrokeDashArray 按线宽计单位 → 一整圈 = 31.4 单位
    #   StrokeDashOffset 从 31.4（空）走到 31.4 × (1 - 分数/100)。从 12 点钟方向顺时针画。
    $ring = New-Object System.Windows.Controls.Grid
    $ring.Width = 88; $ring.Height = 88
    $ring.VerticalAlignment = 'Center'
    $ring.Margin = New-Thick 16 0 0 0
    [System.Windows.Controls.Grid]::SetColumn($ring, 1)
    $track = New-Object System.Windows.Shapes.Ellipse
    $track.Stroke = Get-Brush 'OnHeroTrack'
    $track.StrokeThickness = 8
    $ring.Children.Add($track) | Out-Null
    $arc = New-Object System.Windows.Shapes.Ellipse
    $arc.Stroke = Get-Brush 'OnHero'
    $arc.StrokeThickness = 8
    $arc.StrokeDashCap = 'Flat'
    $Script:HeroRingLen = [math]::PI * (88 - 8) / 8
    $dc = New-Object System.Windows.Media.DoubleCollection
    $dc.Add($Script:HeroRingLen); $dc.Add($Script:HeroRingLen)
    $arc.StrokeDashArray = $dc
    $arc.StrokeDashOffset = $Script:HeroRingLen
    $arc.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $arc.RenderTransform = New-Object System.Windows.Media.RotateTransform -90
    $ring.Children.Add($arc) | Out-Null
    $content.Children.Add($ring) | Out-Null
    $Script:HeroArc = $arc

    $root.Children.Add($content) | Out-Null

    # ---- 光斑（C2）：一团白色 14% 的径向光跟着鼠标 ----
    #   全应用只放这一处（design.md 5.3）。铺满整张卡（负边距盖住内边距），不吃点击。
    #   平时透明度 0；鼠标进来 200ms 淡入、出去 200ms 淡出。
    #   ★ 没有计时器 ★ 只在鼠标动的时候改一下圆心 —— 鼠标不在卡上时零开销。
    $spot = New-Object System.Windows.Controls.Border
    $spot.Margin = New-Thick -24
    $spot.CornerRadius = New-Corner 12
    $spot.IsHitTestVisible = $false
    $spot.Opacity = 0
    $rb = New-Object System.Windows.Media.RadialGradientBrush
    $rb.MappingMode = 'Absolute'
    $rb.RadiusX = 180; $rb.RadiusY = 180
    $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(36, 255, 255, 255)), 0.0))
    $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255)), 1.0))
    $spot.Background = $rb
    $root.Children.Add($spot) | Out-Null
    $Script:HeroSpot = @{ Layer = $spot; Brush = $rb }

    $h.Child = $root
    $Script:HeroRoot = $root
    if (-not $Script:HeroSpotHooked) {
        # 卡片本身（DashHero）是 XAML 里的常驻元素，事件只挂一次；光斑层随卡片内容重建，走 $Script:HeroSpot
        $Script:HeroSpotHooked = $true
        $h.Add_MouseEnter({ if ($Script:HeroSpot) { Start-Fade $Script:HeroSpot.Layer 1 $Script:Dur.Base } })
        $h.Add_MouseLeave({ if ($Script:HeroSpot) { Start-Fade $Script:HeroSpot.Layer 0 $Script:Dur.Base } })
        $h.Add_MouseMove({
                param($sender, $e)
                if ($null -eq $Script:HeroSpot) { return }
                $pt = $e.GetPosition($Script:HeroSpot.Layer)
                # 直接赋值不加缓动：指针本身就在动，再给圆心加缓动，光斑会拖在手后面
                $Script:HeroSpot.Brush.Center = $pt
                $Script:HeroSpot.Brush.GradientOrigin = $pt
            })
    }
    if ($S -and $NoCount) { $num.Text = "$([int]$S.Score)"; Set-HeroRing ([double]$S.Score) }
    elseif ($S) { Start-HeroScore 0 }
}

function Set-HeroRing {
    param([double]$Value)
    if ($null -eq $Script:HeroArc) { return }
    $v = [math]::Max(0, [math]::Min(100, $Value))
    $Script:HeroArc.StrokeDashOffset = $Script:HeroRingLen * (1 - $v / 100)
}

function Start-HeroScore {
    <#
      健康度数字从 0 滚到分数、圆环同步画满（D4，Count 900ms ease-out）。
      DelayMs：切到概览页时等区块依次进场落位再开始 —— 同一时刻只有一个主角在动（design.md 5.3）。
      可打断：再次调用会掐掉上一次的等待和滚动，从 0 重来。
    #>
    param([double]$DelayMs = 0)
    $s = $Script:DashScoreCache
    if ($null -eq $s -or $null -eq $Script:DashHeroValue) { return }
    try { if ($Script:HeroDelay) { $Script:HeroDelay.Stop() } } catch { }
    try { if ($Script:DashHeroValue.Tag -is [System.Windows.Threading.DispatcherTimer]) { $Script:DashHeroValue.Tag.Stop() } } catch { }
    if (-not (Test-AnimOn)) {
        $Script:DashHeroValue.Text = "$([int]$s.Score)"
        Set-HeroRing ([double]$s.Score)
        return
    }
    $Script:DashHeroValue.Text = '0'
    Set-HeroRing 0
    $go = {
        Start-CountUp -Target $Script:DashHeroValue -To ([double]$Script:DashScoreCache.Score) -Decimals 0 -Ms $Script:Dur.Count -From 0 -OnFrame { param($v) Set-HeroRing $v }
    }
    if ($DelayMs -le 0) { & $go; return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($DelayMs)
    $t.Tag = $go
    $t.Add_Tick({ $this.Stop(); & $this.Tag })
    $Script:HeroDelay = $t
    $t.Start()
}

function Update-DashScore {
    <#
      健康度 + 检验结论。
        主角卡：分数和三个计数
        结论卡：每一条扣分写清楚扣在哪、扣了几分、为什么 ——
                「一键体检 98 分」那种黑箱分数是先吓人再卖服务，这里每一分都摊开
    #>
    #  v6.2：算分要读注册表、启动项、查系统盘是不是固态，实测 370ms —— 挪到后台。
    #  温度那一项用传感器线的现成读数，所以要等第一份读数到了再算（Start-DashTimer 里接力）。
    param([switch]$Redraw)
    if ($Redraw -and $Script:DashScoreCache) { Show-DashScore $Script:DashScoreCache $false; return }
    if ($Script:DashScoreBusy) { return }
    $Script:DashScoreBusy = $true
    Start-BgWork 'score' { param($snap) Get-DashScore -Snap $snap } -Arg $Script:Sensor.Snap -OnDone {
        param($s)
        $Script:DashScoreBusy = $false
        if ($null -eq $s) { return }
        $Script:DashScoreCache = $s
        Show-DashScore $s $true
    }
}

function Show-DashScore {
    param($s, [bool]$Animate)
    Build-DashHero $s -NoCount:(-not $Animate)

    $box = $Script:UI.DashVerdict
    $box.Children.Clear()
    $box.Children.Add((New-RptSection -Title '检验结论' -Icon 'ClipboardCheckOutline')) | Out-Null

    $bad = @($s.Items).Count
    if ($bad -gt 0) {
        $nh = New-TextBlock -Text '备注' -Size 11 -Color 'TextDim'
        $nh.Margin = New-Thick 0 0 0 8
        $box.Children.Add($nh) | Out-Null
        $i = 0
        foreach ($it in $s.Items) {
            $i++
            $b = New-Object System.Windows.Controls.Border
            $b.Padding = New-Thick 0 12 0 12
            $b.BorderBrush = Get-Brush 'Stroke'
            $b.BorderThickness = $(if ($i -lt $bad) { New-Thick 0 0 0 1 } else { New-Thick 0 })
            $g = New-Object System.Windows.Controls.Grid
            foreach ($w in @(24.0, 0.0, 64.0)) {
                $cd = New-Object System.Windows.Controls.ColumnDefinition
                $cd.Width = if ($w -eq 0) { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength $w }
                $g.ColumnDefinitions.Add($cd)
            }
            $mk = New-TextBlock -Text '↑' -Size 14 -Color '#8A5750' -Bold $true
            $g.Children.Add($mk) | Out-Null

            $sp = New-Object System.Windows.Controls.StackPanel
            [System.Windows.Controls.Grid]::SetColumn($sp, 1)
            $t1 = New-TextBlock -Text $it.Name -Size 14 -Wrap $true -Bold $true
            $sp.Children.Add($t1) | Out-Null
            $t2 = New-TextBlock -Text $it.Why -Size 12 -Color 'TextDim' -Wrap $true
            $t2.Margin = New-Thick 0 4 0 0
            $sp.Children.Add($t2) | Out-Null
            $g.Children.Add($sp) | Out-Null

            $mn = New-TextBlock -Text ("−{0} 分" -f $it.Minus) -Size 12 -Color '#8A5750'
            $mn.TextAlignment = 'Right'
            [System.Windows.Documents.Typography]::SetNumeralAlignment($mn, 'Tabular')
            [System.Windows.Controls.Grid]::SetColumn($mn, 2)
            $g.Children.Add($mn) | Out-Null
            $b.Child = $g
            $box.Children.Add($b) | Out-Null
        }
    } else {
        $t = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text '全部项目在参考范围内，没有需要处理的。'
        $box.Children.Add($t) | Out-Null
    }
}

function Set-RptReading {
    <#
      刷一行读数：写值、按参考范围算标记、同步区间条、变了就闪一下。
      读不到一律显示长横，连刻记都不画 —— 和「绝不编数字」一个道理，
      不画一个假的位置出来。

      Max 给 0 就用该指标的默认满量程；系统盘传这块盘的实际容量。
    #>
    param([string]$Key, $Value, [int]$Decimals = 0, [double]$Max = 0)
    $row = $Script:DashRows[$Key]
    if ($null -eq $row) { return }
    $rg = Get-RptRange $Key
    $dash = [string][char]0x2014

    if ($null -eq $Value) {
        $row.Result.Text = $dash
        Set-RptMark $row $dash
        Set-RangeBar $row.Bar $null $rg.Max $rg.Lo $rg.Hi
        return
    }

    $fmt = if ($Decimals -gt 0) { "F$Decimals" } else { 'F0' }
    $old = "$($row.Result.Text)" -replace '[^\d.\-]', ''
    $changed = $true
    if ($old -and [double]::TryParse($old, [ref]$null)) {
        $changed = ([math]::Round([double]$old, $Decimals) -ne [math]::Round([double]$Value, $Decimals))
    }

    $mark = Get-RptMarkFor ([double]$Value) $rg
    Start-CountUp -Target $row.Result -To ([double]$Value) -Decimals $Decimals -Ms $Script:Dur.Draw
    Set-RptMark $row $mark

    # 区间条跟着走。超出范围时刻记上法定墨并且画高一点 ——
    # 「超了」这件事同时被数字、标记、刻记三处表达，
    # 用户扫表时可能只看见其中任何一处。
    $useMax = if ($Max -gt 0) { $Max } else { $rg.Max }
    $abnormal = ($mark -eq [string][char]0x2191 -or $mark -eq [string][char]0x2193 -or
                 $mark -eq ([string][char]0x2191 + [char]0x2191) -or $mark -eq ([string][char]0x2193 + [char]0x2193))
    Set-RangeBar $row.Bar ([double]$Value) $useMax $rg.Lo $rg.Hi $abnormal

    if ($changed) { Start-ValueFlash $row.Result }
}

function Update-DashUI {
    <# 每秒刷一次仪表。这里绝不做耗时的事 #>
    if (-not $Script:DashGauges -or $Script:DashGauges.Count -eq 0) { return }
    $snap = $Script:Sensor.Snap
    if ($null -eq $snap) { return }       # 传感器线还在初始化（首次约 3~7 秒），读数卡先显示「—」

    $c = $snap.C
    $rg = Get-RptRange 'CpuTemp'
    Set-Gauge $Script:DashGauges['CpuTemp'] $c.Temp $rg.Max $rg.Lo $rg.Hi 0 '°C' $(
        if ($null -eq $c.Temp) { $(if ($Script:IsAdmin -and $Script:Sensor.LhmReady) { '这台机器不报告' } else { '读不到（需管理员权限）' }) } else { '合格 ' + $rg.Text + ' °C' })

    $g = $snap.G
    $rg = Get-RptRange 'GpuTemp'
    $gsub = if ($g.Name) { ($g.Name -replace 'NVIDIA GeForce |AMD |\(TM\)| Laptop GPU', '') } else { '没检测到显卡' }
    Set-Gauge $Script:DashGauges['GpuTemp'] $g.Temp $rg.Max $rg.Lo $rg.Hi 0 '°C' $gsub

    $r = $snap.R
    $rg = Get-RptRange 'Ram'
    if ($r) {
        Set-Gauge $Script:DashGauges['Ram'] $r.Percent $rg.Max $rg.Lo $rg.Hi 0 '%' (
            "已用 $($r.UsedGB) / 共 $($r.TotalGB) GB")
    }

    $d = $snap.D
    if ($d) {
        # 系统盘的满量程就是这块盘的实际容量 —— 用 100 当量程是错的
        Set-Gauge $Script:DashGauges['Disk'] $d.FreeGB ([double]$d.TotalGB) 20 $null 1 'GB' (
            "$($d.Drive) 共 $($d.TotalGB) GB，已用 $($d.UsedPct)%")
    }

    # 占用率：没有合格阈值，只报数、只画填充，不画安全线
    foreach ($p in @(@{ K = 'CpuLoad'; V = $c.Load }, @{ K = 'GpuLoad'; V = $g.Load })) {
        $t = $Script:DashPlain[$p.K]
        if ($null -eq $t) { continue }
        if ($Script:DashLoadLast[$p.K] -eq "$($p.V)") { continue }
        $Script:DashLoadLast[$p.K] = "$($p.V)"
        Set-Meter $Script:DashLoadMeters[$p.K] $p.V 100 $null
        if ($null -eq $p.V) { $t.Text = [string][char]0x2014; continue }
        Start-CountUp -Target $t -To ([double]$p.V) -Decimals 0 -Ms $Script:Dur.Draw
    }
}

function New-PresetCard {
    <#
      一个「受检类别」（使用场景预设）选项。返回 Border，Tag 挂着预设对象。

      圆角 8 的一行：单选图标 + 名称（+ 一行说明）。
        未选  RadioboxBlank，TextDim
        选中  RadioboxMarked + 名称都换 Accent，整行铺 AccentTint —— 选中态是强调色的三个合法去处之一
      Compact = 性能优化页顶上那一排：横着排、不带说明（点选后右栏有完整说明）。
    #>
    param($Preset, [bool]$Big = $false, [bool]$Compact = $false)

    $row = New-Object System.Windows.Controls.Border
    $row.Background = [System.Windows.Media.Brushes]::Transparent
    $row.CornerRadius = New-Corner 8
    # 描边平时透明、选中时换强调色（C4）。先占好 1.5px，选中时不挤动布局
    $row.BorderThickness = New-Thick 1.5
    $row.BorderBrush = [System.Windows.Media.Brushes]::Transparent
    $row.Padding = $(if ($Compact) { New-Thick 8 4 12 4 } else { New-Thick 8 8 8 8 })
    $row.Margin = $(if ($Compact) { New-Thick 0 0 4 0 } else { New-Thick 0 0 0 4 })
    $row.Cursor = 'Hand'
    $row.Tag = $Preset

    $g = New-Object System.Windows.Controls.Grid
    $cdA = New-Object System.Windows.Controls.ColumnDefinition
    $cdA.Width = New-Object System.Windows.GridLength 28
    $cdB = New-Object System.Windows.Controls.ColumnDefinition
    $cdB.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions.Add($cdA); $g.ColumnDefinitions.Add($cdB)

    $mark = New-Icon -Kind 'RadioboxBlank' -Size 20 -Color 'TextDim'
    $mark.HorizontalAlignment = 'Left'
    $mark.VerticalAlignment = $(if ($Compact) { 'Center' } else { 'Top' })
    $g.Children.Add($mark) | Out-Null

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    $title = New-TextBlock -Text $Preset.Name -Size $(if ($Compact) { 13 } else { 14 }) -Wrap (-not $Compact) -Bold $true
    $title.VerticalAlignment = 'Center'
    $sp.Children.Add($title) | Out-Null
    $subText = $Script:PresetSubtitle["$($Preset.Id)"]
    if ($subText -and -not $Compact) {
        $sub = New-TextBlock -Text $subText -Size 12 -Color 'TextDim' -Wrap $true
        $sub.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($sub) | Out-Null
    }
    $g.Children.Add($sp) | Out-Null

    # 右上角的对勾徽章（C4）：选中时从 0.6 弹到 1，勾在 120ms 后一笔画出
    $badge = New-CheckBadge
    $outer = New-Object System.Windows.Controls.Grid
    $outer.Children.Add($g) | Out-Null
    $outer.Children.Add($badge.Host) | Out-Null
    $row.Child = $outer

    $row.Resources['__preset'] = @{ Mark = $mark; Title = $title; Badge = $badge }
    Add-Interactive $row -BgNormal 'Transparent' -BgHover $Script:CARD_HOVER

    # ★ 按下的瞬间就把记号打上，不等松手 ★ —— 回答「我点上了吗」
    $row.Add_PreviewMouseLeftButtonDown({
            try {
                $m = $this.Resources['__preset']
                $m.Mark.Kind = 'RadioboxMarked'
                $m.Mark.Foreground = Get-Brush 'Accent'
            } catch { }
        })
    $row.Add_MouseLeftButtonUp({
            Select-PresetCard $this
            Select-Preset $this.Tag
        })
    return $row
}

function Select-PresetCard {
    <# 切换选中的预设：选中行 AccentTint 底 + 实心单选 + 名称 Accent；上一行恢复 #>
    param($Card)
    if ($Script:SelectedPresetCard -and $Script:SelectedPresetCard -ne $Card) {
        $old = $Script:SelectedPresetCard
        try {
            $m = $old.Resources['__preset']
            $m.Mark.Kind = 'RadioboxBlank'
            $m.Mark.Foreground = Get-Brush 'TextDim'
            $m.Title.Foreground = Get-Brush 'TextMain'
            $old.Background = [System.Windows.Media.Brushes]::Transparent
            $old.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            Set-CheckBadge $m.Badge $false
        } catch { }
    }
    $Script:SelectedPresetCard = $Card
    if ($null -eq $Card) { return }
    try {
        $m = $Card.Resources['__preset']
        $m.Mark.Kind = 'RadioboxMarked'
        $m.Mark.Foreground = Get-Brush 'Accent'
        $m.Title.Foreground = Get-Brush 'Accent'
        $Card.Background = Get-Brush 'AccentTint'
        $Card.BorderBrush = Get-Brush 'Accent'
        Set-CheckBadge $m.Badge $true
    } catch { }
}

function Build-PresetUI {
    <#
      顶部的预设选择区。按分组竖着排，每组一行标题 + 一片卡片。

      v4.1 之前这里是一排排小方块按钮 —— 字小、挤成一团、没有层次，
      是整个界面最廉价的地方。现在换成卡片（见 New-PresetCard）。
    #>
    $bar = $Script:UI.PresetBar          # 收起来的那些组
    $primary = $Script:UI.PresetPrimary  # 常驻露出来的第一组
    $bar.Children.Clear()
    $primary.Children.Clear()
    $Script:PresetCardList = New-Object System.Collections.ArrayList
    $Script:SelectedPresetCard = $null

    # 分组顺序写死，不跟着定义顺序走。
    #
    # ★ 「按用途选」必须排第一 ★
    #   v3.0 之前第一排是五个 FPS 预设，不玩 FPS 的人打开工具，
    #   第一眼全是跟自己无关的东西，会直接觉得「这工具不是给我用的」。
    $groupOrder = @('按用途选', '竞技射击', '浏览器瘦身')
    $groups = @()
    foreach ($g in $groupOrder) {
        if ($Script:Presets | Where-Object { $_.Group -eq $g }) { $groups += $g }
    }
    foreach ($ps in $Script:Presets) { if ($groups -notcontains $ps.Group) { $groups += $ps.Group } }

    $groupHint = @{
        '按用途选'   = '点一下自动勾好，先找到你自己属于哪一类'
        '竞技射击'   = '只玩 FPS 的话用这一排'
        '浏览器瘦身' = '按代价从小到大三档'
    }

    $gi = -1
    foreach ($grp in $groups) {
        $gi++
        # 第一组（按用途选）放常驻区，其余放可展开区
        $slot = if ($gi -eq 0) { $primary } else { $bar }

        # 组标题
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        # 组名前不再画彩色竖条 —— 语义色只表示状态，不当装饰（design.md 1.2）
        $head.Margin = New-Thick 8 $(if ($slot.Children.Count -eq 0) { 0 } else { 12 }) 0 8
        $ht = New-TextBlock -Text $grp -Size 13 -Bold $true
        $ht.VerticalAlignment = 'Center'
        $head.Children.Add($ht) | Out-Null
        if ($groupHint[$grp]) {
            $hh = New-TextBlock -Text $groupHint[$grp] -Size 11 -Color 'TextDim'
            $hh.VerticalAlignment = 'Center'
            $hh.Margin = New-Thick 12 0 0 0
            $head.Children.Add($hh) | Out-Null
        }
        # 第一组的组标题已经写死在 XAML 那一行里，这里不再重复画
        if ($gi -ne 0) { $slot.Children.Add($head) | Out-Null }

        # 卡片区。用 WrapPanel 自动换行 ——
        # 它的父级是竖向 StackPanel，宽度是实际宽度，能正常换行。
        # ★ 常驻的第一组走紧凑模式 ★
        #   这一页的主角是下面那 55 个优化项（老板定位：鼓励用户自己手动调整）。
        #   预设区原来占 200px、内容区的三分之一，把列表挤得只剩 3 行 ——
        #   主次完全颠倒。紧凑模式一行四个，压到约 48px。
        $compact = ($gi -eq 0)
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($ps in ($Script:Presets | Where-Object { $_.Group -eq $grp })) {
            $card = New-PresetCard -Preset $ps -Compact $compact
            [void]$Script:PresetCardList.Add($card)
            $wrap.Children.Add($card) | Out-Null
        }
        $slot.Children.Add($wrap) | Out-Null
    }
}

function Set-PresetExpanded {
    <# 展开 / 收起「竞技射击 + 浏览器瘦身」那两组。「按用途选」永远露着。 #>
    param([bool]$On)
    $Script:PresetExpanded = $On
    $Script:UI.PresetBody.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    $Script:UI.PresetToggle.Text = if ($On) { '收起' } else { '展开' }
    $Script:UI.PresetMoreHint.Text = if ($On) { '收起' } else { '更多' }
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
    # 选完就把展开的那两组收回去 —— 选择已经做完了，
    # 接下来要看的是下面那个列表，别再占着地方
    $Script:LastPresetName = "$($Preset.Name)"
    if ($Script:PresetExpanded) { Set-PresetExpanded $false }
    Set-Status ("已按「{0}」勾选 {1} 项 —— 确认右边说明后，点下面的「应用选中的优化」" -f $Preset.Name, $n)
}

function Show-PresetDetail {
    param($Preset, [int]$Count)
    $p = $Script:UI.TweakDetail
    $p.Children.Clear()
    Start-FadeSlideIn $p   # 换内容时淡入 + 轻微上移，避免「啪」地一下跳变

    $p.Children.Add((New-TextBlock -Text $Preset.Name -Size 16 -Bold $true -Wrap $true)) | Out-Null

    $sub = New-TextBlock -Text ("共勾选 {0} 项 · 这只是勾选，还没有应用" -f $Count) -Size 12 -Color '#7A6B45'
    $sub.Margin = New-Thick 0 8 0 12
    $p.Children.Add($sub) | Out-Null

    $p.Children.Add((New-TextBlock -Text (Format-Reflow $Preset.Desc) -Size 13 -Color 'TextMid' -Wrap $true)) | Out-Null

    # 兼容性提醒
    $warn = @(Get-SelectionWarnings -TweakIds $Preset.Ids)
    if ($warn.Count -gt 0) {
        # 状态提示：语义底（卡其）+ 语义图标，圆角 8，不再用 3px 彩色左边条
        $wc = New-Object System.Windows.Controls.Border
        $wc.Background = Get-Brush '#EDE7D9'
        $wc.CornerRadius = New-Corner 8
        $wc.Padding = New-Thick 16 12 16 12
        $wc.Margin = New-Thick 0 16 0 0
        $wsp = New-Object System.Windows.Controls.StackPanel
        $wh = New-Object System.Windows.Controls.StackPanel
        $wh.Orientation = 'Horizontal'
        $wh.Children.Add((New-Icon -Kind 'AlertOutline' -Size 18 -Color '#7A6B45')) | Out-Null
        $wt = New-TextBlock -Text '兼容性提醒' -Size 13 -Bold $true -Color '#7A6B45'
        $wt.Margin = New-Thick 8 0 0 0
        $wt.VerticalAlignment = 'Center'
        $wh.Children.Add($wt) | Out-Null
        $wsp.Children.Add($wh) | Out-Null
        foreach ($w in $warn) {
            $t = New-TextBlock -Text $w -Size 12 -Color 'TextMid' -Wrap $true
            $t.Margin = New-Thick 0 8 0 0
            $wsp.Children.Add($t) | Out-Null
        }
        $wc.Child = $wsp
        $p.Children.Add($wc) | Out-Null
    }

    # 这个预设包含哪些项目
    $lt = New-TextBlock -Text '包含的项目（点左边任意一项可以看它的详细说明）' -Size 13 -Bold $true
    $lt.Margin = New-Thick 0 20 0 8
    $p.Children.Add($lt) | Out-Null
    foreach ($id in $Preset.Ids) {
        $tw = $Script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $tw) { continue }
        $t = New-TextBlock -Text ("· " + $tw.Name) -Size 12 -Color 'TextMid' -Wrap $true
        $t.Margin = New-Thick 0 0 0 4
        $p.Children.Add($t) | Out-Null
    }
}

function Show-TweakDetail {
    param($Tweak)
    $p = $Script:UI.TweakDetail
    $p.Children.Clear()
    Start-FadeSlideIn $p   # 换内容时淡入 + 轻微上移，避免「啪」地一下跳变
    if ($Tweak -and $Script:TweakRows[$Tweak.Id]) { Select-Card $Script:TweakRows[$Tweak.Id].Card } else { Select-Card $null }
    if (-not $Tweak) {
        $p.Children.Add((New-RptSection -Title '怎么用这一页' -Icon 'LightbulbOnOutline')) | Out-Null
        $tip = New-TextBlock -Wrap $true -Size 13 -Color 'TextMid' -Text @'

最省事的办法：在上面「**按用途选**」那一排里，点你自己属于的那类。

· **大型单机 3A** —— 黑神话、艾尔登法环这类，要的是不卡顿、读图快
· **网游 / 挂机 / 多开** —— 重点在网络延迟和后台别抢带宽
· **不玩游戏** —— 办公上网刷视频，只想电脑别这么卡
· **老机器救急** —— 配置吃紧、内存小、机械盘

只玩竞技射击的，用下面「竞技射击」那一排。

点完会自动勾好对应的项目，然后点左下角「应用选中的优化」。

想自己挑，就点左边任意一项 —— 这里会显示：
· 这一项是干什么的、原理是什么
· **对八种使用场景分别有什么影响**（同一项对不同人结论经常是相反的）
· 代价和风险是什么、出问题怎么还原

两条设计原则：
1. 所有预设都只做「**对这类人不吃亏**」的事。可能让某种场景变差的项，
   一律不放进预设，只留给你自己单独测。
2. 涉及安全性的「激进优化」**不进任何预设**，必须你自己看完代价再勾。
'@
        $p.Children.Add($tip) | Out-Null
        return
    }

    $p.Children.Add((New-TextBlock -Text $Tweak.Name -Size 16 -Bold $true -Wrap $true)) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = New-Thick 0 12 0 12
    $rc = Get-RiskColors $Tweak.Risk
    $wrap.Children.Add((New-Badge -Text $Tweak.Category -Fg 'TextDim' -Bg 'SurfaceSunken')) | Out-Null
    $wrap.Children.Add((New-Badge -Text ("风险 " + $Tweak.Risk) -Fg $rc.Fg -Bg $rc.Bg)) | Out-Null
    if ($Tweak.Reboot) { $wrap.Children.Add((New-Badge -Text '需要重启生效' -Fg '#7A6B45' -Bg '#EDE7D9')) | Out-Null }
    if ($Tweak.Recommended) { $wrap.Children.Add((New-Badge -Text '推荐' -Fg 'TextMid' -Bg 'SurfaceSunken')) | Out-Null }
    $p.Children.Add($wrap) | Out-Null

    $p.Children.Add((New-TextBlock -Text ("预期效果：" + $Tweak.Effect) -Size 13 -Color 'TextMid' -Wrap $true)) | Out-Null

    # ---- 对各类使用场景的影响 ----
    #
    # v3.0 之前这里只讲「对三个 FPS 游戏的影响」，不玩 FPS 的人
    # 每一项都看到一堆跟自己无关的内容。现在覆盖八种使用场景。
    #
    # 八张卡全平铺会很长，所以分两层：
    #   第一层「一眼看懂」—— 按结论等级把场景名归拢成几行，扫一眼就知道
    #   第二层  详细卡片  —— 结论和理由都相同的场景自动合并成一张
    $gt = New-TextBlock -Text '这一项对各类使用场景意味着什么' -Size 13 -Bold $true
    $gt.Margin = New-Thick 0 24 0 12
    $p.Children.Add($gt) | Out-Null

    $merged = @(Get-MergedVerdicts -Notes $Script:GameNotes -TweakId $Tweak.Id)

    # ---- 第一层：结论汇总 ----
    # 按「必做 > 推荐 > 需实测 > 慎用 > 中性」排序，同一结论的场景并成一行。
    $order = @{ '必做' = 0; '推荐' = 1; '需实测' = 2; '慎用' = 3; '中性' = 4 }
    $byVerdict = [ordered]@{}
    foreach ($m in $merged) {
        if (-not $byVerdict.Contains($m.V)) { $byVerdict[$m.V] = New-Object System.Collections.ArrayList }
        foreach ($nm in $m.Names) { [void]$byVerdict[$m.V].Add($nm) }
    }
    $sumBox = New-Object System.Windows.Controls.Border
    $sumBox.Background = Get-Brush 'SurfaceAlt'
    $sumBox.CornerRadius = New-Corner 8
    $sumBox.Padding = New-Thick 12 12 12 8
    $sumBox.Margin = New-Thick 0 0 0 12
    $sumSp = New-Object System.Windows.Controls.StackPanel
    foreach ($vk in ($byVerdict.Keys | Sort-Object { $order["$_"] })) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Thick 0 0 0 4
        $vcol = Get-VerdictColor $vk
        $b = New-Badge -Text $vk -Fg $vcol -Bg (Get-TintBg $vcol)
        $b.Margin = New-Thick 0 0 8 0
        $row.Children.Add($b) | Out-Null
        $names = New-TextBlock -Text (($byVerdict[$vk]) -join ' · ') -Size 12 -Color 'TextMid' -Wrap $true
        $names.VerticalAlignment = 'Center'
        $row.Children.Add($names) | Out-Null
        $sumSp.Children.Add($row) | Out-Null
    }
    $sumBox.Child = $sumSp
    $p.Children.Add($sumBox) | Out-Null

    # ---- 第二层：逐条理由 ----
    foreach ($m in $merged) {
        $col = Get-VerdictColor $m.V

        # 逐条理由：灰底圆角块，结论用徽章表达 —— 不再用 3px 彩色左边条
        $gc = New-Object System.Windows.Controls.Border
        $gc.Background = Get-Brush 'SurfaceAlt'
        $gc.CornerRadius = New-Corner 8
        $gc.Padding = New-Thick 12 12 12 12
        $gc.Margin = New-Thick 0 0 0 8

        $gsp = New-Object System.Windows.Controls.StackPanel
        $hdr = New-Object System.Windows.Controls.WrapPanel
        $vb = New-Badge -Text $m.V -Fg $col -Bg (Get-TintBg $col)
        $hdr.Children.Add($vb) | Out-Null
        $gname = New-TextBlock -Text (($m.Names) -join ' / ') -Size 13 -Bold $true -Wrap $true
        $gname.VerticalAlignment = 'Center'
        $hdr.Children.Add($gname) | Out-Null
        $gsp.Children.Add($hdr) | Out-Null

        $gn = New-TextBlock -Text $m.N -Size 12 -Color 'TextMid' -Wrap $true
        $gn.Margin = New-Thick 0 4 0 0
        $gsp.Children.Add($gn) | Out-Null

        $gc.Child = $gsp
        $p.Children.Add($gc) | Out-Null
    }

    $sep = New-Object System.Windows.Controls.Border
    $sep.Height = 1; $sep.Background = Get-Brush 'Stroke'; $sep.Margin = New-Thick 0 16 0 16
    $p.Children.Add($sep) | Out-Null

    $p.Children.Add((New-TextBlock -Text (Format-Reflow $Tweak.Detail) -Size 13 -Color 'TextMid' -Wrap $true)) | Out-Null

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = New-Thick 0 20 0 0
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

function Invoke-JumpToCategory {
    <#
      跳到某一组优化项（v6.2，给「激进优化」入口用）：
      清掉搜索（不然那一组可能被筛掉了）、展开那一组、平滑滚过去、分组标题闪一下底色。
      滚动走「屏幕内来回移动」那条 InOut 曲线，时长 Draw（design.md 5.3）。
    #>
    param([string]$Cat)
    $h = $Script:TweakCatHeaders[$Cat]
    if (-not $h) { return }
    if ($Script:UI.TweakSearch.Text) { $Script:UI.TweakSearch.Text = '' }
    if ($Script:TweakCatCollapsed[$Cat]) {
        $Script:TweakCatCollapsed[$Cat] = $false
        $h.Arrow.Kind = 'ChevronDown'
    }
    Update-TweakFilter
    $Script:UI.TweakPanel.UpdateLayout()
    $sv = $Script:UI.TweakPanel.Parent
    if ($sv -isnot [System.Windows.Controls.ScrollViewer]) { return }
    $to = [math]::Min($sv.ScrollableHeight, $h.Border.TranslatePoint((New-Object System.Windows.Point 0, 0), $Script:UI.TweakPanel).Y)
    $from = $sv.VerticalOffset
    if (-not (Test-MotionOn)) { $sv.ScrollToVerticalOffset($to) }
    else {
        try { if ($Script:JumpTimer) { $Script:JumpTimer.Stop() } } catch { }
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(16)
        $t.Tag = @{ SV = $sv; From = $from; To = $to; Sw = [Diagnostics.Stopwatch]::StartNew(); Sp = (New-Spline $Script:Ease.InOut); Ms = [double]$Script:Dur.Draw }
        $t.Add_Tick({
                $st = $this.Tag
                $p = [math]::Min(1.0, $st.Sw.Elapsed.TotalMilliseconds / $st.Ms)
                $st.SV.ScrollToVerticalOffset($st.From + ($st.To - $st.From) * $st.Sp.GetSplineProgress($p))
                if ($p -ge 1) { $this.Stop() }
            })
        $Script:JumpTimer = $t
        $t.Start()
    }
    # 标题闪一下：淡入选中底色，停一会儿再退回去 —— 告诉人「就是这一组」
    Start-ColorFade $h.Border 'AccentTint' $Script:Dur.Base
    $bt = New-Object System.Windows.Threading.DispatcherTimer
    $bt.Interval = [TimeSpan]::FromMilliseconds($Script:Dur.Done)
    $bt.Tag = $h.Border
    $bt.Add_Tick({ $this.Stop(); Start-ColorFade $this.Tag 'Transparent' $Script:Dur.Base })
    $bt.Start()
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
        $hb.Padding = New-Thick 8 8 8 8
        $hb.Margin = New-Thick 0 $(if ($panel.Children.Count -eq 0) { 0 } else { 12 }) 0 4
        $hb.CornerRadius = New-Corner 8
        $hb.Background = Get-Brush 'Transparent'
        $hb.Cursor = 'Hand'
        $hrow = New-Object System.Windows.Controls.StackPanel
        $hrow.Orientation = 'Horizontal'
        $arrow = New-Icon -Kind 'ChevronDown' -Size 18 -Color 'TextDim'
        $arrow.Margin = New-Thick 0 0 8 0
        $hrow.Children.Add($arrow) | Out-Null
        $ct = New-TextBlock -Text $cat -Size 13 -Bold $true
        $ct.VerticalAlignment = 'Center'
        $hrow.Children.Add($ct) | Out-Null
        $cntBox = New-Object System.Windows.Controls.Border
        $cntBox.CornerRadius = New-Corner 6
        $cntBox.Padding = New-Thick 8 0 8 0
        $cntBox.Margin = New-Thick 8 0 0 0
        $cntBox.Background = Get-Brush 'SurfaceSunken'
        $cntBox.VerticalAlignment = 'Center'
        $cnt = New-TextBlock -Text '' -Size 11 -Color 'TextDim'
        $cntBox.Child = $cnt
        $hrow.Children.Add($cntBox) | Out-Null
        $hb.Child = $hrow
        $hb.Tag = $cat
        Add-Interactive $hb -BgNormal 'Transparent' -BgHover 'CardHover'
        $hb.Add_MouseLeftButtonUp({
                $c = $this.Tag
                $Script:TweakCatCollapsed[$c] = -not $Script:TweakCatCollapsed[$c]
                $Script:TweakCatHeaders[$c].Arrow.Kind = if ($Script:TweakCatCollapsed[$c]) { 'ChevronRight' } else { 'ChevronDown' }
                Update-TweakFilter
            })
        $panel.Children.Add($hb) | Out-Null
        $Script:TweakCatHeaders[$cat] = @{ Border = $hb; Arrow = $arrow; Count = $cnt }

        foreach ($tw in ($Script:Tweaks | Where-Object { $_.Category -eq $cat })) {
            $card = New-ListCard
            $card.Tag = $tw
            $card.Add_MouseLeftButtonUp({ Show-TweakDetail $this.Tag })

            # 列轨：勾选框 / 项目 / 结果 / 标记 / 参考范围
            # 后三列定宽，整列右边缘对齐，一眼能顺着扫下来 ——
            # 这是表格相对于卡片最实在的好处。
            $g = New-Object System.Windows.Controls.Grid
            foreach ($w in @(0, -1, 72, 24, 80)) {
                $cd = New-Object System.Windows.Controls.ColumnDefinition
                $cd.Width = if ($w -eq -1) {
                    New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
                } elseif ($w -eq 0) {
                    [System.Windows.GridLength]::Auto
                } else {
                    New-Object System.Windows.GridLength ([double]$w)
                }
                $g.ColumnDefinitions.Add($cd)
            }

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Margin = New-Thick 0 0 8 0
            $cb.VerticalAlignment = 'Top'
            $cb.Tag = $tw
            $cb.Add_Click({ Show-TweakDetail $this.Tag; Update-TweakSelCount })
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)
            $g.Children.Add($cb) | Out-Null

            $sp = New-Object System.Windows.Controls.StackPanel
            $nameTb = New-TextBlock -Text $tw.Name -Size 14
            $nameTb.TextWrapping = 'Wrap'
            $sp.Children.Add($nameTb) | Out-Null
            $meta = New-TextBlock -Text ("风险 {0}　{1}" -f $tw.Risk, $tw.Effect) -Size 12 -Color 'TextDim'
            $meta.TextWrapping = 'Wrap'
            $meta.Margin = New-Thick 0 4 0 0
            $sp.Children.Add($meta) | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($sp, 1)
            $g.Children.Add($sp) | Out-Null

            # ================================================================
            #  结果 / 标记 / 参考范围 —— 和概览页同一套四栏语法
            #
            #  ★ 原来这里是一个圆角药丸，只显示「当前是什么状态」★
            #    报告单多给一栏「参考范围」：这一项**对你这类用户应该是什么**。
            #    信息量实打实多了一层，用户不用点进去才知道该不该动。
            #
            #  ★ 正常的行一律不标色不加粗 ★
            #    只有「该开却没开」的行才上法定墨和 ↑，
            #    满页平静，真要处理的那几行才跳出来。
            # ================================================================
            $res = New-TextBlock -Text '检测中' -Size 13 -Color 'TextMain'
            $res.TextAlignment = 'Right'
            $res.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($res, 2)
            $g.Children.Add($res) | Out-Null

            $mk = New-TextBlock -Text '' -Size 14 -Color 'TextDim'
            $mk.TextAlignment = 'Center'
            $mk.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($mk, 3)
            $g.Children.Add($mk) | Out-Null

            $rf = New-TextBlock -Size 12 -Color 'TextDim' -Text $(if ($tw.Recommended) { '建议 开启' } else { '可选' })
            $rf.TextAlignment = 'Right'
            $rf.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($rf, 4)
            $g.Children.Add($rf) | Out-Null

            $card.Child = $g
            $panel.Children.Add($card) | Out-Null

            $Script:TweakRows[$tw.Id] = @{ Check = $cb; Badge = $res; Mark = $mk; Ref = $rf; Tweak = $tw; Card = $card }
        }
    }
    Show-TweakDetail $null
    $na = @($Script:Tweaks | Where-Object { $_.Category -eq '激进优化' }).Count
    if ($Script:UI.JumpAggressive) {
        $Script:UI.JumpAggressive.Visibility = if ($na -gt 0) { 'Visible' } else { 'Collapsed' }
        $Script:UI.JumpAggressiveText.Text = "激进优化 $na 项（默认不勾）"
    }
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
            # 本机不适用的项用「未上墨」表达：结果写一个长横、整行降到 0.45。
            # 化验单上没做的项目是留白，不会专门涂一块灰遮罩。
            $row.Badge.Text = [char]0x2014
            $row.Badge.Foreground = Get-Brush 'TextDim'
            $row.Badge.FontWeight = 'Normal'
            $row.Mark.Text = ''
            $row.Ref.Text = '本机不适用'
            $row.Check.IsEnabled = $false
            $row.Check.IsChecked = $false
            $row.Card.Opacity = 0.45
            continue
        }
        $row.Check.IsEnabled = $true
        $row.Card.Opacity = 1.0
        $applied = Test-TweakApplied $tw
        $row.Ref.Text = $(if ($tw.Recommended) { '建议 开启' } else { '可选' })
        if ($applied) {
            $row.Badge.Text = '已开启'
            $row.Badge.Foreground = Get-Brush 'TextMain'
            $row.Badge.FontWeight = 'Normal'
            $row.Mark.Text = ''
            $row.Mark.Foreground = Get-Brush 'TextDim'
            $row.Mark.FontWeight = 'Normal'
        } elseif ($tw.Recommended) {
            # 该开却没开 = 超出参考范围。整行唯一上法定墨的情况。
            $row.Badge.Text = '未开启'
            $row.Badge.Foreground = Get-Brush '#8A5750'
            $row.Badge.FontWeight = 'SemiBold'
            $row.Mark.Text = [char]0x2191
            $row.Mark.Foreground = Get-Brush '#8A5750'
            $row.Mark.FontWeight = 'SemiBold'
        } else {
            $row.Badge.Text = '未开启'
            $row.Badge.Foreground = Get-Brush 'TextMain'
            $row.Badge.FontWeight = 'Normal'
            $row.Mark.Text = ''
            $row.Mark.Foreground = Get-Brush 'TextDim'
            $row.Mark.FontWeight = 'Normal'
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
        Show-Msg -Text '还没有勾选任何项目。左边勾上想开的优化，或者点「勾选推荐项」。' | Out-Null
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

    $r = Show-Msg -Text ("即将应用以下 $($List.Count) 项优化：`r`n`r`n$names$warn`r`n`r`n所有修改都会先备份原值，之后随时可以还原。确定继续吗？") -Title '确认应用' -Kind Ask
    if ($r -ne 'Yes') { return }
    Enter-ActionBusy

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
    # 需要重启这种要紧事还是弹模态框，确保看见；其余飘个气泡就够了
    if ($needReboot) { Show-Msg -Text $msg -Kind 'Success' | Out-Null } else { Show-Toast "成功应用 $ok / $($List.Count) 项优化" }
    $Script:LastActionDone = $true     # 按钮据此播「完成」（B3）
}

function Invoke-RevertTweaks {
    param($List)
    $List = @($List)
    if ($List.Count -eq 0) {
        Show-Msg -Text '还没有勾选任何项目。' | Out-Null
        return
    }
    $names = ($List | ForEach-Object { '· ' + $_.Name }) -join "`r`n"
    $r = Show-Msg -Text ("即将把以下 $($List.Count) 项还原为修改前的状态：`r`n`r`n$names`r`n`r`n确定吗？") -Title '确认还原' -Kind Ask
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
    Show-Toast $msg
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
    Start-FadeSlideIn $p   # 换内容时淡入 + 轻微上移，避免「啪」地一下跳变
    if ($Item -and $Script:CleanRows[$Item.Id]) { Select-Card $Script:CleanRows[$Item.Id].Card } else { Select-Card $null }
    if (-not $Item) {
        $p.Children.Add((New-RptSection -Title '清理说明' -Icon 'Broom')) | Out-Null
        $p.Children.Add((New-TextBlock -Text "点左边任意一项，这里会说明它清的是什么、安不安全。`r`n`r`n建议先点「扫描可清理的垃圾」看看各项能清多少，再决定。" -Color 'TextDim' -Wrap $true)) | Out-Null
        return
    }
    $p.Children.Add((New-TextBlock -Text $Item.Name -Size 16 -Bold $true -Wrap $true)) | Out-Null
    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = New-Thick 0 12 0 12
    $rc = Get-RiskColors $Item.Risk
    $wrap.Children.Add((New-Badge -Text ("风险 " + $Item.Risk) -Fg $rc.Fg -Bg $rc.Bg)) | Out-Null
    if ($Item.Recommended) { $wrap.Children.Add((New-Badge -Text '推荐' -Fg 'TextMid' -Bg 'SurfaceSunken')) | Out-Null }
    $p.Children.Add($wrap) | Out-Null
    $p.Children.Add((New-TextBlock -Text (Format-Reflow $Item.Detail) -Size 13 -Color 'TextMid' -Wrap $true)) | Out-Null
}

function Update-CleanSelCount {
    $n = 0
    foreach ($r in $Script:CleanRows.Values) { if ($r.Check.IsChecked) { $n++ } }
    $Script:UI.CleanSelCount.Text = if ($n -gt 0) { "已勾选 $n 项" } else { '还没勾选任何项目' }
    $Script:UI.BtnClean.IsEnabled = ($n -gt 0)
}

function Update-CleanFilter {
    $q = "$($Script:UI.CleanSearch.Text)".Trim()
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
    Add-ColHeader $panel -First '清理项目' -Cols @(@{ T = '可清理'; W = 96 })

    foreach ($it in $Script:CleanItems) {
        $card = New-ListCard
        $card.Tag = $it
        $card.Add_MouseLeftButtonUp({ Show-CleanDetail $this.Tag })

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(0, -1, 96)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq -1) {
                New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            } elseif ($w -eq 0) {
                [System.Windows.GridLength]::Auto
            } else {
                New-Object System.Windows.GridLength ([double]$w)
            }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = New-Thick 0 0 8 0
        $cb.IsChecked = [bool]$it.Recommended
        $cb.Tag = $it
        $cb.Add_Click({ Show-CleanDetail $this.Tag; Update-CleanSelCount })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $g.Children.Add($cb) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        $nameTb = New-TextBlock -Text $it.Name -Size 14
        $nameTb.TextWrapping = 'Wrap'
        $sp.Children.Add($nameTb) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null

        # 扫描结果：等宽数位右对齐，和别的表一个语汇。
        # 不加粗 —— 加粗是留给「超出参考范围」的。
        $size = New-TextBlock -Text ([string][char]0x2014) -Size 14 -Color 'TextMain' -Bold $true
        $size.VerticalAlignment = 'Center'
        $size.TextAlignment = 'Right'
        [System.Windows.Documents.Typography]::SetNumeralAlignment($size, 'Tabular')
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
            $row.Size.Foreground = Get-Brush 'TextDim'
        } elseif ($sz -eq 0) {
            $row.Size.Text = '无'
            $row.Size.Foreground = Get-Brush 'TextDim'
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
        Show-Msg -Text '还没有勾选任何清理项。' | Out-Null
        return
    }
    $names = ($sel | ForEach-Object { '· ' + $_.Name }) -join "`r`n"
    $r = Show-Msg -Text ("即将清理以下 $($sel.Count) 项：`r`n`r`n$names`r`n`r`n建议先关闭浏览器和游戏平台客户端，正在使用的文件删不掉。`r`n清理不可撤销，确定继续吗？") -Title '确认清理' -Kind AskWarn
    if ($r -ne 'Yes') { return }
    Enter-ActionBusy

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
    Show-Toast $msg
    $Script:LastActionDone = $true     # 按钮据此播「完成」（B3）
}

# ---------------------------------------------------------------------
#  7. 启动项页
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#  个性化（换肤）页
# ---------------------------------------------------------------------
function New-ThemeSwatchBar {
    <#
      一套皮肤的缩略图：画布底色上放一张白卡 + 一粒强调色，像这套皮肤下的界面剖面。

      ★ 必须直接 ConvertFromString，不能走 Get-Brush ★
        Get-Brush 按**当前**皮肤取色，那样两张预览会被画成同一套颜色。（踩过。）
    #>
    param([string[]]$Colors, [double]$H = 96)
    $bg = New-Object System.Windows.Controls.Border
    $bg.Height = $H
    $bg.CornerRadius = New-Corner 8
    $bg.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Colors[0]))
    $bg.BorderBrush = Get-Brush 'Stroke'
    $bg.BorderThickness = New-Thick 1
    $bg.Padding = New-Thick 16 16 16 16
    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = New-Corner 8
    $card.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Colors[1]))
    $card.Padding = New-Thick 12 12 12 12
    $sp = New-Object System.Windows.Controls.StackPanel
    foreach ($w in 64, 40) {
        $ln = New-Object System.Windows.Controls.Border
        $ln.Width = $w; $ln.Height = 6
        $ln.CornerRadius = New-Corner 3
        $ln.HorizontalAlignment = 'Left'
        $ln.Margin = New-Thick 0 0 0 8
        $ln.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Colors[0]))
        $sp.Children.Add($ln) | Out-Null
    }
    $pill = New-Object System.Windows.Controls.Border
    $pill.Width = 48; $pill.Height = 12
    $pill.CornerRadius = New-Corner 6
    $pill.HorizontalAlignment = 'Left'
    $pill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Colors[2]))
    $sp.Children.Add($pill) | Out-Null
    $card.Child = $sp
    $bg.Child = $card
    return $bg
}

function Add-SubItem {
    <#
      把一个控件作为「上面那一组的子项」加进面板：左缩进 + 左边一条细线。

      ★ 为什么需要它 ★
        「面板不透明度」和「磨砂」是「背景图」这一组的从属选项，
        而「开启界面动画」是一个独立设置。上一版它们长得一模一样，
        读者分不出哪个管上面那一摊。缩进加一条竖线是最省的说法。

      ★ 每个子项各包一个 Border，但 Border 之间不留 Margin ★
        留了的话竖线会断成好几截，看起来像三条独立的线而不是一组。
    #>
    param($Panel, $Element)
    if ($null -eq $Panel -or $null -eq $Element) { return }
    $b = New-Object System.Windows.Controls.Border
    $b.BorderBrush = Get-Brush 'Stroke'
    $b.BorderThickness = New-Thick 1 0 0 0
    $b.Padding = New-Thick 16 0 0 0
    $b.Child = $Element
    $Panel.Children.Add($b) | Out-Null
}

function New-SettingCheck {
    <#
      一个带说明的开关。返回可以直接塞进面板的那一块（勾 + 说明）。

      ★ 说明不能塞进 CheckBox.Content ★
        试过了：控件库的模板里那个方框是**垂直居中**的，内容再高它也不跟，
        于是「标题 + 说明」两行下去，方框就对到了说明那一行 ——
        看起来像方框是说明的、跟标题没关系。
        所以勾里只放标题（永远一行，方框自然对齐），说明另起一行。

      ★ 说明照样要能点 ★
        它就在勾正下方、同样的视觉分组里，用户下意识就会去点。
        点它等于点勾 —— 切完状态再把 Click 事件抛出去，走同一个处理逻辑，
        不用把那段逻辑抄两遍。

      ★ 说明写「开了会怎样、什么时候该关」，不写怎么实现的 ★
        用这东西的人不关心它是导入时算的还是每帧算的。
    #>
    param(
        [string]$Title,
        [string]$Note = '',
        [string]$WhyOff = '',        # 不可用时的理由，会替掉说明
        [bool]$Checked = $false,
        [bool]$Enabled = $true,
        [scriptblock]$OnClick = $null
    )
    $wrap = New-Object System.Windows.Controls.StackPanel

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $Script:Window.FindResource('SwitchBox')    # 设置项 = 开关（design.md 5.3）
    $cb.Content = $Title
    $cb.FontSize = 13
    $cb.IsChecked = $Checked
    $cb.IsEnabled = $Enabled
    if ($OnClick) { $cb.Add_Click($OnClick) }
    $wrap.Children.Add($cb) | Out-Null

    $noteText = if ($Enabled) { $Note } else { $WhyOff }
    if ($noteText) {
        $n = New-TextBlock -Text $noteText -Size 12 -Color 'TextDim' -Wrap $true
        # 左边缩到和标题文字对齐（开关 36 + 间距 8），说明才像是这个开关的
        $n.Margin = New-Thick 44 4 0 0
        # 一行 90 个字没人读，压到一个正常的阅读宽度
        $n.MaxWidth = 720
        $n.HorizontalAlignment = 'Left'
        if ($Enabled) {
            $n.Cursor = 'Hand'
            $n.Tag = $cb
            $n.Add_MouseLeftButtonUp({
                    $c = $this.Tag
                    $c.IsChecked = -not [bool]$c.IsChecked
                    # 抛一次 Click，让它走和真点勾完全一样的那条路
                    $c.RaiseEvent((New-Object System.Windows.RoutedEventArgs (
                                [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                })
        }
        $wrap.Children.Add($n) | Out-Null
    }
    return $wrap
}

function Build-ThemeUI {
    <#
      个性化页：三张卡 —— 皮肤（浅色 / 深色）、背景图、界面动画。
      v6.0 只有两套皮肤：浅色默认，深色备选（design.md 1.1）。
    #>
    $panel = $Script:UI.ThemePanel
    $panel.Children.Clear()
    $cur = Get-ThemeSetting

    # ==================== 皮肤 ====================
    $c1 = New-Card -Title '皮肤' -Aside '点一下立刻生效，下次打开自动记住' -Icon 'PaletteOutline'
    $themes = Get-BuiltinThemes
    $names = @($themes.Keys)
    $grid = New-Object System.Windows.Controls.Grid
    for ($c = 0; $c -lt ($names.Count * 2 - 1); $c++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($c % 2 -eq 1) { New-Object System.Windows.GridLength 16 } else { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
        $grid.ColumnDefinitions.Add($cd)
    }
    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = $names[$i]
        $th = $themes[$name]
        $on = ($name -eq $cur.Name)

        # 选中 = 2px 强调色描边 + 名字前一个勾（选中态是强调色的合法去处）
        $cell = New-Object System.Windows.Controls.Border
        $cell.CornerRadius = New-Corner 12
        $cell.Padding = New-Thick 12 12 12 12
        $cell.BorderThickness = New-Thick 2
        $cell.BorderBrush = Get-Brush $(if ($on) { 'Accent' } else { 'Stroke' })
        $cell.Background = [System.Windows.Media.Brushes]::Transparent
        $cell.Cursor = 'Hand'
        $cell.Tag = $name
        $cell.Add_MouseLeftButtonUp({
                Set-AppTheme -Name $this.Tag -Image $Script:ThemeImage -Opacity $Script:ThemeOpacity -Frost $Script:ThemeFrost
                Redraw-AllPages
                Set-Status "皮肤已换成「$($this.Tag)」"
            })
        Add-Interactive $cell -BgNormal 'Transparent' -BgHover 'CardHover'
        if ($on) { $cell.Resources['__sel'] = $true }

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-ThemeSwatchBar -Colors $th.Swatch)) | Out-Null
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $head.Margin = New-Thick 0 12 0 0
        if ($on) {
            $ck = New-Icon -Kind 'CheckCircle' -Size 18 -Color 'Accent'
            $ck.Margin = New-Thick 0 0 8 0
            $head.Children.Add($ck) | Out-Null
        }
        $nm = New-TextBlock -Text $name -Size 14 -Bold $true -Color $(if ($on) { 'Accent' } else { 'TextMain' })
        $nm.VerticalAlignment = 'Center'
        $head.Children.Add($nm) | Out-Null
        $tagBits = @()
        if ($on) { $tagBits += '使用中' }
        if (Test-ThemeIsDark $name) { $tagBits += '深色' }
        if ($tagBits.Count -gt 0) {
            $tg = New-TextBlock -Text ($tagBits -join ' · ') -Size 12 -Color 'TextDim'
            $tg.VerticalAlignment = 'Center'
            $tg.Margin = New-Thick 8 0 0 0
            $head.Children.Add($tg) | Out-Null
        }
        $sp.Children.Add($head) | Out-Null
        $ds = New-TextBlock -Text $th.Desc -Size 12 -Color 'TextDim' -Wrap $true
        $ds.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($ds) | Out-Null

        $cell.Child = $sp
        [System.Windows.Controls.Grid]::SetColumn($cell, $i * 2)
        $grid.Children.Add($cell) | Out-Null
    }
    $c1.Body.Children.Add($grid) | Out-Null
    $panel.Children.Add($c1.Card) | Out-Null

    # ==================== 背景图 ====================
    $c2 = New-Card -Title '背景图' -Aside '可选' -Icon 'ImageOutline'
    $c2.Card.Margin = New-Thick 0 16 0 0
    $pb = $c2.Body
    $tip = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text (
        '选一张图铺在窗口背景上。图片会被复制到工具自己的文件夹里保存，' +
        '所以选完之后原图删掉、U 盘拔掉都不影响。' + "`r`n" +
        '建议选颜色比较淡、内容不太花的图 —— 太花的图会让上面的字看不清。' +
        '下面的「面板不透明度」就是用来调这个的：拉低一点图更明显，拉高一点字更清楚。')
    $pb.Children.Add($tip) | Out-Null

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Thick 0 16 0 0
    $btnPick = New-Object System.Windows.Controls.Button
    $btnPick.Content = '选择图片…'
    $btnPick.Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = '选一张背景图'
            $dlg.Filter = '图片文件|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.webp|所有文件|*.*'
            if ($dlg.ShowDialog() -ne $true) { return }
            $saved = Copy-ThemeImage -SourcePath $dlg.FileName
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image $saved -Opacity $st.Opacity -Frost $st.Frost
            Redraw-AllPages
            Set-Status '背景图已设置'
        })
    $row.Children.Add($btnPick) | Out-Null
    $btnClear = New-Object System.Windows.Controls.Button
    $btnClear.Content = '取消背景图'
    $btnClear.Add_Click({
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image '' -Opacity $st.Opacity -Frost $st.Frost
            Redraw-AllPages
            Set-Status '已恢复纯色背景'
        })
    $row.Children.Add($btnClear) | Out-Null
    $pb.Children.Add($row) | Out-Null

    # ★ PowerShell 5.1 里 if 不能当表达式用在参数位置上 ★ 先算到变量里再传。
    # ★ 没有背景图的时候下面两项一个都不起作用 —— 必须禁用，有反应而反应是假的比没反应更坏 ★
    $hasImg = [bool]$cur.Image -and (Test-Path -LiteralPath "$($cur.Image)")
    $nowText = if ($hasImg) { "当前背景图：$($cur.Image)" } else { '当前是纯色背景。下面两项要选了图才用得上。' }
    $now = New-TextBlock -Size 12 -Color 'TextDim' -Wrap $true -Text $nowText
    $now.Margin = New-Thick 0 12 0 0
    $pb.Children.Add($now) | Out-Null

    $ol = New-TextBlock -Size 13 -Bold $true -Text ('面板不透明度　{0}%' -f [int]($cur.Opacity * 100))
    $ol.Margin = New-Thick 0 20 0 8
    $ol.Foreground = Get-Brush $(if ($hasImg) { 'TextMain' } else { 'TextDim' })
    Add-SubItem $pb $ol

    $sld = New-Object System.Windows.Controls.Slider
    $sld.Minimum = 0.35; $sld.Maximum = 1.0
    $sld.Value = $cur.Opacity
    $sld.TickFrequency = 0.05
    $sld.IsSnapToTickEnabled = $true
    $sld.Width = 320
    $sld.HorizontalAlignment = 'Left'
    $sld.Tag = $ol
    $sld.IsEnabled = $hasImg
    $sld.Add_ValueChanged({
            $this.Tag.Text = ('面板不透明度　{0}%' -f [int]($this.Value * 100))
        })
    # 拖完再套用 —— 拖动过程中每动一下就重绘全部页面会非常卡
    $sld.Add_PreviewMouseUp({
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image $st.Image -Opacity ([double]$this.Value) -Frost $st.Frost
            Apply-PanelOpacity
            Set-Status ('面板不透明度已设为 {0}%' -f [int]($this.Value * 100))
        })
    Add-SubItem $pb $sld

    $on2 = New-TextBlock -Size 12 -Color 'TextDim' -Wrap $true -Text (
        '100% = 完全挡住背景图（和纯色一样），拉低才能看见图。')
    $on2.Margin = New-Thick 0 8 0 0
    Add-SubItem $pb $on2

    $fcb = New-SettingCheck -Title '磨砂 —— 把背景图模糊掉' `
        -Note '图上的细节会糊成大块的颜色，压在上面的字就清楚了。想看清自己那张图就关掉它。' `
        -WhyOff '选了背景图才用得上。' `
        -Checked ([bool]$cur.Frost) -Enabled $hasImg -OnClick {
        $st = Get-ThemeSetting
        Set-AppTheme -Name $st.Name -Image $st.Image -Opacity $st.Opacity -Frost ([bool]$this.IsChecked)
        Redraw-AllPages
        Set-Status $(if ($this.IsChecked) { '已开磨砂' } else { '已关磨砂，背景图恢复原清晰度' })
    }
    $fcb.Margin = New-Thick 0 20 0 0
    Add-SubItem $pb $fcb
    $panel.Children.Add($c2.Card) | Out-Null

    # ==================== 界面动画 ====================
    $c3 = New-Card -Title '界面动画' -Icon 'AnimationOutline'
    $c3.Card.Margin = New-Thick 0 16 0 0
    $acb = New-SettingCheck -Title '开启界面动画' `
        -Note '切换页面、点开详情时淡入。如果你的机器点哪都要等一下，关掉它操作反馈会更干脆 —— 关了之后所有切换都是瞬间完成，功能一模一样。' `
        -Checked ([bool]$Script:AnimEnabled) -OnClick {
        $Script:AnimEnabled = [bool]$this.IsChecked
        Sync-TransitionSwitch
        $st = Get-ThemeSetting
        Save-ThemeSetting -Name $st.Name -Image $st.Image -Opacity $st.Opacity -Anim $Script:AnimEnabled -Frost $st.Frost
        Set-Status $(if ($Script:AnimEnabled) { '界面动画已开启 —— 切一下页签就能看见' } else { '界面动画已关闭' })
    }
    $c3.Body.Children.Add($acb) | Out-Null
    $panel.Children.Add($c3.Card) | Out-Null
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
    Update-ThemeToggleIcon
    try { Build-NavUI } catch { }
    # 重建列表会丢掉勾选状态 —— 先记下来、建完再勾回去，换个皮肤不该让用户重勾一遍
    $keepTweak = @{}; foreach ($k in $Script:TweakRows.Keys) { $keepTweak[$k] = [bool]$Script:TweakRows[$k].Check.IsChecked }
    $keepClean = @{}; foreach ($k in $Script:CleanRows.Keys) { $keepClean[$k] = [bool]$Script:CleanRows[$k].Check.IsChecked }
    try { Build-TweakUI; Update-TweakStates; foreach ($k in $keepTweak.Keys) { if ($Script:TweakRows[$k] -and $Script:TweakRows[$k].Check.IsEnabled) { $Script:TweakRows[$k].Check.IsChecked = $keepTweak[$k] } }; Update-TweakSelCount } catch { }
    try { Build-PresetUI } catch { }
    # ★ 概览页也必须重建 ★ 漏了它的话换皮肤之后读数卡还是旧配色
    #   （v5.1 这里判断的是一个永远为空的表，概览页换肤后其实从没重画过）
    try { if ($Script:DashGauges -and $Script:DashGauges.Count -gt 0) { Build-DashUI; Update-DashScore -Redraw; $Script:DashSeq = -1; Update-DashUI } } catch { }
    try { Build-CleanUI; foreach ($k in $keepClean.Keys) { if ($Script:CleanRows[$k]) { $Script:CleanRows[$k].Check.IsChecked = $keepClean[$k] } }; Update-CleanSelCount } catch { }
    try { Build-ThemeUI } catch { }
    try { if ($Script:UI.StartupPanel.Children.Count -gt 0) { Build-StartupUI } } catch { }
    try { if ($Script:UI.AppxPanel.Children.Count -gt 0) { Build-AppxUI } } catch { }
    try { if ($Script:UI.MaintainPanel.Children.Count -gt 0) { Build-MaintainUI } } catch { }
    try { if ($Script:UI.AdvicePanel.Children.Count -gt 0) { Build-HealthUI } } catch { }
    # 弹窗排查页：扫过就重画结果，没扫过就重画空状态（空状态里也有颜色）
    try {
        if ($Script:Findings -and $Script:Findings.Count -gt 0) { Show-Findings }
        else { $Script:UI.InspectPanel.Children.Clear(); Set-InspectEmpty }
    } catch { }
    try { Build-LogUI } catch { }
    # 大文件查找：只重画空状态。已经扫出来的结果不动 ——
    # 重扫要一两分钟，为了换个皮肤把用户等来的结果清掉，那是本末倒置。
    try {
        if ($Script:UI.BigFilePanel.Children.Count -le 1) {
            $Script:UI.BigFilePanel.Children.Clear(); Set-BigFileEmpty
        }
    } catch { }
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
    <#
      v6.2：Get-AppxPackage 在后台跑（首次进这一页原来会卡半秒以上），读完再画。
      -Refresh 重新读（按钮 / 卸载之后）；换肤重画不带参数。
    #>
    param([switch]$Refresh, [switch]$Enter)
    $panel = $Script:UI.AppxPanel
    if ($Refresh -or $null -eq $Script:AppxData) {
        if ($Script:AppxBusy) { return }
        $Script:AppxBusy = $true
        $Script:AppxEnter = [bool]$Enter
        $panel.Children.Clear()
        $panel.Children.Add((New-TextBlock -Text '正在读取自带应用列表…' -Size 13 -Color 'TextDim')) | Out-Null
        Set-Status '正在读取自带应用列表…'
        Start-BgWork 'appx' {
            $Script:AppxFailReason = $null
            $items = @(Get-AppxCatalog)
            @{ Items = $items; Why = $Script:AppxFailReason }
        } -OnDone {
            param($r)
            $Script:AppxBusy = $false
            if ($null -eq $r) { Set-Status '读取自带应用列表失败，详见日志页'; return }
            $Script:AppxData = $r
            Build-AppxUI
            if ($Script:AppxEnter) { Start-ListEnter $Script:UI.AppxPanel }
        }
        return
    }
    $panel.Children.Clear()
    $Script:AppxRows = @{}

    $Script:AppxFailReason = $Script:AppxData.Why
    $items = @($Script:AppxData.Items)
    if ($items.Count -eq 0) {
        $why = '常见原因：这台机器是精简版系统，自带应用已经被处理过了 —— 那就不用管这一页。'
        if ($Script:AppxFailReason -eq 'pwsh') {
            $why = '原因：当前是用 PowerShell 7（pwsh）运行的，' +
            '微软的 Appx 模块在 PowerShell 7 上不支持，读不到应用列表。' + "`r`n`r`n" +
            '解决办法：关掉这个窗口，改成双击「电脑调优助手.exe」——' +
            '它用的是系统自带的 PowerShell 5.1，这一页就正常了。'
        } elseif ($Script:AppxFailReason) {
            $why = "原因：$Script:AppxFailReason"
        }
        $panel.Children.Add((New-TextBlock -Wrap $true -Color 'TextDim' -Text (
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

        # 行式表，和别的页一个语汇：没有圆角、没有底色、没有边框盒子，
        # 只有一条行间细线。
        $card = New-Object System.Windows.Controls.Border
        $card.Background = [System.Windows.Media.Brushes]::Transparent
        $card.BorderBrush = Get-Brush $Script:CARD_BORDER
        $card.BorderThickness = New-Thick 0 0 0 1
        $card.Padding = New-Thick 12 12 12 12
        $card.Margin = New-Thick 0 0 0 0

        # 列轨：勾选框 / 项目 / 结果 / 参考范围
        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(0, -1, 80, 88)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq -1) {
                New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            } elseif ($w -eq 0) {
                [System.Windows.GridLength]::Auto
            } else {
                New-Object System.Windows.GridLength ([double]$w)
            }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Margin = New-Thick 0 0 8 0
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
        $head.Children.Add((New-TextBlock -Text $it.Label -Size 14 -Bold $true)) | Out-Null
        $bd = New-Badge -Text $it.Verdict -Fg $c.Fg -Bg $c.Bg
        $bd.Margin = New-Thick 8 0 0 0
        $head.Children.Add($bd) | Out-Null
        if ($it.Size -and $it.Size -ne '—') {
            $sz = New-Badge -Text $it.Size -Fg 'TextDim' -Bg 'SurfaceSunken'
            $sz.Margin = New-Thick 4 0 0 0
            $head.Children.Add($sz) | Out-Null
        }
        $sp.Children.Add($head) | Out-Null

        $tx = New-TextBlock -Text (Format-Reflow $it.Text) -Size 12 -Color 'TextDim' -Wrap $true
        $tx.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($tx) | Out-Null

        # 标题已经是包名（不认识的包没有友好名）就不再印一遍
        if ($it.Label -ne $it.Name) {
            $pn = New-TextBlock -Text $it.Name -Size 11 -Color 'TextDim' -Wrap $true
            $pn.Margin = New-Thick 0 4 0 0
            $sp.Children.Add($pn) | Out-Null
        }

        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null
        $card.Child = $g
        $panel.Children.Add($card) | Out-Null
    }

    Close-CardRows $panel
    $safe = @($items | Where-Object { $_.Verdict -eq '可以删' }).Count
    Update-AppxCounter
    # 后台读完回来时人可能已经在别的页了 —— 状态栏只报当前页的事，不串台
    if ("$($Script:UI.Tabs.SelectedItem.Header)" -eq '自带软件') {
        Set-Status ("自带应用 {0} 个，其中 {1} 个可以放心删" -f $items.Count, $safe)
    }
}

function Invoke-AppxUninstall {
    $names = @()
    foreach ($k in $Script:AppxRows.Keys) {
        $cb = $Script:AppxRows[$k]
        # 三重确认：勾上了 + 复选框是启用的 + 不在硬黑名单里
        if ($cb.IsChecked -and $cb.IsEnabled -and -not (Test-AppxProtected $k)) { $names += $k }
    }
    if ($names.Count -eq 0) {
        Show-Msg -Text '还没有勾选要卸载的应用。' | Out-Null
        return
    }

    $r = Show-Msg -Text (("确定要卸载这 {0} 个自带应用吗？`r`n`r`n{1}`r`n`r`n卸载只影响当前用户，任何一个都能去 Microsoft Store 搜名字装回来。" -f `
                $names.Count, ($names -join "`r`n"))) -Title '确认卸载' -Kind Ask
    if ($r -ne 'Yes') { return }

    Set-Busy $true
    $ok = 0; $fail = 0
    foreach ($n in $names) {
        Set-Status "正在卸载 $n …"
        Sync-UI
        if (Remove-AppxSafe -Name $n) { $ok++ } else { $fail++ }
    }
    Set-Busy $false
    Build-AppxUI -Refresh
    Show-Msg -Text (("卸载完成：成功 {0} 个，失败 {1} 个。`r`n`r`n失败的多半是系统保护的包，日志页有具体原因。" -f $ok, $fail)) -Title '电脑调优助手' -Kind Info | Out-Null
}

function Build-StartupUI {
    <#
      v6.2：读启动项（注册表 + 启动文件夹 + 解析快捷方式，实测 150~460ms）在后台跑，读完再画。
      -Refresh 重新读（按钮 / F5）；换肤重画不带参数。
    #>
    param([switch]$Refresh, [switch]$Enter)
    $panel = $Script:UI.StartupPanel
    if ($Refresh -or $null -eq $Script:StartupData) {
        if ($Script:StartupBusy) { return }
        $Script:StartupBusy = $true
        $Script:StartupEnter = [bool]$Enter
        if ($null -eq $Script:StartupData) {
            $panel.Children.Clear()
            $panel.Children.Add((New-TextBlock -Text '正在读取开机启动项…' -Size 13 -Color 'TextDim')) | Out-Null
        }
        Set-Status '正在读取开机启动项…'
        Start-BgWork 'startup' { @{ Items = @(Get-StartupItems) } } -OnDone {
            param($r)
            $Script:StartupBusy = $false
            if ($null -eq $r) { Set-Status '读取开机启动项失败，详见日志页'; return }
            $Script:StartupData = $r
            Build-StartupUI
            if ($Script:StartupEnter) { Start-ListEnter $Script:UI.StartupPanel }
        }
        return
    }
    $panel.Children.Clear()
    $items = @($Script:StartupData.Items)
    if ($items.Count -eq 0) {
        $panel.Children.Add((New-TextBlock -Text '没有发现任何开机启动项，很干净。' -Color 'TextDim')) | Out-Null
        Set-Status '就绪'
        return
    }

    Add-ColHeader $panel -First '开机启动项' -Cols @(@{ T = '结果'; W = 80 }, @{ T = '安全范围'; W = 88 }) -Indent 56
    foreach ($it in $items) {
        # 行式表，和别的页一个语汇：没有圆角、没有底色、没有边框盒子，
        # 只有一条行间细线。深度靠表面阶梯，不靠盒子。
        $card = New-Object System.Windows.Controls.Border
        $card.Background = [System.Windows.Media.Brushes]::Transparent
        $card.BorderBrush = Get-Brush $Script:CARD_BORDER
        $card.BorderThickness = New-Thick 0 0 0 1
        $card.Padding = New-Thick 12 12 12 12
        $card.Margin = New-Thick 0 0 0 0

        # 列轨：勾选框 / 项目 / 结果 / 参考范围
        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(0, -1, 80, 88)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq -1) {
                New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            } elseif ($w -eq 0) {
                [System.Windows.GridLength]::Auto
            } else {
                New-Object System.Windows.GridLength ([double]$w)
            }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $Script:Window.FindResource('SwitchBox')    # 启用 / 禁用是开关，不是「选中」
        $cb.Margin = New-Thick 0 0 8 0
        $cb.VerticalAlignment = 'Top'
        $cb.IsChecked = [bool]$it.Enabled
        $cb.Tag = $it
        $cb.Add_Click({
                $item = $this.Tag
                Set-StartupItemEnabled -Item $item -Enabled ([bool]$this.IsChecked) | Out-Null
                try { $item.Enabled = [bool]$this.IsChecked } catch { }   # 换肤重画用的是缓存，跟着改
                Set-Status ("启动项「{0}」已{1}" -f $item.Name, $(if ($this.IsChecked) { '启用' } else { '禁用' }))
            })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $g.Children.Add($cb) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $nm = New-TextBlock -Text $it.Name -Size 14 -Bold $true
        $head.Children.Add($nm) | Out-Null
        $sc = New-Badge -Text $it.Scope -Fg 'TextDim' -Bg 'SurfaceSunken'
        $sc.Margin = New-Thick 8 0 0 0
        $head.Children.Add($sc) | Out-Null
        $sp.Children.Add($head) | Out-Null

        $adv = New-TextBlock -Text $it.AdviceText -Size 12 -Color 'TextDim' -Wrap $true
        $adv.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($adv) | Out-Null

        $cmd = New-TextBlock -Text $it.Command -Size 11 -Color 'TextDim' -Wrap $true
        $cmd.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($cmd) | Out-Null

        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null
                # ================================================================
        #  结果 / 参考范围
        #
        #  ★ 法定墨只表示「超出参考范围」★
        #    这一页的「超出」是：**建议关掉，但它还开着**。
        #    「建议保留」是好事，绝不能上墨 —— 原来它用的是高危玫瑰色，
        #    在检验单皮肤里被映射成法定墨，等于把好事标成了问题。
        #    颜色一旦用错，整套「扫过去只有真问题在发光」的机制就废了。
        # ================================================================
        $res = New-TextBlock -Size 13 -Color 'TextMain' -Text $(if ($it.Enabled) { '已开启' } else { '已关闭' })
        $res.TextAlignment = 'Right'
        $res.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($res, 2)

        # AdviceLevel 本身就是「建议保留」这种说法，前面再拼一个「建议」就重了
        $rf = New-TextBlock -Text $(if ($it.AdviceLevel -like '建议*') { $it.AdviceLevel } else { '建议 ' + $it.AdviceLevel }) -Size 12 -Color 'TextDim'
        $rf.TextAlignment = 'Right'
        $rf.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($rf, 3)

        if ($it.AdviceLevel -eq '可关' -and $it.Enabled) {
            $res.Foreground = Get-Brush '#8A5750'
            $res.FontWeight = 'SemiBold'
            $res.Text = '已开启 ' + [char]0x2191
        }
        $g.Children.Add($res) | Out-Null
        $g.Children.Add($rf) | Out-Null

        $card.Child = $g
        $panel.Children.Add($card) | Out-Null
    }
    Close-CardRows $panel
    # 同自带软件页：后台读完 / 换肤重画时人多半不在这一页，别串台
    if ("$($Script:UI.Tabs.SelectedItem.Header)" -eq '启动项管理') { Set-Status ("共 {0} 个开机启动项" -f $items.Count) }
}

# ---------------------------------------------------------------------
#  7.5 日常维护页
# ---------------------------------------------------------------------

function New-ToolButton {
    param([string]$Text, [scriptblock]$OnClick, $Tag = $null)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Margin = New-Thick 0 0 8 8
    # 不加这句的话，按钮放进竖排 StackPanel 会被拉成整行宽，非常难看
    $b.HorizontalAlignment = 'Left'
    if ($null -ne $Tag) { $b.Tag = $Tag }
    $b.Add_Click($OnClick)
    return $b
}

function Invoke-DailyMaintenance {
    <# 「一键日常维护」：清理 + 刷新DNS + 系统盘 TRIM，一条龙 #>
    $r = Show-Msg -Text ("一键日常维护会依次做三件事：`r`n`r`n1. 清理「垃圾清理」页里所有推荐项（临时文件、缓存、日志…）`r`n2. 刷新 DNS 缓存`r`n3. 对系统盘执行 TRIM / 碎片整理`r`n`r`n全程不会改动任何性能设置，也不会碰你的文件。`r`n建议先关掉浏览器和游戏平台。`r`n`r`n现在开始吗？") -Title '一键日常维护' -Kind Ask
    if ($r -ne 'Yes') { return }
    Enter-ActionBusy

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
    Show-Msg -Text $msg | Out-Null
    $Script:LastActionDone = $true     # 按钮据此播「完成」（B3）
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
        Show-Msg -Text "切换到 $Hz Hz 失败 —— 显卡驱动拒绝了这个模式。`r`n`r`n常见原因是线材带宽不够（HDMI 2.0 带不动 1080p 240Hz 这种），换根 DP 线试试。`r`n`r`n设置没有被改动。" | Out-Null
        return
    }

    # 倒计时确认。用 DispatcherTimer 是因为要在界面线程上更新按钮文字。
    $win = New-Object System.Windows.Window
    $win.UseLayoutRounding = $true
    $win.Title = '确认刷新率'
    $win.Width = 420; $win.SizeToContent = 'Height'
    $win.WindowStartupLocation = 'CenterScreen'
    $win.ResizeMode = 'NoResize'
    $win.Background = Get-Brush 'Card'
    # ★ 子窗口不继承主窗口的 FontFamily ★
    #   WPF 的属性继承走的是可视树，而新建的 Window 是另一棵树的根。
    #   不显式设的话，弹窗会退回系统默认字 —— 主界面是随包字体、
    #   弹窗是微软雅黑，一眼就看出是两套东西拼的。
    $win.FontFamily = New-Object System.Windows.Media.FontFamily $Script:FontStack
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 24 20 24 20
    $sp.Children.Add((New-TextBlock -Text ("已切换到 {0} Hz" -f $Hz) -Size 16 -Bold $true)) | Out-Null
    $tip = New-TextBlock -Wrap $true -Size 12 -Color 'TextMid' -Text '画面正常吗？正常就点「保持」。如果黑屏或花屏，什么都不用做 —— 倒计时结束会自动切回去。'
    $tip.Margin = New-Thick 0 12 0 12
    $sp.Children.Add($tip) | Out-Null
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $keep = New-Object System.Windows.Controls.Button
    $keep.Content = '保持这个设置'
    try { $keep.Style = $Script:Window.FindResource('ButtonPrimary') } catch { }
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
    Build-MaintainUI -Refresh   # 重新读一遍再重建，按钮上的「当前」标记要跟着更新
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
    [void]$sb.AppendLine(('工具版本：v{0}（{1}）' -f $Script:AppVersion, $Script:AppVersionDate))
    [void]$sb.AppendLine(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---------- 硬件信息 ----------')
    # 体检页后台跑过就用它的结果，没跑完才现读（v6.2）
    $hd = $Script:HealthData
    foreach ($r in $(if ($hd) { @($hd.Report) } else { Get-SystemReport })) { [void]$sb.AppendLine(('{0}：{1}' -f $r.Key, $r.Value)) }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---------- 体检结论 ----------')
    foreach ($a in $(if ($hd) { @($hd.Advice) } else { Get-HealthAdvice })) {
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
        $r = Show-Msg -Text ("报告已保存到桌面：`r`n$(Split-Path $path -Leaf)`r`n`r`n里面有硬件信息、体检结论、优化项状态和操作日志，可以直接发给别人看。`r`n`r`n现在打开它吗？") -Title '电脑调优助手' -Kind Ask
        if ($r -eq 'Yes') { Start-Process notepad.exe -ArgumentList "`"$path`"" }
    } catch {
        Set-Busy $false
        Show-Msg -Text "保存失败：$($_.Exception.Message)" | Out-Null
    }
}

function Build-MaintainUI {
    <#
      这一页是报告单末尾的「处置」栏：能测的先报数，能做的就跟在那一行后面。

      ★ 全页只有两种行 ★
        New-RptRow  —— 有数可报的项（刷新率、硬盘寿命、占用）
        New-ActRow  —— 只有动作的项（一键维护、开关、打开某个设置）
      每一节是一张卡（design.md 4.4），节里的行用细线分开。
    #>
    #  v6.2：显示器模式、硬盘 SMART、分区列表、计划任务在后台读（实测 1.2 秒），读完再画。
    #  -Refresh 重新读（改完刷新率之后）；换肤重画不带参数，用上次读到的。
    param([switch]$Refresh)
    $root = $Script:UI.MaintainPanel
    if ($Refresh -or $null -eq $Script:MaintData) {
        if ($Script:MaintBusy) { return }
        $Script:MaintBusy = $true
        if ($null -eq $Script:MaintData) {
            $root.Children.Clear()
            $root.Children.Add((New-TextBlock -Text '正在读取显示器和硬盘信息…' -Size 13 -Color 'TextDim')) | Out-Null
        }
        Start-BgWork 'maintain' {
            @{ Cur = (Get-CurrentDisplayMode); Opts = @(Get-DisplayRefreshOptions); Disks = @(Get-DiskHealthReport)
               Vols = @(Get-VolumesToOptimize); Auto = [bool](Test-AutoCleanEnabled) }
        } -OnDone {
            param($r)
            $Script:MaintBusy = $false
            if ($null -eq $r) { return }
            $Script:MaintData = $r
            Build-MaintainUI
        }
        return
    }
    $md = $Script:MaintData
    $root.Children.Clear()
    $p = $root

    function Add-Sec {
        <# 开一张新卡，之后往 $p 里加的东西都进这张卡 #>
        param([string]$Title, [string]$Aside = '', [bool]$First = $false, [string]$Icon = '')
        $prev = (Get-Variable -Name p -Scope 1).Value
        if ($prev -ne $root) { Close-CardRows $prev }
        $c = New-Card -Title $Title -Aside $Aside -Icon $Icon
        $c.Card.Margin = New-Thick 0 $(if ($First) { 0 } else { 16 }) 0 0
        $root.Children.Add($c.Card) | Out-Null
        Set-Variable -Name p -Value $c.Body -Scope 1
    }

    # ==================== 例行处置 ====================
    Add-Sec -Title '例行处置' -Aside '每月一次就够' -First $true -Icon 'CalendarCheckOutline'

    $r1 = New-ActRow -Name '一键日常维护' `
        -Note '清垃圾 + 刷新 DNS + 优化系统盘，一条龙。不会改任何性能设置，也不碰你的文件。'
    $bAll = New-ToolButton -Text '开始维护' -OnClick { Invoke-WithDone $this { Invoke-DailyMaintenance } }
    try { $bAll.Style = $Script:Window.FindResource('ButtonPrimary') } catch { }
    # ★ 别给按钮加上下 Padding ★ 要改高度改 Height（design.md 4.3）
    $bAll.Margin = New-Thick 0
    $r1.Slot.Children.Add($bAll) | Out-Null
    $p.Children.Add($r1.Row) | Out-Null

    $r2 = New-ActRow -Name '每周自动清理' `
        -Note '建一个计划任务，每周日 12:00 在后台静默跑一遍「垃圾清理」页的推荐项。不弹窗、不影响你用电脑、不碰性能设置。人不在电脑前错过了，下次开机自动补跑。'
    $cbAuto = New-Object System.Windows.Controls.CheckBox
    $cbAuto.Style = $Script:Window.FindResource('SwitchBox')
    $cbAuto.Content = '开启'
    $cbAuto.FontSize = 13
    $cbAuto.VerticalAlignment = 'Center'
    $cbAuto.IsChecked = [bool]$md.Auto
    $cbAuto.Add_Click({
            if ($this.IsChecked) {
                $ok = Enable-AutoClean -ScriptPath $PSCommandPath
                if ($ok) { $Script:MaintData.Auto = $true; Set-Status '已开启每周自动清理（每周日 12:00）' }
                else { $this.IsChecked = $false; Show-Msg -Text '创建计划任务失败，详见日志页。' | Out-Null }
            } else {
                Disable-AutoClean | Out-Null
                $Script:MaintData.Auto = $false
                Set-Status '已关闭每周自动清理'
            }
        })
    $r2.Slot.Children.Add($cbAuto) | Out-Null
    $p.Children.Add($r2.Row) | Out-Null

    # ==================== 显示器 ====================
    # 买了高刷屏却还跑在 60Hz 非常常见（换线、重装驱动、接新屏都会退回去）。
    # 对 FPS 玩家来说这个差距比任何注册表优化都大，所以排在第二位。
    $cur = $md.Cur
    $opts = @($md.Opts)
    if ($cur -and $opts.Count -gt 0) {
        $maxHz = $opts[0]
        Add-Sec -Title '显示器' -Aside ("{0} × {1}" -f $cur.Width, $cur.Height) -Icon 'Monitor'
        $p.Children.Add((New-RptHeader -First '项目')) | Out-Null

        # 没跑满最高刷新率 = 没达到参考范围，正是法定墨该管的那一件事
        $low = ($cur.Hz -lt $maxHz)
        $rHz = New-RptRow -Name '刷新率' -Result ([string]$cur.Hz) -Mark $(if ($low) { '↓' } else { '' }) `
            -Ref ("最高 {0}" -f $maxHz) -Unit 'Hz' `
            -Note $(if ($low) {
                "这套「显示器 + 线 + 显卡」最高能跑 $maxHz Hz —— 现在没跑满。"
            } else {
                "已经是这套配置能跑的最高刷新率。"
            })
        Set-RangeBar $rHz.Bar -Value $cur.Hz -Max $maxHz -Lo $maxHz -Abnormal $low
        foreach ($hz in $opts) {
            $b = New-ToolButton -Text ("{0} Hz" -f $hz) -Tag $hz -OnClick { Invoke-SetRefresh $this.Tag }
            $b.Margin = New-Thick 0
            if ($hz -eq $cur.Hz) {
                $b.IsEnabled = $false
                $b.Content = "{0} Hz（当前）" -f $hz
            } elseif ($hz -eq $maxHz) {
                # 一屏只许一个主按钮（「开始维护」），这里靠「（最高）」三个字点明
                $b.Content = "{0} Hz（最高）" -f $hz
            }
            Add-RptAct $rHz $b
        }
        $p.Children.Add($rHz.Row) | Out-Null

        $t15 = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text '切换后会弹一个 15 秒倒计时确认框。万一切完黑屏或花屏，什么都别动，倒计时结束会自动切回原来的设置 —— 和 Windows 自己改分辨率时的行为一样。'
        $t15.Margin = New-Thick 0 8 0 0
        $p.Children.Add($t15) | Out-Null
    }

    # ==================== 硬盘健康 ====================
    $disks = @($md.Disks)
    if ($disks.Count -gt 0) {
        Add-Sec -Title '硬盘健康' -Aside '读盘自己记的健康日志' -Icon 'Harddisk'
        # 量程那一列画的是什么就叫什么：固态是「剩余寿命」，机械是「通电时长」 —— 别再笼统叫「占了多少」
        $hasLife = @($disks | Where-Object { $null -ne $_.Life }).Count -gt 0
        $hasHours = @($disks | Where-Object { $null -eq $_.Life -and $null -ne $_.Hours -and $_.Media -ne '固态' }).Count -gt 0
        $barName = if ($hasLife -and -not $hasHours) { '剩余多少' } elseif ($hasHours -and -not $hasLife) { '用了多久' } else { '读数' }
        $p.Children.Add((New-RptHeader -First '硬盘' -Bar $barName)) | Out-Null
        foreach ($d in $disks) {
            $abn = ($d.Level -ne '良好')
            $mark = switch ($d.Level) { '严重' { '↑↑' } '建议' { '↑' } default { '' } }

            # 固态看剩余寿命，机械看通电时长 —— 各有各的参考范围。
            # ★ v6.2：统一说「剩余寿命」★ 以前写「0 % 寿命」，实际是「已用 0%」，朋友读成了「寿命只剩 0」。
            # 读不到 / 对不上就只报「—」并写清原因，不编数字。
            $lo = $null; $hi = $null
            if ($null -ne $d.Life) {
                $val = [double]$d.Life; $max = 100; $lo = 30
                $res = [string]$d.Life; $ref = '> 30'; $unit = '%'; $nobar = $false
            } elseif ($null -ne $d.Hours -and $d.Media -ne '固态') {
                $val = [double]$d.Hours; $max = 44000; $hi = 35000
                $res = [string]$d.Hours; $ref = '< 35000'; $unit = '小时'; $nobar = $false
            } else {
                $val = $null; $max = 100
                $res = '—'; $ref = ''; $unit = ''; $nobar = $true
                if (-not $abn) { $mark = '—' }
            }

            $extra = @($d.Media, $d.Size)
            if ($null -ne $d.Life) { $extra += "剩余寿命 $($d.Life)%" }
            elseif ($d.LifeWhy) { $extra += $d.LifeWhy }
            if ($null -ne $d.Hours -and $d.Hours -gt 0 -and $res -ne [string]$d.Hours) { $extra += "已通电 $($d.Hours) 小时" }
            if ($null -ne $d.WrittenTB) { $extra += "累计写入 $($d.WrittenTB) TB" }
            if ($null -ne $d.Temp -and $d.Temp -gt 0) { $extra += "$($d.Temp) °C" }
            if ($d.Verdict -ne '正常' -and $d.Verdict -notlike '健康*') { $extra += $d.Verdict }

            $rd = New-RptRow -Name $d.Name -Result $res -Mark $mark -Ref $ref -Unit $unit `
                -Note ($extra -join '   ·   ') -NoBar $nobar
            if (-not $nobar) { Set-RangeBar $rd.Bar -Value $val -Max $max -Lo $lo -Hi $hi -Abnormal $abn }
            $p.Children.Add($rd.Row) | Out-Null
        }
    }

    # ==================== 磁盘优化 ====================
    $vols = @($md.Vols)
    if ($vols.Count -gt 0) {
        Add-Sec -Title '磁盘优化' -Aside '半年一次' -Icon 'Speedometer'
        $sd = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text '自动认介质：固态做 TRIM（恢复写入速度），机械做碎片整理。不会对固态盘做碎片整理 —— 那只会白白消耗寿命。'
        $sd.Margin = New-Thick 0 0 0 4
        $p.Children.Add($sd) | Out-Null
        foreach ($v in $vols) {
            $rv = New-ActRow -Name ("{0}:   {1}" -f $v.Letter, $(if ($v.IsSSD) { '固态' } else { '机械' })) `
                -Note ("{0} 可用 / 共 {1}" -f (Format-Size $v.Free), (Format-Size $v.Size))
            $bv = New-ToolButton -Text $(if ($v.IsSSD) { '执行 TRIM' } else { '碎片整理' }) -Tag $v -OnClick {
                $vv = $this.Tag
                Set-Status ("正在优化 {0} 盘，机械盘可能要几十分钟，请耐心等…" -f $vv.Letter)
                Sync-UI
                $ok = Invoke-DiskOptimize -DriveLetter $vv.Letter -IsSSD $vv.IsSSD
                Set-Status $(if ($ok) { "$($vv.Letter) 盘优化完成" } else { "$($vv.Letter) 盘优化失败，详见日志" })
            }
            $bv.Margin = New-Thick 0
            $rv.Slot.Children.Add($bv) | Out-Null
            $p.Children.Add($rv.Row) | Out-Null
        }
    }

    # ==================== 微信 / QQ 占用 ====================
    Add-Sec -Title '微信 / QQ 占用' -Aside '只统计，不删' -Icon 'ChatOutline'
    $rc = New-ActRow -Name '统计聊天软件占了多少空间' `
        -Note '这两个是国内 C 盘杀手的常客，几十个 GB 很常见。这里只统计不删 —— 聊天图片和文件是你的资料，该不该删只有你自己知道。「垃圾清理」页的微信/QQ 那一项只清纯缓存，绝不碰聊天内容。'
    $chatHost = New-Object System.Windows.Controls.StackPanel
    $bChat = New-ToolButton -Text '扫描占用' -Tag $chatHost -OnClick {
        $holder = $this.Tag
        Set-Status '正在统计微信 / QQ 占用…'
        Sync-UI
        $holder.Children.Clear()
        $rows = @(Get-ChatAppUsage)
        if ($rows.Count -eq 0) {
            $t = New-TextBlock -Text '没有找到微信或 QQ 的数据目录（可能没装，或者装在非默认位置）。' -Size 13 -Color 'TextDim' -Wrap $true
            $t.Margin = New-Thick 0 12 0 0
            $holder.Children.Add($t) | Out-Null
        } else {
            $holder.Children.Add((New-RptHeader -First '软件')) | Out-Null
            foreach ($r in $rows) {
                # 占用没有「参考范围」这回事 —— 多少算多只有用户自己知道，
                # 所以不给量程、不给阈值、不上标记。
                $gb = [math]::Round($r.Size / 1GB, 1)
                $rr = New-RptRow -Name $r.App -Result ([string]$gb) -Unit 'GB' -Note $r.Path -NoBar $true
                $holder.Children.Add($rr.Row) | Out-Null
            }
            $h = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text '嫌大的话用软件自带的清理挑着删：微信 → 设置 → 文件管理 → 清理微信存储空间；QQ → 设置 → 文件管理 → 清理。它们能按聊天对象和时间筛选，比无脑全删安全得多。'
            $h.Margin = New-Thick 0 12 0 0
            $holder.Children.Add($h) | Out-Null
        }
        Set-Status '统计完成'
    }
    $bChat.Margin = New-Thick 0
    $rc.Slot.Children.Add($bChat) | Out-Null
    $p.Children.Add($rc.Row) | Out-Null
    $p.Children.Add($chatHost) | Out-Null

    # ==================== 快捷工具 ====================
    # 上一版这里是五个光溜溜的按钮排一行，没写各自什么时候用 ——
    # 「刷新 DNS 缓存」对不懂的人等于一个不敢按的按钮。一项一行，写清场合。
    Add-Sec -Title '快捷工具' -Aside '藏得很深的系统功能' -Icon 'Toolbox'

    $tools = @(
        @{ N = '刷新 DNS 缓存'; B = '执行'
            D = '某个网站突然打不开但别的正常、刚换过 DNS、游戏登录服务器连不上但网页能开 —— 这三种情况试它。'
            A = {
                Clear-DnsCacheNow | Out-Null
                Show-Msg -Text "DNS 缓存已刷新。`r`n`r`n什么时候用它：某个网站突然打不开但别的正常、刚换过 DNS、游戏登录服务器连不上但网页能开。" | Out-Null
            } },
        @{ N = '重启资源管理器'; B = '重启'
            D = '任务栏卡住不响应、桌面图标刷不出来、右键菜单卡死的时候用。屏幕会黑闪一下，打开的文件夹窗口会关掉，不影响别的程序。'
            A = { Restart-ExplorerShell; Set-Status '资源管理器已重启' } },
        @{ N = '系统磁盘清理'; B = '打开'
            D = 'Windows 自带的 cleanmgr。本工具的「垃圾清理」页覆盖不到的项（比如旧的 Windows 更新备份）在它那儿。'
            A = { Start-Process 'cleanmgr.exe' -ArgumentList "/d $env:SystemDrive" -ErrorAction SilentlyContinue } },
        @{ N = '存储设置'; B = '打开'
            D = '看 C 盘被哪类文件占了多少，也能开「存储感知」让 Windows 自己定期清。'
            A = { Start-Process 'ms-settings:storagesense' -ErrorAction SilentlyContinue } },
        @{ N = '已安装程序'; B = '打开'
            D = '卸载软件的地方。不确定某个程序是什么，先别卸 —— 名字里带厂商驱动的多半是必需的。'
            A = { Start-Process 'ms-settings:appsfeatures' -ErrorAction SilentlyContinue } }
    )
    foreach ($t in $tools) {
        $rt = New-ActRow -Name $t.N -Note $t.D
        $bt = New-ToolButton -Text $t.B -OnClick $t.A
        $bt.Margin = New-Thick 0
        $bt.MinWidth = 80
        $rt.Slot.Children.Add($bt) | Out-Null
        $p.Children.Add($rt.Row) | Out-Null
    }
    $tip2 = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text '顺带一提：游戏里画面卡死、显卡驱动假死的时候，按 Win + Ctrl + Shift + B 可以直接重启显卡驱动，屏幕会黑一下然后恢复，不用重启电脑。这是 Windows 自带的快捷键，不需要本工具。'
    $tip2.Margin = New-Thick 0 12 0 0
    $p.Children.Add($tip2) | Out-Null
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
                    Start-ListEnter $Script:UI.BigFilePanel
                })) | Out-Null
    }
    # 结果区还空着就摆上空状态（换肤重建时也会走这儿，不会覆盖已有结果）
    if ($Script:UI.BigFilePanel -and $Script:UI.BigFilePanel.Children.Count -eq 0) { Set-BigFileEmpty }
}

function Set-BigFileEmpty {
    <# 右栏的空状态。空着一大片白什么也不说，是在浪费用户的一次注视。 #>
    $panel = $Script:UI.BigFilePanel
    if ($null -eq $panel) { return }
    $panel.Children.Clear()
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 0 28 0 0
    $t1 = New-TextBlock -Text '还没扫描' -Size 14 -Color 'TextMid'
    $sp.Children.Add($t1) | Out-Null
    $t2 = New-TextBlock -Wrap $true -Size 13 -Color 'TextDim' -Text '点上面的盘符开始。扫描期间可以切到别的页干活，结果出来会留在这儿。'
    $t2.Margin = New-Thick 0 8 0 0
    $sp.Children.Add($t2) | Out-Null
    $t3 = New-TextBlock -Wrap $true -Size 13 -Color 'TextDim' -Text '扫的是「超过 300MB 的文件」，最大的 40 个。WinSxS、回收站、系统卷信息这三处跳过 —— 它们的大小是假的（硬链接），或者有专门的清理入口。'
    $t3.Margin = New-Thick 0 16 0 0
    $sp.Children.Add($t3) | Out-Null
    $panel.Children.Add($sp) | Out-Null
}

function Invoke-BigFileScan {
    param([string]$Root)
    $panel = $Script:UI.BigFilePanel
    $panel.Children.Clear()
    $panel.Children.Add((New-TextBlock -Text '正在扫描，请稍候…' -Size 13 -Color 'TextDim')) | Out-Null
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
        $panel.Children.Add((New-TextBlock -Text ("{0} 里没有找到超过 300MB 的文件。" -f $Root) -Size 13 -Color 'TextDim' -Wrap $true)) | Out-Null
        Set-Status '扫描完成'
        return
    }

    $hint = New-TextBlock -Size 13 -Color 'TextDim' -Wrap $true -Text '点任意一行会在资源管理器里定位到它。删之前想清楚：大文件里有很多是系统必需的（pagefile.sys 虚拟内存、hiberfil.sys 休眠文件、install.wim 等），别乱删。游戏安装包、下载的视频、旧的备份文件才是该清的。'
    $hint.Margin = New-Thick 0 0 0 12
    $panel.Children.Add($hint) | Out-Null

    # 列名 + 表头线。四十个文件是一张表，不是四十张卡片 ——
    # 卡片会让每个文件看起来都是一件独立的事，而用户要做的是**比大小**。
    Add-ColHeader -Panel $panel -First '文件' -Cols @(@{ T = '大小'; W = 96 }) -Indent 12

    foreach ($f in $files) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = [System.Windows.Media.Brushes]::Transparent
        $b.CornerRadius = New-Corner 8
        $b.Padding = New-Thick 12 8 12 8
        $b.Cursor = 'Hand'
        $b.Tag = $f.Path
        $b.Add_MouseLeftButtonUp({
                try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $this.Tag) } catch { }
            })
        # 可点的行：圆角 8，悬停浮出 CardHover（design.md 4.4 列表卡）
        Add-Interactive -Border $b -BgNormal 'Transparent' -BgHover 'CardHover'

        $g = New-Object System.Windows.Controls.Grid
        $cdA = New-Object System.Windows.Controls.ColumnDefinition
        $cdA.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $g.ColumnDefinitions.Add($cdA)
        $cdB = New-Object System.Windows.Controls.ColumnDefinition
        $cdB.Width = New-Object System.Windows.GridLength 96.0
        $g.ColumnDefinitions.Add($cdB)

        $sp = New-Object System.Windows.Controls.StackPanel
        $leaf = try { [System.IO.Path]::GetFileName($f.Path) } catch { $f.Path }
        if (-not $leaf) { $leaf = $f.Path }
        $sp.Children.Add((New-TextBlock -Text $leaf -Size 14 -Color 'TextMain' -Wrap $true)) | Out-Null
        $dir = try { [System.IO.Path]::GetDirectoryName($f.Path) } catch { '' }
        if ($dir) {
            $t = New-TextBlock -Text $dir -Size 12 -Color 'TextDim' -Wrap $true
            $t.Margin = New-Thick 0 4 0 0
            $sp.Children.Add($t) | Out-Null
        }
        $g.Children.Add($sp) | Out-Null

        # ★ 表格数位 ★ 不加的话 1 比 8 窄，整列大小对不齐，比大小就费劲
        $sz = New-TextBlock -Text (Format-Size $f.Size) -Size 14 -Color 'TextMain' -Bold $true
        $sz.TextAlignment = 'Right'
        $sz.VerticalAlignment = 'Center'
        [System.Windows.Documents.Typography]::SetNumeralAlignment($sz, 'Tabular')
        [System.Windows.Controls.Grid]::SetColumn($sz, 1)
        $g.Children.Add($sz) | Out-Null

        $b.Child = $g
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
        '无用'     { return 'TextDim' }
        '已知打扰' { return 'TextMid' }
        default    { return 'TextDim' }
    }
}

function Set-InspectEmpty {
    <# 扫描前的左栏。空着一大片白什么也不说，是在浪费用户的一次注视。 #>
    $p = $Script:UI.InspectPanel
    if ($null -eq $p -or $p.Children.Count -gt 0) { return }
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 0 32 0 0
    $t1 = New-TextBlock -Text '还没扫描' -Size 14 -Color 'TextMid'
    $sp.Children.Add($t1) | Out-Null
    foreach ($line in @(
            '点上面的「开始扫描」。全程只读不改，扫完你再决定关谁。',
            '会扫这些地方：计划任务、注册表 Run、启动文件夹、服务、WMI 事件订阅 —— 也就是所有「能让一个程序自己跑起来」的位置。',
            '扫完按可疑程度排序：会弹黑框的排最前，然后是高危、可疑，最后是「无用」和「已知打扰」（不危险，只是没必要留着）。',
            '扫不出来也别慌 —— 定期弹的黑框多半来自某个已经在跑的程序，那种要用右边的「抓现行」。')) {
        $t = New-TextBlock -Wrap $true -Size 13 -Color 'TextDim' -Text $line
        $t.Margin = New-Thick 0 12 0 0
        $sp.Children.Add($t) | Out-Null
    }
    $p.Children.Add($sp) | Out-Null
}

function Invoke-Inspect {
    $Script:UI.InspectPanel.Children.Clear()
    $Script:UI.InspectPanel.Children.Add((New-TextBlock -Text '正在扫描，请稍候…' -Size 13 -Color 'TextDim')) | Out-Null
    Sync-UI
    Set-Busy $true
    $Script:Findings = @(Get-SuspiciousFindings -OnProgress { param($m) Set-Status $m; Sync-UI })
    Set-Busy $false
    Show-Findings
}

function Show-Findings {
    <#
      结果列表。★ 一条 = 一行，不是一张卡 ★
        上一版每条是「圆角卡 + 3px 彩色左边条 + 三个彩色药丸标签」。
        四个危险档各一种颜色，满页都是彩色 —— 真正的高危反而不显眼了。
        改成和全app一样的判读语法：左边一个标记，只有该上墨的才上墨。
          ↑↑  会弹黑框，或高危
          ↑   可疑
          （空）无用 / 已知打扰 —— 不危险，只是没必要留着
    #>
    $p = $Script:UI.InspectPanel
    $p.Children.Clear()

    $list = $Script:Findings
    if ($Script:InspectFilterOn) { $list = @($list | Where-Object { $_.Flash -or $_.Level -eq '高危' }) }

    $n弹框 = @($Script:Findings | Where-Object { $_.Flash }).Count
    $n高危 = @($Script:Findings | Where-Object Level -eq '高危').Count
    $n可疑 = @($Script:Findings | Where-Object Level -eq '可疑').Count
    $n无用 = @($Script:Findings | Where-Object Level -eq '无用').Count
    $n打扰 = @($Script:Findings | Where-Object Level -eq '已知打扰').Count
    $Script:UI.InspectSummary.Text = ("会弹黑框 {0} · 高危 {1} · 可疑 {2} · 无用 {3} · 已知打扰 {4}" -f $n弹框, $n高危, $n可疑, $n无用, $n打扰)

    if ($Script:Findings.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 13 -Color 'TextMid' -Text "扫描完成，没有发现可疑项。`r`n`r`n如果还是会弹黑框，用右边的「抓现行」：先点「开启持续记录」，等下次黑框出现之后马上回来点「查看进程记录」，就能看到那一刻到底是谁在跑。")) | Out-Null
        Set-Status '扫描完成，没有发现可疑项'
        return
    }
    if ($list.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 13 -Color 'TextMid' -Text '按当前筛选条件没有内容 —— 也就是说没有「高危」和「会弹黑框」的项，这是好事。点「显示全部」可以看其余条目。')) | Out-Null
        return
    }

    # 列名 + 表头线
    Add-ColHeader -Panel $p -First '可疑项' -Cols @(@{ T = '判定'; W = 96 }) -Indent 34

    foreach ($f in $list) {
        # 只有两档会上墨：会弹黑框 / 高危 -> ↑↑，可疑 -> ↑
        $mark = ''
        if ($f.Flash -or $f.Level -eq '高危') { $mark = '↑↑' }
        elseif ($f.Level -eq '可疑') { $mark = '↑' }
        $abn = [bool]$mark

        $row = New-Object System.Windows.Controls.Border
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.BorderBrush = Get-Brush $Script:CARD_BORDER
        $row.BorderThickness = New-Thick 0 0 0 1
        # 右边留 14px：竖滚动条要占位，不留的话「判定」那一列会被裁掉
        $row.Padding = New-Thick 0 12 16 12

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(34.0, 0.0, 96.0)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 0) {
                New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            } else {
                New-Object System.Windows.GridLength $w
            }
            $g.ColumnDefinitions.Add($cd)
        }

        # --- 标记 ---
        $mk = New-TextBlock -Text $mark -Size 14 -Color $(if ($abn) { '#8A5750' } else { 'TextDim' })
        if ($abn) { $mk.FontWeight = 'SemiBold' }
        $mk.VerticalAlignment = 'Top'
        $mk.Margin = New-Thick 0 0 0 0
        $g.Children.Add($mk) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)

        $nm = New-TextBlock -Text $f.Name -Size 14 -Color 'TextMain' -Wrap $true
        if ($abn) { $nm.FontWeight = 'SemiBold' }
        $sp.Children.Add($nm) | Out-Null

        # 来源 + 会不会弹黑框，一行小字说清，不用药丸
        $kindBits = @($f.Kind)
        if ($f.Extra) { $kindBits += $f.Extra }
        $kd = New-TextBlock -Text ($kindBits -join '   ·   ') -Size 13 -Color 'TextDim' -Wrap $true
        $kd.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($kd) | Out-Null

        if ($f.Command) {
            # 原始命令行。底色是「下沉面」—— 报告单上引用原始值就是这么做的，
            # 不换字体：随包字体的意义就在于不依赖系统装了什么，
            # 而且 craft-floor 拒绝「拿等宽当技术感的戏服」。
            $cb = New-Object System.Windows.Controls.Border
            $cb.Background = Get-Brush 'SurfaceSunken'
            $cb.CornerRadius = New-Corner 8
            $cb.Padding = New-Thick 12 8 12 8
            $cb.Margin = New-Thick 0 8 0 0
            $ct = New-TextBlock -Text $f.Command -Size 12 -Color 'TextMid' -Wrap $true
            [System.Windows.Documents.Typography]::SetNumeralAlignment($ct, 'Tabular')
            $cb.Child = $ct
            $sp.Children.Add($cb) | Out-Null
        }

        foreach ($r in $f.Reasons) {
            $rt = New-TextBlock -Text ('· ' + $r) -Size 13 -Color 'TextMid' -Wrap $true
            $rt.Margin = New-Thick 0 8 0 0
            $sp.Children.Add($rt) | Out-Null
        }

        # 建议。★ 只有真该警觉的那两档上墨 ★
        # 建议只在最高档上墨。「可疑」也上墨的话一页下来红字太多，真高危就不跳了。
        $ad = New-TextBlock -Text $f.Advice -Size 13 -Color $(if ($mark -eq '↑↑') { '#8A5750' } else { 'TextMid' }) -Wrap $true
        $ad.Margin = New-Thick 0 8 0 0
        $sp.Children.Add($ad) | Out-Null

        # ---- 处置 ----
        if ($f.Target.Type -eq 'WmiConsumer') {
            $b = New-ToolButton -Text '删除这个 WMI 订阅' -Tag $f -OnClick {
                $ff = $this.Tag
                $r = Show-Msg -Text ("即将删除 WMI 事件订阅：`r`n$($ff.Name)`r`n`r`n注意：这一项删掉之后工具无法帮你恢复。`r`n而且删掉它只是切断了自动执行，真正的恶意文件还在硬盘上 ——`r`n删完请务必用 Windows Defender 做一次完全扫描。`r`n`r`n确定删除吗？") -Title '确认删除' -Kind AskWarn
                if ($r -ne 'Yes') { return }
                if (Set-FindingEnabled -Finding $ff -Enabled $false) { $this.IsEnabled = $false; $this.Content = '已删除' }
            }
            $b.Margin = New-Thick 0 12 0 0
            $sp.Children.Add($b) | Out-Null
        } elseif ($f.Target.Type -ne 'None') {
            $cbx = New-Object System.Windows.Controls.CheckBox
            $cbx.Style = $Script:Window.FindResource('SwitchBox')
            $cbx.Content = '保持启用（关掉 = 禁用它，随时可以再打开）'
            $cbx.FontSize = 13
            $cbx.Margin = New-Thick 0 12 0 0
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
            $t = New-TextBlock -Text '这一项工具不会自动改动 —— 涉及系统核心设置，误改会开不了机。请先杀毒，确认之后手动处理。' -Size 13 -Color 'TextDim' -Wrap $true
            $t.Margin = New-Thick 0 12 0 0
            $sp.Children.Add($t) | Out-Null
        }

        $g.Children.Add($sp) | Out-Null

        # --- 判定（右列，和列名对齐）---
        # 会弹黑框的那条就把「会弹黑框」写在判定里 ——
        # 标记是 ↑↑ 而判定写「可疑」，两处对不上，读者会先以为自己看错了。
        $lvText = if ($f.Flash) { '会弹黑框' } else { $f.Level }
        $lv = New-TextBlock -Text $lvText -Size 13 -Color $(if ($abn) { '#8A5750' } else { 'TextDim' })
        if ($abn) { $lv.FontWeight = 'SemiBold' }
        $lv.TextAlignment = 'Right'
        $lv.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetColumn($lv, 2)
        $g.Children.Add($lv) | Out-Null

        $row.Child = $g
        $p.Children.Add($row) | Out-Null
    }
    Close-CardRows $p
    Set-Status ("扫描完成：" + $Script:UI.InspectSummary.Text)
}

# ---- 抓现行：实时进程监控 ----
$Script:WatchTimer = $null

function New-ProcRow {
    <# 一条进程记录的卡片。会弹黑框的用醒目颜色标出来。 #>
    param([string]$Head, [string]$Sub, [string]$Cmd, [bool]$Hot)
    # 会弹黑框的那条铺卡其底（语义色：需要注意），其余灰底；不再用 3px 彩色左边条
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush $(if ($Hot) { '#EDE7D9' } else { 'SurfaceAlt' })
    $b.CornerRadius = New-Corner 8
    $b.Padding = New-Thick 12 8 12 8
    $b.Margin = New-Thick 0 0 0 4
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((New-TextBlock -Text $Head -Size 12 -Bold $true -Color $(if ($Hot) { '#89694F' } else { 'TextMid' }) -Wrap $true)) | Out-Null
    if ($Sub) {
        $t = New-TextBlock -Text $Sub -Size 11 -Color 'TextDim' -Wrap $true
        $t.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($t) | Out-Null
    }
    if ($Cmd) {
        $t2 = New-TextBlock -Text $Cmd -Size 11 -Color 'TextDim' -Wrap $true
        $t2.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($t2) | Out-Null
    }
    $b.Child = $sp
    return $b
}

function Start-LiveWatch {
    if (-not (Start-ProcWatch)) {
        Show-Msg -Text "实时监控启动失败。`r`n`r`n这个功能需要管理员权限（正常双击「电脑调优助手.exe」并在 UAC 弹窗点「是」即可）。`r`n`r`n如果还是不行，改用下面的「持续记录」，效果一样，而且关掉工具也在记。" | Out-Null
        return
    }
    $Script:UI.RecentRunPanel.Children.Clear()
    $Script:UI.RecentRunPanel.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color 'TextDim' -Text '监控已启动。现在正常用电脑，等黑框出现——出现的瞬间这里就会多出几条记录。带橙色标记的就是控制台进程（也就是黑框本身），看它的「父进程」是谁，那就是元凶。')) | Out-Null
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
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color 'TextDim' -Text '最近 3 小时没有记录到控制台进程。如果刚开启记录，要等下次弹窗之后再来看。')) | Out-Null
        Set-Status '就绪'
        return
    }
    $h = New-TextBlock -Wrap $true -Size 11 -Color 'TextDim' -Text '最近 3 小时内创建过的控制台进程（也就是黑框），按次数从多到少排。次数特别多的那条，基本就是你看到的规律性弹窗。重点看「父进程」——那是真正开出黑框的程序。'
    $h.Margin = New-Thick 0 0 0 12
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
        $t1 = New-TextBlock -Wrap $true -Size 12 -Color '#7A6B45' -Text '任务运行记录当前是【关闭】的，所以查不到历史。'
        $p.Children.Add($t1) | Out-Null
        $t2 = New-TextBlock -Wrap $true -Size 12 -Color 'TextMid' -Text @'
点上面的「开启运行记录」把它打开，然后：

1. 该干嘛干嘛，等下次黑框弹出来
2. 看到之后马上回到这里点「刷新记录」
3. 时间对得上的那一条，就是弹窗的元凶

这个记录只占几 MB，平时对性能没有影响。
'@
        $t2.Margin = New-Thick 0 12 0 0
        $p.Children.Add($t2) | Out-Null
        return
    }

    $runs = @(Get-RecentTaskRuns -Hours 24)
    if ($runs.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color 'TextDim' -Text '过去 24 小时没有任务运行记录。如果刚刚才开启记录，那要等下次任务运行才会有内容。')) | Out-Null
        return
    }

    $h = New-TextBlock -Wrap $true -Size 11 -Color 'TextDim' -Text '按最近运行时间排序。跑得特别频繁（次数很多）的那几条，最可能就是你看到的规律性弹窗。'
    $h.Margin = New-Thick 0 0 0 12
    $p.Children.Add($h) | Out-Null

    foreach ($r in $runs) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = Get-Brush 'SurfaceAlt'
        $b.CornerRadius = New-Corner 8
        $b.Padding = New-Thick 12 8 12 8
        $b.Margin = New-Thick 0 0 0 4
        $sp = New-Object System.Windows.Controls.StackPanel
        $col = if ($r.Count -ge 10) { '#7A6B45' } else { 'TextMid' }
        $sp.Children.Add((New-TextBlock -Text ("{0}   ·   24 小时内跑了 {1} 次" -f $r.Last.ToString('MM-dd HH:mm:ss'), $r.Count) -Size 12 -Bold $true -Color $col)) | Out-Null
        $t1 = New-TextBlock -Text $r.TaskName -Size 11 -Color 'TextMid' -Wrap $true
        $t1.Margin = New-Thick 0 4 0 0
        $sp.Children.Add($t1) | Out-Null
        if ($r.Exe) {
            $t2 = New-TextBlock -Text $r.Exe -Size 11 -Color 'TextDim' -Wrap $true
            $t2.Margin = New-Thick 0 4 0 0
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
    <#
      v6.2：收集硬件信息 + 体检在后台跑（实测 4~5 秒，原来这段时间界面是死的），跑完再画。
        -Refresh  重新体检（按钮 / F5）
        -Enter    画完之后右栏依次进场（用户点了才播）
      换肤重画时不带参数 —— 用上次的结果重画，不重新体检。
    #>
    param([switch]$Refresh, [switch]$Enter)
    if ($Refresh -or $null -eq $Script:HealthData) {
        if ($Script:HealthBusy) { return }
        $Script:HealthBusy = $true
        $Script:HealthEnter = [bool]$Enter
        Set-Busy $true
        Set-Status '正在收集硬件信息、做系统体检…（在后台做，界面照常能用）'
        if ($null -eq $Script:HealthData) {
            foreach ($pn in @($Script:UI.InfoPanel, $Script:UI.AdvicePanel)) {
                $pn.Children.Clear()
                $pn.Children.Add((New-TextBlock -Text '正在读取…' -Size 13 -Color 'TextDim')) | Out-Null
            }
        }
        Start-BgWork 'health' { @{ Report = @(Get-SystemReport); Advice = @(Get-HealthAdvice) } } -OnDone {
            param($r)
            $Script:HealthBusy = $false
            Set-Busy $false
            if ($null -eq $r) { Set-Status '体检没做完，详见日志页'; return }
            $Script:HealthData = $r
            Build-HealthUI
            # 启动时那次是自己跑的，不抢状态栏（状态栏那时写着「报告已出」）；用户点的才报
            if ($Script:HealthEnter) { Start-ListEnter $Script:UI.AdvicePanel; Set-Status '体检完成' }
        }
        return
    }
    $info = $Script:UI.InfoPanel
    $info.Children.Clear()
    $sb = New-Object System.Text.StringBuilder

    # ==================== 登记信息 ====================
    #   化验单最上面那一栏：姓名、年龄、送检科室。
    #   两列对齐（标签 | 值），细线分隔 —— 这样才扫得快。
    $info.Children.Add((New-RptSection -Title '受检机器' -Icon 'Laptop')) | Out-Null

    foreach ($row in @($Script:HealthData.Report)) {
        $b = New-Object System.Windows.Controls.Border
        $b.BorderBrush = Get-Brush $Script:CARD_BORDER
        $b.BorderThickness = New-Thick 0 0 0 1
        $b.Padding = New-Thick 0 12 0 12

        $g = New-Object System.Windows.Controls.Grid
        $cdK = New-Object System.Windows.Controls.ColumnDefinition
        $cdK.Width = New-Object System.Windows.GridLength 108.0
        $g.ColumnDefinitions.Add($cdK)
        $cdV = New-Object System.Windows.Controls.ColumnDefinition
        $cdV.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $g.ColumnDefinitions.Add($cdV)

        $k = New-TextBlock -Text $row.Key -Size 12 -Color 'TextDim' -Wrap $true
        $k.VerticalAlignment = 'Top'
        $g.Children.Add($k) | Out-Null

        $v = New-TextBlock -Text $row.Value -Size 13 -Color 'TextMain' -Wrap $true
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        [System.Windows.Controls.Grid]::SetColumn($v, 1)
        $g.Children.Add($v) | Out-Null

        $b.Child = $g
        $info.Children.Add($b) | Out-Null
        [void]$sb.AppendLine("$($row.Key)：$($row.Value)")
    }

    # ==================== 体检结论 ====================
    $apRoot = $Script:UI.AdvicePanel
    $apRoot.Children.Clear()
    $adviceCard = New-Card -Title '检验结论' -Aside '按性价比从高到低排' -Icon 'ClipboardCheckOutline'
    $apRoot.Children.Add($adviceCard.Card) | Out-Null
    $ap = $adviceCard.Body
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('===== 体检结论 =====')

    foreach ($a in @($Script:HealthData.Advice)) {
        # ★ 判读标记，不是彩色药丸 ★
        #   上一版每条是「圆角卡 + 整块底色 + 4px 彩色左边条 + 彩色标签」，
        #   三档各一种颜色，满屏都是色块 —— 真正「严重」的那条反而不跳。
        $mark = switch ($a.Level) { '严重' { '↑↑' } '建议' { '↑' } default { '' } }
        $abn = [bool]$mark

        $row = New-Object System.Windows.Controls.Border
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.BorderBrush = Get-Brush $Script:CARD_BORDER
        $row.BorderThickness = New-Thick 0 0 0 1
        $row.Padding = New-Thick 0 12 16 16

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(34.0, 0.0, 64.0)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 0) {
                New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            } else {
                New-Object System.Windows.GridLength $w
            }
            $g.ColumnDefinitions.Add($cd)
        }

        $mk = New-TextBlock -Text $mark -Size 14 -Color $(if ($abn) { '#8A5750' } else { 'TextDim' })
        if ($abn) { $mk.FontWeight = 'SemiBold' }
        $mk.VerticalAlignment = 'Top'
        $mk.Margin = New-Thick 0 0 0 0
        $g.Children.Add($mk) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $ttl = New-TextBlock -Text $a.Title -Size 14 -Color 'TextMain' -Wrap $true
        if ($abn) { $ttl.FontWeight = 'SemiBold' }
        $sp.Children.Add($ttl) | Out-Null
        $bd = New-TextBlock -Text (Format-Reflow $a.Text) -Size 13 -Color 'TextMid' -Wrap $true
        $bd.Margin = New-Thick 0 8 0 0
        $sp.Children.Add($bd) | Out-Null
        $g.Children.Add($sp) | Out-Null

        $lv = New-TextBlock -Text $a.Level -Size 13 -Color $(if ($abn) { '#8A5750' } else { 'TextDim' })
        if ($abn) { $lv.FontWeight = 'SemiBold' }
        $lv.TextAlignment = 'Right'
        $lv.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetColumn($lv, 2)
        $g.Children.Add($lv) | Out-Null

        $row.Child = $g
        $ap.Children.Add($row) | Out-Null

        [void]$sb.AppendLine()
        [void]$sb.AppendLine("[$($a.Level)] $($a.Title)")
        [void]$sb.AppendLine($a.Text)
    }
    Close-CardRows $ap
    $Script:LastReportText = $sb.ToString()
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

    $t = New-TextBlock -Text '帧数瓶颈诊断' -Size 16 -Bold $true
    $t.Margin = New-Thick 0 0 0 8
    $ap.Children.Add($t) | Out-Null
    $sub = New-TextBlock -Size 12 -Color 'TextMid' -Wrap $true -Text (
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
            '信息'   { @{ Line = 'TextMid'; Bg = 'SurfaceSunken' } }
            default  { @{ Line = '#556B54'; Bg = '#E7EBE4' } }
        }
        # 状态卡（design.md 4.4）：白卡 + 左上语义徽章。
        #   不再是「整块语义底色 + 4px 彩色左边条」—— 满屏色块时真正的瓶颈反而不显眼
        $card = New-Object System.Windows.Controls.Border
        $card.Background      = Get-Brush 'Card'
        $card.BorderBrush     = Get-Brush 'Stroke'
        $card.BorderThickness = New-Thick 1
        $card.CornerRadius    = New-Corner 12
        $card.Padding         = New-Thick 20 16 20 16
        $card.Margin          = New-Thick 0 0 0 12

        $sp = New-Object System.Windows.Controls.StackPanel
        $h  = New-Object System.Windows.Controls.StackPanel
        $h.Orientation = 'Horizontal'
        $h.Children.Add((New-Badge -Text $d.Level -Fg $c.Line -Bg (Get-TintBg $c.Line))) | Out-Null
        $sp.Children.Add($h) | Out-Null
        $ttl = New-TextBlock -Text $d.Title -Size 14 -Bold $true -Wrap $true
        $ttl.Margin = New-Thick 0 8 0 8
        $sp.Children.Add($ttl) | Out-Null
        $sp.Children.Add((New-TextBlock -Text (Format-Reflow $d.Text) -Size 13 -Color 'TextMid' -Wrap $true)) | Out-Null
        $card.Child = $sp
        $ap.Children.Add($card) | Out-Null
    }

    $n = @($diag | Where-Object { $_.Level -eq '瓶颈' }).Count
    Set-Busy $false
    if ($n -gt 0) { Set-Status ("帧数诊断完成 —— 发现 {0} 个真正的瓶颈，看红色那几条" -f $n) }
    else          { Set-Status '帧数诊断完成 —— 没发现硬件层面的瓶颈，看「已到顶」那几条的说明' }
}

function Build-AdviceCards {
    <#
      把一串 @{ Kind; Title; Text } 画成右边那一列卡片。
      超频陪练和厂商软件两页共用这个 —— 卡片长相和帧数诊断保持一致，
      用户不用再学一套新的看法。
    #>
    param([string]$Head, [string]$Sub, $Items)

    $ap = $Script:UI.AdvicePanel
    $ap.Children.Clear()

    $t = New-TextBlock -Text $Head -Size 16 -Bold $true
    $t.Margin = New-Thick 0 0 0 8
    $ap.Children.Add($t) | Out-Null
    if ($Sub) {
        $s = New-TextBlock -Text $Sub -Size 12 -Color 'TextMid' -Wrap $true
        $s.Margin = New-Thick 0 0 0 12
        $ap.Children.Add($s) | Out-Null
    }

    foreach ($d in @($Items)) {
        # 颜色沿用全局那套语义色：红=当心、卡其=要动手、蓝=背景、绿=流程
        $c = switch ($d.Kind) {
            '当心' { @{ Line = '#8A5750'; Bg = '#EFE3E0' } }
            '动手' { @{ Line = '#7A6B45'; Bg = '#F0EADC' } }
            '步骤' { @{ Line = '#556B54'; Bg = '#E7EBE4' } }
            default { @{ Line = 'TextMid'; Bg = 'SurfaceSunken' } }
        }
        # 状态卡（design.md 4.4）：白卡 + 左上语义徽章。
        #   不再是「整块语义底色 + 4px 彩色左边条」—— 满屏色块时真正的瓶颈反而不显眼
        $card = New-Object System.Windows.Controls.Border
        $card.Background      = Get-Brush 'Card'
        $card.BorderBrush     = Get-Brush 'Stroke'
        $card.BorderThickness = New-Thick 1
        $card.CornerRadius    = New-Corner 12
        $card.Padding         = New-Thick 20 16 20 16
        $card.Margin          = New-Thick 0 0 0 12

        $sp = New-Object System.Windows.Controls.StackPanel
        $h = New-Object System.Windows.Controls.StackPanel
        $h.Orientation = 'Horizontal'
        $h.Children.Add((New-Badge -Text $d.Kind -Fg $c.Line -Bg (Get-TintBg $c.Line))) | Out-Null
        $sp.Children.Add($h) | Out-Null
        $ttl = New-TextBlock -Text $d.Title -Size 14 -Bold $true -Wrap $true
        $ttl.Margin = New-Thick 0 8 0 8
        $sp.Children.Add($ttl) | Out-Null
        $sp.Children.Add((New-TextBlock -Text (Format-Reflow $d.Text) -Size 13 -Color 'TextMid' -Wrap $true)) | Out-Null
        $card.Child = $sp
        $ap.Children.Add($card) | Out-Null
    }
}

function Build-OcCoachUI {
    <#
      超频陪练。

      【这一页不改任何东西】 它只认卡、讲清每个滑块是干什么的、
        给出一步步的试法。真正的调节交给 Afterburner / AMD 驱动面板。
        理由写在 Modules\Overclock.ps1 开头。
    #>
    Set-Busy $true
    Set-Status '正在认显卡…'
    Sync-UI
    Build-AdviceCards -Head '超频陪练' -Items (Get-OcPlan) -Sub (
        '这一页不会动你的显卡 —— 它只告诉你每个滑块是干什么的、从多少起步、' +
        '怎么一步步试、崩了怎么办。真正的调节在 Afterburner / 显卡驱动面板里做。')
    Set-Busy $false
    Set-Status '超频陪练 —— 一次只动一个滑块，每动一次就测一次；先看「步骤」那一条'
    Write-Log '打开了超频陪练页（只读，未修改任何设置）' '信息'
}

function Build-VendorUI {
    <# 厂商软件识别：认出机器品牌，告诉用户该装哪个厂商工具、它管什么 #>
    Set-Busy $true
    Set-Status '正在识别机器品牌…'
    Sync-UI
    Build-AdviceCards -Head '该装哪个厂商工具' -Items (Get-VendorSoftware) -Sub (
        '这个工具动的是 Windows 这一层；风扇转速、功耗墙、充电上限这些在硬件那一层，' +
        '得靠厂商自己的工具。两边分工清楚了，效果才不打折。')
    Set-Busy $false
    Set-Status '厂商工具建议 —— 笔记本尤其要看最后一条「分工」'
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
$Script:UI.JumpAggressive.Add_MouseLeftButtonUp({ Invoke-JumpToCategory '激进优化' })
$Script:UI.CleanSearch.Add_TextChanged({ Update-CleanFilter })
$Script:UI.BtnApplySelected.Add_Click({ Invoke-WithDone $this { Invoke-ApplyTweaks (Get-CheckedTweaks) } })
$Script:UI.BtnRevertSelected.Add_Click({ Invoke-RevertTweaks (Get-CheckedTweaks) })
$Script:UI.BtnRevertAll.Add_Click({
        $applied = @($Script:Tweaks | Where-Object { (Test-TweakAvailable $_) -and (Test-TweakApplied $_) })
        if ($applied.Count -eq 0) {
            Show-Msg -Text '当前没有任何已应用的优化项需要还原。' | Out-Null
            return
        }
        Invoke-RevertTweaks $applied
    })

$Script:UI.BtnRestorePoint.Add_Click({
        Set-Status '正在创建系统还原点，可能需要 10~60 秒…'
        $ok = New-SystemRestorePoint -Description 'PC调优助手-手动创建'
        if ($ok) {
            Show-Msg -Text '系统还原点创建成功。万一出问题，可以在「设置 → 系统 → 恢复」里回滚到这个时间点。' | Out-Null
        } else {
            Show-Msg -Text "创建还原点失败。`r`n`r`n最常见的原因是系统保护被关闭了。打开方法：`r`n控制面板 → 系统 → 系统保护 → 选中 C 盘 → 配置 → 启用系统保护。`r`n`r`n不影响本工具的使用（工具自己有完整的备份/还原机制）。" | Out-Null
        }
        Set-Status '就绪'
    })

$Script:UI.BtnScanJunk.Add_Click({ Invoke-ScanJunk })
$Script:UI.BtnClean.Add_Click({ Invoke-WithDone $this { Invoke-CleanSelected } })
$Script:UI.BtnPickCleanRec.Add_Click({
        foreach ($it in $Script:CleanItems) { $Script:CleanRows[$it.Id].Check.IsChecked = [bool]$it.Recommended }
        Update-CleanSelCount
    })
$Script:UI.BtnPickCleanNone.Add_Click({
        foreach ($row in $Script:CleanRows.Values) { $row.Check.IsChecked = $false }
        Update-CleanSelCount
    })

$Script:UI.BtnRefreshStartup.Add_Click({ Build-StartupUI -Refresh -Enter })

$Script:UI.BtnInspect.Add_Click({ Invoke-Inspect; Start-ListEnter $Script:UI.InspectPanel })
$Script:UI.BtnInspectFilter.Add_Click({
        $Script:InspectFilterOn = -not $Script:InspectFilterOn
        $this.Content = if ($Script:InspectFilterOn) { '显示全部' } else { '只看会弹黑框的' }
        if ($Script:Findings.Count -gt 0) { Show-Findings; Start-ListEnter $Script:UI.InspectPanel }
    })
$Script:UI.BtnRecentRuns.Add_Click({ Build-RecentRuns; Start-ListEnter $Script:UI.RecentRunPanel; Set-Status '任务运行记录已刷新' })
$Script:UI.BtnCopyLog.Add_Click({
        # 表格不像 TextBox 能直接框选复制，所以给一个「全拿走」的出口
        try {
            [System.Windows.Clipboard]::SetText(($Script:LogLines -join [Environment]::NewLine))
            Set-Status ('已复制 {0} 条日志到剪贴板' -f $Script:LogLines.Count)
        } catch { Set-Status '复制失败，日志文件在备份文件夹里' }
    })
$Script:UI.BtnWatchStart.Add_Click({ Start-LiveWatch })
$Script:UI.BtnWatchStop.Add_Click({ Stop-LiveWatch })
$Script:UI.BtnProcLog.Add_Click({ Show-ProcLog; Start-ListEnter $Script:UI.RecentRunPanel })
$Script:UI.BtnProcAudit.Add_Click({
        if (Test-ProcAuditEnabled) {
            $r = Show-Msg -Text ("「持续记录」当前是开启的。`r`n`r`n要关掉吗？`r`n（排查完建议关掉——开着的时候每创建一个进程都会写一条安全日志，量很大。）") -Title '持续记录' -Kind Ask
            if ($r -eq 'Yes') { Disable-ProcAudit | Out-Null; $this.Content = '开启持续记录'; Set-Status '持续记录已关闭' }
            return
        }
        $r = Show-Msg -Text (@"
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
"@) -Title '开启持续记录' -Kind Ask
        if ($r -ne 'Yes') { return }
        if (Enable-ProcAudit) {
            $this.Content = '关闭持续记录'
            Show-Msg -Text "已开启。`r`n`r`n接下来正常用电脑，等黑框出现过几次之后，回到这一页点「查看进程记录」。`r`n`r`n排查完记得回来把它关掉。" | Out-Null
            Set-Status '持续记录已开启'
        } else {
            Show-Msg -Text '开启失败，详见日志页。' | Out-Null
        }
    })
$Script:UI.BtnEnableTaskLog.Add_Click({
        if (Test-TaskLogEnabled) {
            Show-Msg -Text '运行记录本来就是开着的，直接点「刷新记录」即可。' | Out-Null
            return
        }
        if (Enable-TaskLog) {
            Show-Msg -Text "已开启任务运行记录。`r`n`r`n接下来这样抓现行：`r`n1. 正常用电脑，等下次黑框弹出来`r`n2. 看到之后马上回到这一页点「刷新记录」`r`n3. 时间对得上的那一条就是元凶`r`n`r`n这个记录只占几 MB，不影响性能。" | Out-Null
            Build-RecentRuns
        } else {
            Show-Msg -Text '开启失败，详见日志页。' | Out-Null
        }
    })
# 体检页右栏在「体检结论 / 帧数诊断 / 超频陪练 / 厂商工具」之间切换 = 页面内的区块切换，卡片依次进场
$Script:UI.BtnHealthScan.Add_Click({ Build-HealthUI -Refresh -Enter })
$Script:UI.BtnFpsDiag.Add_Click({ Build-FpsDiagUI; Start-ListEnter $Script:UI.AdvicePanel })
$Script:UI.BtnOcCoach.Add_Click({ Build-OcCoachUI; Start-ListEnter $Script:UI.AdvicePanel })
$Script:UI.BtnVendor.Add_Click({ Build-VendorUI; Start-ListEnter $Script:UI.AdvicePanel })
$Script:UI.BtnRefreshAppx.Add_Click({ Build-AppxUI -Refresh -Enter })
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
            Show-Msg -Text ("已添加白名单：`r`n$path`r`n`r`n作用：Windows Defender 以后不再实时扫描这个文件夹里的文件。游戏读取大量资源文件时不用每个都过一遍杀毒，加载速度和帧数稳定性都会改善。`r`n`r`n注意：白名单里的文件不再被保护，所以只加你信任的游戏目录，不要加下载文件夹。") -Title '电脑调优助手' -Kind Info | Out-Null
        } catch {
            Show-Msg -Text "添加失败：$($_.Exception.Message)`r`n`r`n如果你装了第三方杀毒软件（360/火绒/腾讯管家），Windows Defender 会被自动关闭，这个功能就用不了了 —— 请去那个杀毒软件里手动添加信任目录。" | Out-Null
        }
    })

$Script:UI.BtnSfc.Add_Click({
        $r = Show-Msg -Text ("将在新窗口里运行 sfc /scannow，它会扫描并自动修复损坏的系统文件。`r`n`r`n· 需要 5~20 分钟`r`n· 期间不要关掉那个黑窗口`r`n· 扫完如果提示「已修复」，建议重启一次`r`n`r`n什么时候该用：系统莫名其妙报错、某些功能打不开、蓝屏频繁。`r`n`r`n现在开始吗？") -Title '检查系统文件' -Kind Ask
        if ($r -ne 'Yes') { return }
        Start-Process 'cmd.exe' -ArgumentList '/k', 'sfc /scannow' -Verb RunAs
        Write-Log '已启动 sfc /scannow 系统文件检查' '信息'
    })

$Script:UI.BtnCopyReport.Add_Click({
        if ([string]::IsNullOrWhiteSpace($Script:LastReportText)) {
            Show-Msg -Text '体检还在后台进行，等「系统体检」页出结果之后再点一次。' | Out-Null
            return
        }
        try {
            Set-Clipboard -Value $Script:LastReportText
            Show-Msg -Text '体检报告已复制到剪贴板，可以直接粘贴发给别人看。' | Out-Null
        } catch {
            Show-Msg -Text "复制失败：$($_.Exception.Message)" | Out-Null
        }
    })

$Script:UI.BtnOpenBackup.Add_Click({ Start-Process explorer.exe -ArgumentList $Script:BackupDir })
# 顶栏的换肤按钮：浅色 <-> 深色一键切换（个性化页里是同一件事的完整版）
$Script:UI.BtnThemeToggle.Add_Click({
        $st = Get-ThemeSetting
        $to = if ($Script:ThemeIsDark) { '浅色' } else { '深色' }
        Set-AppTheme -Name $to -Image $st.Image -Opacity $st.Opacity -Frost $st.Frost
        Redraw-AllPages
        Set-Status "皮肤已换成「$to」"
    })
$Script:UI.BtnExportReport.Add_Click({ Export-DiagnosticReport })

# ---- 快捷键 ----
# Ctrl+F 跳到当前页的搜索框，F5 重新检测。都是用惯了的习惯，省得去找鼠标。
$Script:Window.Add_PreviewKeyDown({
        $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
        # ★ 按页名分派，不按序号 ★ v4.1 在最前面插了「概览」之后，按序号写的快捷键全体错位了一格
        $pg = "$($Script:UI.Tabs.SelectedItem.Header)"
        if ($ctrl -and $_.Key -eq 'F') {
            switch ($pg) {
                '性能优化' { $Script:UI.TweakSearch.Focus() | Out-Null; $_.Handled = $true }
                '垃圾清理' { $Script:UI.CleanSearch.Focus() | Out-Null; $_.Handled = $true }
            }
        } elseif ($_.Key -eq 'F5') {
            switch ($pg) {
                '性能优化' { Update-TweakStates }
                '垃圾清理' { Invoke-ScanJunk }
                '弹窗排查' { Invoke-Inspect }
                '启动项管理' { Build-StartupUI -Refresh -Enter }
                '系统体检' { Build-HealthUI -Refresh -Enter }
            }
            $_.Handled = $true
        } elseif ($_.Key -eq 'Escape') {
            # Esc 清空搜索，回到完整列表
            if ($pg -eq '性能优化' -and $Script:UI.TweakSearch.Text) { $Script:UI.TweakSearch.Text = ''; $_.Handled = $true }
            if ($pg -eq '垃圾清理' -and $Script:UI.CleanSearch.Text) { $Script:UI.CleanSearch.Text = ''; $_.Handled = $true }
        }
    })

# ---------------------------------------------------------------------
#  10. 启动
# ---------------------------------------------------------------------
$osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
# 套用上次选的皮肤（读不到就是默认的浅色）
$Script:ThemeImage = ''
$Script:ThemeOpacity = 0.88
try {
    $savedTheme = Get-ThemeSetting
    # 动画开关和皮肤存在同一份配置里，启动时一起读回来
    $Script:AnimEnabled = [bool]$savedTheme.Anim
    Set-AppTheme -Name $savedTheme.Name -Image $savedTheme.Image -Opacity $savedTheme.Opacity -Frost $savedTheme.Frost
    Apply-PanelOpacity
} catch { Write-Log "套用皮肤失败，用默认配色：$($_.Exception.Message)" '警告' }
Sync-TransitionSwitch
Update-ThemeToggleIcon

$Script:Window.Title = "电脑调优助手 v$Script:AppVersion"
$Script:UI.AppVerText.Text = "v$Script:AppVersion · $Script:AppVersionDate"

# 页眉那四个事实。★ 受检机器要写真机型 ★
#   报告单的抬头写的是「谁的报告」，不是「谁出的报告」。
#   写清楚这是给这台机器出的，用户才知道下面的参考范围是按他的硬件算的。
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    # 厂商名和型号都要收拾一下：
    #   OEM 写进 BIOS 的字符串常常是「ASUSTeK COMPUTER INC.」这种带法律后缀的，
    #   型号还经常是「G533QR_G533QR」这种自我重复。
    #   报告单的抬头要的是人能认出来的那个名字。
    $mk = "$($cs.Manufacturer)" -replace '(?i)\s*(computer|technology|technologies|electronics)?\s*(inc|corp|corporation|co|ltd|limited|gmbh)\.?,?\s*$', ''
    $md = "$($cs.Model)".Trim()
    # 「ROG Strix G533QR_G533QR」这种：尾巴上那段用下划线接的东西
    # 如果前面已经出现过，就是 OEM 自我重复，砍掉。
    if ($md -match '^(.*?)_([^_\s]+)$' -and $Matches[1] -like "*$($Matches[2])*") { $md = $Matches[1] }
    $machine = if ($cs) { ("$mk $md").Trim() } else { $env:COMPUTERNAME }
} catch { $machine = $env:COMPUTERNAME }
$Script:UI.SubTitle.Text = "受检机器  $machine　·　$osCaption"
$Script:UI.RptNo.Text    = "编号  PCT-$Script:AppVersion-$((Get-Date).ToString('MMdd'))"
$Script:UI.RptDate.Text  = "报告日期  $((Get-Date).ToString('yyyy-MM-dd'))"

# ★ 写真实的权限状态 ★
#   这句话原来是写死的「管理员模式」。出图模式不提权之后，
#   日志里会出现一句假话 —— 日志写假话比没日志更坏。
$Script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log ('=== 电脑调优助手已启动（{0}）===' -f $(if ($Script:IsAdmin) { '管理员模式' } else { '普通权限 —— 传感器、SMART、系统设置读不到也改不了' })) '信息'
if ($Script:FontLoaded) {
    Write-Log "随包字体 MiSans 已加载（不装进系统）：$Script:FontStack" '信息'
} else {
    Write-Log "随包字体没加载上，退回系统字体。$Script:FontLoadError" '警告'
}

Install-PressFeedback      # 所有按钮按下缩 0.97、松手弹簧回弹（类级注册，切到哪页都有）
Install-ToggleMotion       # 勾选框画勾、开关弹簧滑动（同样类级注册）
# 刷新类按钮前加刷新图标，悬停转半圈（D7）
foreach ($rb in @($Script:UI.BtnRescan, $Script:UI.BtnRefreshStartup, $Script:UI.BtnRefreshAppx, $Script:UI.BtnHealthScan)) { Set-RefreshButton $rb }
Build-NavUI
Build-TweakUI
Build-PresetUI
$Script:PresetExpanded = $false
$Script:LastPresetName = ''
$Script:UI.PresetHeader.Add_MouseLeftButtonUp({ Set-PresetExpanded (-not $Script:PresetExpanded) })
Build-CleanUI
Update-CleanSelCount
Update-TweakStates -PreselectRecommended $true

# 启动项和体检比较慢，等窗口显示出来之后再在后台补上
$Script:Window.Add_ContentRendered({
        # 高分屏排查用：实际跑界面的这个进程是什么 DPI 感知级别、当前缩放多少。朋友发日志截图就能看出是不是被系统拉伸了
        try {
            $api = Get-NativeApi
            $aw = $api::GetAwarenessFromDpiAwarenessContext($api::GetThreadDpiAwarenessContext())
            $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($Script:Window)
            $Script:DpiInfo = @{ Awareness = $aw; Scale = [math]::Round($dpi.DpiScaleX * 100) }
            Write-Log ("显示缩放 {0}%，DPI 感知：{1}" -f $Script:DpiInfo.Scale, $(switch ($aw) { 0 { '不感知（会被系统按位图拉伸，字会糊）' } 1 { '系统级' } 2 { '按显示器' } default { "未知($aw)" } })) '信息'
        } catch { }
        Invoke-Step 'Build-StartupUI' { Build-StartupUI }
        Invoke-Step 'Build-MaintainUI' { Build-MaintainUI }
        Invoke-Step 'Build-BigFileDrives' { Build-BigFileDrives }
        Invoke-Step 'Build-RecentRuns' { Build-RecentRuns }
        Invoke-Step 'Set-InspectEmpty' { Set-InspectEmpty }        # 弹窗排查页扫描前的空状态
        Invoke-Step 'Build-LogUI' { Build-LogUI }             # 把窗口出来之前记下的那几条日志补画出来
        Invoke-Step 'Build-ThemeUI' { Build-ThemeUI }
        # 概览页：先建壳子再开硬件监控。
        # Initialize-Dash 要枚举全部硬件，实测约 3 秒，所以放在
        # 窗口已经显示出来之后做 —— 不然用户会觉得「双击了半天不出来」。
        Invoke-Step 'Build-DashUI' { Build-DashUI }
        # 硬件监控初始化（枚举全部硬件，3~7 秒）在传感器线里做，界面不等它
        Invoke-Step 'Start-DashTimer' { Start-DashTimer }
        if (Test-ProcAuditEnabled) { $Script:UI.BtnProcAudit.Content = '关闭持续记录' }
        Invoke-Step 'Build-HealthUI' { Build-HealthUI }
        Start-PageWarmup
        Set-Status '报告已出 —— 超出安全范围的项列在「检验结论」里；要动手去「性能优化」页'
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
        # 切页过场：新页面的区块依次进场（design.md 5.3）
        # ★ 用 SelectedItem.Content，不用 SelectedContent ★ 这个事件触发时 SelectedContent 还是旧页面
        $Script:LastEnterMs = Start-PageEnter $Script:UI.Tabs.SelectedItem.Content
        # 概览页：区块落位之后，健康度数字和圆环再从 0 滚上来（接力，不和进场抢）
        if ("$($Script:UI.Tabs.SelectedItem.Header)" -eq '概览') { Start-HeroScore $Script:LastEnterMs }
        Update-NavSelection
        $header = "$($Script:UI.Tabs.SelectedItem.Header)"
        # 只有停在概览页才轮询传感器，切走立刻停 ——
        # 全量刷新一次 100ms，一直跑等于工具自己变成最大的后台负担
        if ($header -eq '概览') { Start-DashTimer } else { Stop-DashTimer }
        if ($header -eq '自带软件' -and -not $Script:AppxBuilt) {
            $Script:AppxBuilt = $true
            Build-AppxUI
        }
    })

# ---------------------------------------------------------------------
#  自检：我们自己的控件样式有没有真的生效
#
#  ★ 为什么需要这一项 ★
#    页签选中那条线曾经一直是 HandyControl 的默认蓝 #326CF3，
#    完全在色板外、换皮肤也不变，而三个自检都查不出来 ——
#    对比度脚本只查我们自己写的色号，库模板里的颜色不在它视野里。
#    根因是库的样式把我们的盖了，而这种覆盖不报错。
#    所以直接查「我们的模板在不在位」。
# ---------------------------------------------------------------------
if ($SelfTest) {
    $styleBad = @()
    # ---- MDIX 真的挂上了、样式真的解得出来 ----
    #   「加载成功但样式一个不生效」是这类库最常见的死法，而且不报错 ——
    #   v4 的 HandyControl 就这么静默失效过（根因见 design.md 7）。所以直接查。
    if (-not $Script:MdLoaded) { $styleBad += "界面库 MDIX 没加载上：$Script:MdLoadError" }
    if (-not $Script:AppStyles -or $Script:AppStyles.MergedDictionaries.Count -lt 2) { $styleBad += '全局样式字典没挂上（MDIX 主题 + 默认样式应为 2 个合并字典）' }
    elseif ($Script:AppStyles.MergedDictionaries[1].MergedDictionaries.Count -eq 0) { $styleBad += 'MaterialDesign3.Defaults 是空的 —— 多半是有人把 Source 写成了 $rd.Source = …' }
    foreach ($k in 'ButtonPrimary', 'ButtonDanger', 'ButtonIcon', 'SearchBox', 'CardBorder', 'PageHost', 'MaterialDesignOutlinedButton') {
        try { if ($null -eq $Script:Window.FindResource($k)) { $styleBad += "样式 $k 解不出来" } } catch { $styleBad += "样式 $k 解不出来" }
    }
    try {
        $bp = $Script:Window.FindResource('ButtonPrimary')
        if ($null -eq $bp.BasedOn) { $styleBad += 'ButtonPrimary 没有基于 MDIX 的按钮样式' }
        $el = ($bp.Setters | Where-Object { "$($_.Property.Name)" -eq 'Elevation' })
        if (-not $el -or "$($el.Value)" -ne 'Dp0') { $styleBad += 'ButtonPrimary 的阴影没压成 Dp0（扁平风格要求零阴影）' }
    } catch { $styleBad += "ButtonPrimary 查不了：$($_.Exception.Message)" }
    try {
        [void]$Script:UI.Tabs.ApplyTemplate()
        if ($null -eq $Script:UI.Tabs.Template.FindName('HeaderPanel', $Script:UI.Tabs)) { $styleBad += '页面容器没用 PageHost 模板，页签条会露出来' }
    } catch { $styleBad += "页面容器检查报错：$($_.Exception.Message)" }
    # ---- 动效硬检查：弹簧和过场真的挂上了 ----
    #   这两样坏了不会报错，只会「界面突然变死」—— 必须有人盯
    try {
        $curve = Get-SpringCurve
        $peak = ($curve | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum
        if ($peak -lt 1.12 -or $peak -gt 1.20) { $styleBad += ("弹簧曲线不对：超调 {0:P1}，A3 应该在 16% 左右" -f ($peak - 1)) }
        if ([math]::Abs($curve[$curve.Count - 1][1] - 1.0) -gt 0.0001) { $styleBad += '弹簧曲线最后没落到 1' }
        $sa = New-SpringAnim -From 0 -To 10
        if ($sa.KeyFrames.Count -lt 30) { $styleBad += "弹簧关键帧太少（$($sa.KeyFrames.Count) 个）" }
    } catch { $styleBad += "弹簧检查报错：$($_.Exception.Message)" }
    if (-not $Script:PressInstalled) { $styleBad += "按钮按下的弹簧没挂上：$Script:PressError" }
    if (-not $Script:ToggleInstalled) { $styleBad += "勾选框 / 开关的动效没挂上：$Script:ToggleError" }
    try {
        $probeCb = New-Object System.Windows.Controls.CheckBox
        # 探针不在界面树上，默认样式不会自己找上门 —— 显式指一下，查的是「默认样式是不是画勾模板」
        $probeCb.Style = $Script:Window.FindResource([System.Windows.Controls.CheckBox])
        $probeCb.ApplyTemplate() | Out-Null
        if ($null -eq $probeCb.Template.FindName('Tick', $probeCb)) { $styleBad += '勾选框没用上画勾模板（Tick 不在）' }
        $probeSw = New-Object System.Windows.Controls.CheckBox
        $probeSw.Style = $Script:Window.FindResource('SwitchBox')
        $probeSw.ApplyTemplate() | Out-Null
        if ($null -eq $probeSw.Template.FindName('KnobX', $probeSw)) { $styleBad += '开关模板里没有 KnobX' }
    } catch { $styleBad += "勾选框 / 开关模板检查报错：$($_.Exception.Message)" }
    foreach ($ti in $Script:UI.Tabs.Items) {
        $nb = @(Get-PageBlocks $ti.Content).Count
        if ($nb -lt 2) { $styleBad += "「$($ti.Header)」页只找到 $nb 个区块，切页过场会退化成整页一起出现" }
    }
    # 色槽：每个槽都得在资源里，且是真正的 Brush（存成 PSObject 会在 ShowDialog 时崩）
    foreach ($k in $Script:Palettes['浅色'].Keys) {
        $v = [System.Windows.Application]::Current.Resources[$k]
        if ($v -isnot [System.Windows.Media.Brush]) { $styleBad += "色槽 $k 不是 Brush（是 $($v.GetType().Name)）" }
    }
    # 深色皮肤切一个来回：MDIX 的 BaseTheme 要真的跟着变
    try {
        $keepName = $Script:ThemeName
        Set-AppTheme -Name '深色' -NoSave
        $bgDark = "$([System.Windows.Application]::Current.Resources['MaterialDesign.Brush.Background'])"
        Set-AppTheme -Name '浅色' -NoSave
        $bgLight = "$([System.Windows.Application]::Current.Resources['MaterialDesign.Brush.Background'])"
        if ($bgDark -eq $bgLight) { $styleBad += "深浅切换没生效（两次底色都是 $bgLight）" }
        Set-AppTheme -Name $keepName -NoSave
    } catch { $styleBad += "深浅切换报错：$($_.Exception.Message)" }
    # 点「说明文字」能不能切勾。老板点名的就是这个交互 —— 转发不生效等于根本没改。
    try {
        $blk = New-SettingCheck -Title '探针' -Note '点我' -Checked $false
        $pcb = $blk.Children[0]
        $pnt = $blk.Children[1]
        $ev = New-Object System.Windows.Input.MouseButtonEventArgs (
            [System.Windows.Input.Mouse]::PrimaryDevice), 0, ([System.Windows.Input.MouseButton]::Left)
        $ev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        $pnt.RaiseEvent($ev)
        if (-not $pcb.IsChecked) { $styleBad += '点设置项的说明文字切不动那个勾' }
    } catch { $styleBad += "说明文字点击转发报错：$($_.Exception.Message)" }
    # 侧边栏：十个页面都得有入口
    if ($Script:NavItems.Count -ne $Script:UI.Tabs.Items.Count) { $styleBad += "侧边栏只有 $($Script:NavItems.Count) 项，页面有 $($Script:UI.Tabs.Items.Count) 个" }
    if ($styleBad.Count -gt 0) {
        Write-Host ('自检失败：控件样式' + [Environment]::NewLine + '  ' + ($styleBad -join ([Environment]::NewLine + '  '))) -ForegroundColor Red
        exit 5
    }

    Build-StartupUI
    Build-MaintainUI
    Build-BigFileDrives
    Build-RecentRuns
    Invoke-Inspect
    $inCards = { param($panel) $n = 0; foreach ($c in $panel.Children) { if ($c -is [System.Windows.Controls.Border] -and $c.Child -is [System.Windows.Controls.StackPanel]) { $n += $c.Child.Children.Count } else { $n++ } }; $n }
    Build-ThemeUI
    $themeCards = & $inCards $Script:UI.ThemePanel
    Build-AppxUI
    Build-FpsDiagUI
    $fpsCards = $Script:UI.AdvicePanel.Children.Count
    Build-OcCoachUI
    $ocCards = $Script:UI.AdvicePanel.Children.Count
    Build-VendorUI
    $vendorCards = $Script:UI.AdvicePanel.Children.Count
    Build-HealthUI
    Build-DashUI
    Start-SensorLoop
    Update-DashScore
    Update-DashUI
    # v6 把「维护 / 体检 / 个性化」的条目装进了卡片 —— 数卡片里面的条目，口径才和 v5.1 对得上
    $inCards = { param($panel) $n = 0; foreach ($c in $panel.Children) { if ($c -is [System.Windows.Controls.Border] -and $c.Child -is [System.Windows.Controls.StackPanel]) { $n += $c.Child.Children.Count } else { $n++ } }; $n }
    Write-Host ('自检通过：优化项 {0} / 预设 {1} / 清理项 {2} / 启动项 {3} / 维护项 {4} / 盘符 {5} / 排查结果 {6} / 运行记录 {7} / 体检卡片 {8} / 帧数诊断 {9} / 自带应用 {10} / 皮肤 {11} / 超频陪练 {12} / 厂商建议 {13} / 导航 {14} / 读数卡 {15}' -f `
            $Script:UI.TweakPanel.Children.Count, $Script:Presets.Count,
        $Script:UI.CleanPanel.Children.Count, $Script:UI.StartupPanel.Children.Count,
        (& $inCards $Script:UI.MaintainPanel), $Script:UI.BigFileDrives.Children.Count,
        $Script:UI.InspectPanel.Children.Count, $Script:UI.RecentRunPanel.Children.Count,
        (& $inCards $Script:UI.AdvicePanel), $fpsCards, $Script:UI.AppxPanel.Children.Count, $themeCards, $ocCards, $vendorCards,
        $Script:NavItems.Count, $Script:DashGauges.Count)
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

# 窗口一拉伸，整排页签就挪位置了，指示条得跟着走（不动画，跟手才对）
$Script:Window.Add_Closed({ try { if ($Script:WatchTimer) { $Script:WatchTimer.Stop() }; Stop-ProcWatch } catch { } })
$Script:Window.Add_Closed({ try { Stop-DashTimer; Stop-SensorLoop } catch { } })

# ---------------------------------------------------------------------
#  测卡顿模式（-Perf 文件路径）
#
#  ★ 量什么 ★
#    · 每一帧的间隔 —— 订阅 CompositionTarget.Rendering 之后 WPF 每帧都会回调一次，
#      两次回调的间隔就是界面线程能不能按时出帧。60Hz 下正常是 16.7ms，
#      超过 33ms 就是掉了一帧以上，人眼看得出「卡一下」。
#    · 切页首帧 —— 从设 SelectedIndex 到下一帧回调，也就是「点了之后多久看到东西」
#    · 每次定时刷新（概览页的传感器轮询等）在界面线程上占了多少毫秒
#    · 启动时窗口出来之后那一串 Build-* 各花了多久
#  ★ 不提权 ★ 和出图模式一样；传感器在非管理员下读得少，数字是下限 —— 汇报时要说明。
# ---------------------------------------------------------------------
if ($Perf) {
    $Script:Window.WindowStartupLocation = 'Manual'
    $Script:Window.Left = -4000
    $Script:Window.Top = 0
    $Script:Window.ShowInTaskbar = $false

    $Script:PerfClock = [Diagnostics.Stopwatch]::StartNew()
    $Script:PerfPhase = 'boot'
    $Script:PerfGaps = @{}                  # 阶段 -> 帧间隔列表
    $Script:PerfLastFrame = -1.0
    $Script:PerfFirstFrame = New-Object System.Collections.ArrayList   # 切页首帧
    $Script:PerfSwitchAt = $null
    $Script:PerfSwitchName = ''
    $Script:PerfCpu = [ordered]@{}
    $Script:PerfCpuAt = $null

    $Script:PerfOnFrame = [EventHandler] {
        $now = $Script:PerfClock.Elapsed.TotalMilliseconds
        if ($null -ne $Script:PerfSwitchAt) {
            [void]$Script:PerfFirstFrame.Add([pscustomobject]@{ Page = $Script:PerfSwitchName; Ms = [math]::Round($now - $Script:PerfSwitchAt, 1); SetterMs = $Script:PerfSetterMs })
            $Script:PerfSwitchAt = $null
            $Script:PerfLastFrame = $now      # 切页那一下的空档单独算在首帧里，不混进帧间隔
            return
        }
        if ($Script:PerfLastFrame -ge 0) {
            $ph = $Script:PerfPhase
            if (-not $Script:PerfGaps.ContainsKey($ph)) { $Script:PerfGaps[$ph] = New-Object System.Collections.Generic.List[double] }
            $Script:PerfGaps[$ph].Add($now - $Script:PerfLastFrame)
        }
        $Script:PerfLastFrame = $now
    }

    $Script:Window.Add_ContentRendered({
            # 排在主 ContentRendered（建页面、开传感器）之后跑
            [System.Windows.Media.CompositionTarget]::add_Rendering($Script:PerfOnFrame)
            $n = $Script:UI.Tabs.Items.Count
            $plan = New-Object System.Collections.ArrayList
            [void]$plan.Add(@{ Tab = 0; Ms = 6000; Ph = 'dash-idle' })
            foreach ($i in 1..($n - 1)) { [void]$plan.Add(@{ Tab = $i; Ms = 1500; Ph = "first-$i" }) }
            foreach ($i in 0..($n - 1)) { [void]$plan.Add(@{ Tab = $i; Ms = 1200; Ph = "again-$i" }) }
            [void]$plan.Add(@{ Tab = 0; Ms = 6000; Ph = 'dash-idle-2' })
            $Script:PerfPlan = $plan
            $Script:PerfStep = -1
            $drv = New-Object System.Windows.Threading.DispatcherTimer
            $drv.Interval = [TimeSpan]::FromMilliseconds(1500)   # 先让启动那一串动画落完
            $drv.Add_Tick({
                    $Script:PerfStep++
                    if ($Script:PerfStep -ge $Script:PerfPlan.Count) {
                        $this.Stop()
                        $Script:PerfCpu[$Script:PerfPhase] = [math]::Round(100 * ([Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalMilliseconds - $Script:PerfCpuAt) / [math]::Max(1, $Script:PerfClock.Elapsed.TotalMilliseconds - $Script:PerfWallAt), 1)
                        [System.Windows.Media.CompositionTarget]::remove_Rendering($Script:PerfOnFrame)
                        Save-PerfReport
                        $Script:Window.Close()
                        return
                    }
                    $st = $Script:PerfPlan[$Script:PerfStep]
                    # 上一阶段整个进程（含后台线）吃了多少 CPU，折算成「一个核心的百分之几」
                    $cpuNow = [Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalMilliseconds
                    $wallNow = $Script:PerfClock.Elapsed.TotalMilliseconds
                    if ($null -ne $Script:PerfCpuAt) {
                        $Script:PerfCpu[$Script:PerfPhase] = [math]::Round(100 * ($cpuNow - $Script:PerfCpuAt) / [math]::Max(1, $wallNow - $Script:PerfWallAt), 1)
                    }
                    $Script:PerfCpuAt = $cpuNow; $Script:PerfWallAt = $wallNow
                    $this.Interval = [TimeSpan]::FromMilliseconds($st.Ms)
                    $Script:PerfPhase = $st.Ph
                    $Script:PerfSwitchName = "$($st.Ph) $($Script:UI.Tabs.Items[$st.Tab].Header)"
                    if ($Script:UI.Tabs.SelectedIndex -ne $st.Tab) {
                        $Script:PerfSwitchAt = $Script:PerfClock.Elapsed.TotalMilliseconds
                        $sw = [Diagnostics.Stopwatch]::StartNew()
                        $Script:UI.Tabs.SelectedIndex = $st.Tab
                        $Script:PerfSetterMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                    }
                })
            $drv.Start()
        })
}

function Save-PerfReport {
    $stat = {
        param($list)
        $a = @($list | Sort-Object)
        if ($a.Count -eq 0) { return $null }
        [pscustomobject]@{
            N      = $a.Count
            Avg    = [math]::Round(($a | Measure-Object -Average).Average, 1)
            P95    = [math]::Round($a[[math]::Min($a.Count - 1, [int][math]::Floor($a.Count * 0.95))], 1)
            Max    = [math]::Round($a[$a.Count - 1], 1)
            Over33 = @($a | Where-Object { $_ -gt 33.4 }).Count
        }
    }
    $frames = [ordered]@{}
    foreach ($k in ($Script:PerfGaps.Keys | Sort-Object)) { $frames[$k] = & $stat $Script:PerfGaps[$k] }
    $ticks = [ordered]@{}
    foreach ($k in ($Script:PerfTicks.Keys | Sort-Object)) { $ticks[$k] = & $stat $Script:PerfTicks[$k] }
    $rep = [ordered]@{
        Version    = $Script:AppVersion
        Admin      = [bool]$Script:IsAdmin
        Dpi        = $Script:DpiInfo
        Startup    = $Script:PerfSteps
        FirstFrame = $Script:PerfFirstFrame
        FrameGaps  = $frames
        Ticks      = $ticks
        CpuPct     = $Script:PerfCpu
    }
    $rep | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Perf -Encoding UTF8
    Write-Host "测卡顿：结果写到 $Perf"
}

# ---------------------------------------------------------------------
#  出图模式
#
#  ★ 为什么不用外面的截图脚本 ★
#    程序自己提权。Windows 的 UIPI 不让低权限进程往高权限窗口发合成的
#    鼠标键盘事件，PrintWindow 拍提权窗口也只出一张白图。
#    所以想按页出图，只能让程序自己拍自己。
#
#  ★ RenderTargetBitmap 拍的是绘制结果，拍不到 RenderTransform ★
#    缩放、位移这类合成阶段的效果在图里看不见 —— 那些只能在程序内读属性验。
#    这里拍的是排版和配色，够用。
# ---------------------------------------------------------------------
if ($Shot) {
    try { if (-not (Test-Path $Shot)) { New-Item -ItemType Directory -Path $Shot -Force | Out-Null } } catch { }

    # 窗口挪到屏幕外：RenderTargetBitmap 画的是可视树，
    # 不需要窗口真的显示在屏幕上 —— 不必在人眼前一直闪。
    if (-not $ShotLive) {
        $Script:Window.WindowStartupLocation = 'Manual'
        $Script:Window.Left = -4000
        $Script:Window.Top = 0
        $Script:Window.ShowInTaskbar = $false
    }

    $Script:Window.Add_ContentRendered({
            # v6.2：体检、维护、启动项这些页的数据在后台读 —— 等它们读完、传感器出第一份读数再拍
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while ($wait.Elapsed.TotalSeconds -lt 30 -and ($Script:BgJobs.Count -gt 0 -or -not $Script:Sensor.Snap -or $null -eq $Script:DashScoreCache)) {
                Sync-UI
                Start-Sleep -Milliseconds 100
            }
            Sync-UI
            $shotScale = 1.0
            if ($ShotDpi -gt 0) {
                $shotScale = $ShotDpi / 100.0
                [System.Windows.Media.VisualTreeHelper]::SetRootDpi($Script:Window, (New-Object System.Windows.DpiScale $shotScale, $shotScale))
                Sync-UI
            }
            if ($ShotH -gt 0) {
                $Script:Window.Height = $ShotH
                Sync-UI
            }
            $tabs = $Script:UI.Tabs
            $idx = if ($ShotTab -ge 0) { @($ShotTab) } else { 0..($tabs.Items.Count - 1) }
            foreach ($i in $idx) {
                if ($i -lt 0 -or $i -ge $tabs.Items.Count) { continue }
                $tabs.SelectedIndex = $i
                # 有些页得先扫一遍才有东西可拍 —— 空着的页面当 README 截图没意义
                if ($ShotScan) {
                    $hd = "$($tabs.Items[$i].Header)"
                    if ($hd -eq '弹窗排查' -and @($Script:Findings).Count -eq 0) { Invoke-Inspect }
                }
                # 开发用：出图前在这一页上跑一段脚本（比如点某个按钮），验证交互后的样子
                if ($env:PCTUNER_SHOT_EVAL) { Sync-UI; try { Invoke-Expression $env:PCTUNER_SHOT_EVAL } catch { Write-Host "SHOT_EVAL 出错：$($_.Exception.Message)" } }
                # 让这一页把自己排完、数据填完再拍。
                # Sync-UI 把队列里排到 Background 的活全跑一遍，页面淡入也跑完。
                Sync-UI
                Start-Sleep -Milliseconds 700
                Sync-UI

                if ($ShotScroll -gt 0) {
                    # 把这一页里所有滚动区都往下滚 —— 长页面拍下半截用
                    foreach ($sv in (Find-Descendants $tabs.SelectedContent ([System.Windows.Controls.ScrollViewer]))) {
                        try { $sv.ScrollToVerticalOffset([double]$ShotScroll) } catch { }
                    }
                    Sync-UI
                    Start-Sleep -Milliseconds 400
                    Sync-UI
                }

                $name = ('{0}-{1}' -f $i, "$($tabs.Items[$i].Header)")
                if ($ShotDpi -gt 0) { $name += "-$ShotDpi" }
                $file = Join-Path $Shot ($name + '.png')
                try {
                    $w = [int][math]::Round($Script:Window.ActualWidth * $shotScale)
                    $h = [int][math]::Round($Script:Window.ActualHeight * $shotScale)
                    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap `
                        $w, $h, (96 * $shotScale), (96 * $shotScale), ([System.Windows.Media.PixelFormats]::Pbgra32)
                    $rtb.Render($Script:Window)
                    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb)) | Out-Null
                    $fs = [System.IO.File]::Create($file)
                    $enc.Save($fs)
                    $fs.Close()
                    Write-Host ("出图：{0}" -f $file)
                } catch {
                    Write-Host ("出图失败 {0} —— {1}" -f $name, $_.Exception.Message)
                }
            }
            if (-not $ShotLive) { $Script:Window.Close() }
        })
}

$Script:Window.ShowDialog() | Out-Null
