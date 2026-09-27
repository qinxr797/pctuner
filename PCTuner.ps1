<#
=====================================================================
  PCTuner.ps1  ——  电脑调优助手  主程序
---------------------------------------------------------------------
  用法：双击同目录下的「电脑调优助手.exe」即可（会自动申请管理员权限）。

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

    # 出图前先把需要扫描才有内容的页扫一遍（弹窗排查）。
    [switch]$ShotScan,

    # 出图时把窗口留在屏幕上、不自动关。
    # 悬停、按下这些状态 RenderTargetBitmap 拍不到，
    # 得真把鼠标放上去拍屏幕才算验过。
    [switch]$ShotLive
)

$ErrorActionPreference = 'Continue'

# ===== 版本号 =====
# 改版本号只改这一处，标题栏 / 副标题 / 诊断报告都从这里取。
$Script:AppVersion     = '5.1'
$Script:AppVersionDate = '2026-09-27'

# ---------------------------------------------------------------------
#  0. 加载 .NET 界面库
# ---------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------------
#  0.5 加载 HandyControl（界面控件库，MIT 协议，随包分发）
# ---------------------------------------------------------------------
#  v4.0 起界面构建在 HandyControl 上。DLL 放在 Lib\ 目录里，
#  不用安装、不进 GAC、不写注册表，就是个跟着跑的文件。
#
#  ★★ 这里有个大坑，踩过一次，务必别改回去 ★★
#    HandyControl 官方文档教你在 App.xaml 里合并这两个资源字典：
#        pack://application:,,,/HandyControl;component/Themes/SkinDefault.xaml
#        pack://application:,,,/HandyControl;component/Themes/Theme.xaml
#    在 PowerShell 里照着做，会「加载成功」但**样式一个都不生效** ——
#    按钮还是 Windows 原生样子，CircleProgressBar 直接渲染成一片空白，
#    而且不报任何错，极难排查。
#
#    正确入口是 HandyControl.Themes.Theme 这个类：它是 ResourceDictionary
#    的子类，会自己把该填的东西填进去。实测 5/5 具名样式可用。
#
#  另外必须先 new 一个 Application 实例 —— pack:// 这个 URI 协议
#  是 Application 初始化时注册的，没有它连 DLL 里的资源都找不到。
$Script:HcTheme = $null
try {
    $hcDll = Join-Path (Split-Path -Parent $PSCommandPath) 'Lib\HandyControl.dll'
    if (Test-Path -LiteralPath $hcDll) {
        Add-Type -Path $hcDll -ErrorAction Stop
        if (-not [System.Windows.Application]::Current) {
            $null = New-Object System.Windows.Application
        }
        $Script:HcTheme = New-Object HandyControl.Themes.Theme
        [System.Windows.Application]::Current.Resources.MergedDictionaries.Add($Script:HcTheme)
    }
} catch {
    # 加载失败不直接崩，下面的文件检查会给出人话提示
    $Script:HcLoadError = "$($_.Exception.Message)"
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
if (-not $SelfTest -and -not $AutoClean -and -not $Shot -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
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
$Script:ModuleNames = @('Engine', 'Tweaks', 'Games', 'Cleaner', 'Maintain', 'Inspect', 'SysInfo', 'Startup', 'Appx', 'Theme', 'Dash', 'Overclock', 'Motion')

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
# Lib 下的三个 DLL 也要查。
# 少了界面库，整个界面会退化成 Windows 原生控件，而且不报错，
# 只是「突然变丑」，用户根本不知道发生了什么；
# 少了硬件监控库，概览页的温度和风扇会全变成「—」。
foreach ($d in 'HandyControl.dll', 'LibreHardwareMonitorLib.dll', 'HidSharp.dll') {
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

# ---------------------------------------------------------------------
#  3. 界面小工具
# ---------------------------------------------------------------------
function Get-Brush {
    <#
      拿一支画笔。

      【换肤的关键在这里】
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

# =====================================================================
#  动画
# ---------------------------------------------------------------------
#  用 WPF 自带的 Storyboard，没有引入任何动画库。
#
#  ★ 规则来自 Emil Kowalski 的动画方法论（Sonner / Vaul 作者）★
#    以下每一条都是照着他那套硬规矩写的，改之前先想清楚：
#
#    1. **只动 Opacity 和 Transform。**
#       这两样走 GPU 合成，不触发布局和重绘。
#       动 Width/Height/Margin 会让整页反复重排，是性能杀手。
#
#    2. **绝不用 ease-in。**
#       它开头慢，而开头恰恰是用户正在盯着看的那一刻。
#       同样 200ms，ease-out 感觉比 ease-in 快。
#
#    3. **内置缓动太弱，要用精确的三次贝塞尔。**
#       WPF 的 CubicEase 大约是 cubic-bezier(0.33,1,0.68,1)，偏温吞。
#       这里用 KeySpline 实现真正的 (0.23,1,0.32,1) —— 起步快、收尾稳。
#       KeySpline 的两个控制点就是 cubic-bezier 的四个参数，一一对应。
#
#    4. **时长按元素类型分级，UI 一律 < 300ms。**
#       按钮反馈 100~160 / 小浮层 125~200 / 下拉 150~250 / 弹窗抽屉 200~500
#
#    5. **按触发频率决定要不要动。**
#       一天上百次的操作（键盘快捷键）不做动画；
#       一天几十次的（悬停）只能做到「几乎察觉不到」。
#       所以悬停用 110ms，比换页的 200ms 短得多。
#
#    6. **必须跟随系统的「减弱动效」设置。**
#       Windows 里关掉「显示动画」的用户，多半是因为晕动症或机器太慢，
#       不是让我们无视的。关掉之后不是「没有反馈」，而是「只留透明度、
#       去掉位移」—— 减少和减弱，不是归零。
#
#    7. **不许所有元素同时进场**，列表要 30~80ms 错峰。
# =====================================================================

# 精确缓动曲线（对应 CSS 的 cubic-bezier）
$Script:EaseOutPoints = @(0.23, 1.0, 0.32, 1.0)      # 进场/退场：强 ease-out
$Script:EaseInOutPoints = @(0.77, 0.0, 0.175, 1.0)   # 屏幕内移动/形变

# 时长分级（毫秒）
$Script:DurHover = 110    # 悬停：一天几十次，只能几乎察觉不到
$Script:DurPanel = 200    # 右侧详情栏换内容
$Script:DurTab = 160      # 切页签
$Script:DurStagger = 45   # 列表错峰间隔

$Script:AnimEnabled = $true          # 用户在「个性化」页的开关
$Script:SystemAnimOff = $false       # 系统级「减弱动效」

function Test-SystemReducedMotion {
    <#
      Windows 的「减弱动效」等价物。

      控制面板 → 轻松使用 → 显示 → 「在 Windows 中显示动画」，
      关掉之后 SystemParameters.ClientAreaAnimation 变 False。

      会关这个的人通常有两种：晕动症，或者机器实在带不动。
      两种都不该被我们无视。
    #>
    try { return (-not [System.Windows.SystemParameters]::ClientAreaAnimation) } catch { return $false }
}

function Test-AnimOn {
    <# 动画到底开不开：用户开关 且 系统没要求减弱 #>
    return ($Script:AnimEnabled -and -not $Script:SystemAnimOff)
}

function New-SplineAnim {
    <#
      用 KeySpline 做出精确的 cubic-bezier 曲线。

      【为什么不用 CubicEase / QuarticEase 那些内置的】
        它们是固定公式，曲线偏软，动起来「温吞」。
        KeySpline 的两个控制点 = cubic-bezier 的四个参数，
        想要什么曲线就是什么曲线，不用将就。
    #>
    param([double]$From, [double]$To, [double]$Ms, [double[]]$Curve)
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))

    # 起点：0 时刻用 Discrete 钉住，避免从控件当前值开始插值
    $k0 = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame
    $k0.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)
    $k0.Value = $From
    [void]$anim.KeyFrames.Add($k0)

    $k1 = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame
    $k1.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($Ms))
    $k1.Value = $To
    $k1.KeySpline = New-Object System.Windows.Media.Animation.KeySpline (
        $Curve[0], $Curve[1], $Curve[2], $Curve[3])
    [void]$anim.KeyFrames.Add($k1)
    return $anim
}

function Start-FadeSlideIn {
    <#
      内容换新时的淡入 + 轻微上移。用在右侧详情栏这种「整块换内容」的地方。

      Delay 用来做列表错峰进场（30~80ms 一档）——
      全部同时出现是 Emil 那份 Never Ship 清单里的一条。
    #>
    param($Element, [double]$Ms = 0, [double]$SlideY = 10, [double]$Delay = 0)
    if ($null -eq $Element) { return }
    if ($Ms -le 0) { $Ms = $Script:DurPanel }

    if (-not (Test-AnimOn)) {
        $Element.Opacity = 1
        $Element.RenderTransform = $null
        return
    }

    # 系统要求减弱动效时：保留淡入（帮助理解内容换了），去掉位移
    $reduce = $Script:SystemAnimOff
    try {
        $fade = New-SplineAnim -From 0 -To 1 -Ms $Ms -Curve $Script:EaseOutPoints
        if ($Delay -gt 0) { $fade.BeginTime = [TimeSpan]::FromMilliseconds($Delay) }
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

        if (-not $reduce -and $SlideY -ne 0) {
            $tt = New-Object System.Windows.Media.TranslateTransform
            $tt.Y = $SlideY
            $Element.RenderTransform = $tt
            $slide = New-SplineAnim -From $SlideY -To 0 -Ms $Ms -Curve $Script:EaseOutPoints
            if ($Delay -gt 0) { $slide.BeginTime = [TimeSpan]::FromMilliseconds($Delay) }
            $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
        }
    } catch {
        # 动画失败绝不能拖垮功能：直接显示出来
        $Element.Opacity = 1
    }
}

function Start-StaggerIn {
    <#
      一批元素错峰进场，每个比前一个晚 45ms。

      【为什么要错峰】
        全部同时淡入，眼睛会把它们当成一整块，感觉不到「逐个出现」，
        反而显得生硬。差几十毫秒，大脑就读成有节奏的序列。
        超过 6 个就不再往后加延迟 —— 再排下去最后一个要等半秒，
        那就从「有节奏」变成「怎么还没出来」。
    #>
    param($Elements, [double]$Ms = 0, [double]$SlideY = 8)
    if ($Ms -le 0) { $Ms = $Script:DurPanel }
    $i = 0
    foreach ($e in $Elements) {
        if ($null -eq $e) { continue }
        $delay = [math]::Min($i, 6) * $Script:DurStagger
        Start-FadeSlideIn -Element $e -Ms $Ms -SlideY $SlideY -Delay $delay
        $i++
    }
}

function Get-ThemedHex {
    <# 拿到某个基准色号在当前皮肤下的实际色号（Get-Brush 的纯字符串版）#>
    param([string]$Hex)
    if ($Script:ColorRemap -and $Script:ColorRemap.ContainsKey($Hex.ToUpper())) {
        return $Script:ColorRemap[$Hex.ToUpper()]
    }
    return $Hex
}

function Start-ColorFade {
    <#
      背景色平滑过渡。用在卡片悬停上。

      【悬停必须极短】
        悬停是一天要发生几十上百次的动作。按 Emil 的频率分级，
        这一档「只能做到几乎察觉不到，否则就别做」。
        110ms 是能感觉到「柔和」但不会觉得「在等」的上限。

      【用 ColorAnimation 而不是关键帧】
        鼠标可以在两张卡之间快速来回扫，动画会被反复打断。
        ColorAnimation 会从「当前实际颜色」重新出发；
        关键帧则每次都从头播，来回扫的时候会闪。

      【注意冻结画笔】
        主题里那批资源画笔是 Frozen 的（渲染更快），
        直接对它做动画会抛 InvalidOperationException。
        所以这里每次都换一支独立的、可动画的画笔给这个控件用。
    #>
    param($Element, [string]$ToHex, [double]$Ms = 0)
    if ($null -eq $Element) { return }
    if ($Ms -le 0) { $Ms = $Script:DurHover }
    $to = [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemedHex $ToHex))

    if (-not (Test-AnimOn)) {
        $Element.Background = New-Object System.Windows.Media.SolidColorBrush $to
        return
    }
    try {
        $cur = $Element.Background
        if ($cur -isnot [System.Windows.Media.SolidColorBrush] -or $cur.IsFrozen) {
            $startColor = if ($cur -is [System.Windows.Media.SolidColorBrush]) { $cur.Color } else { $to }
            $cur = New-Object System.Windows.Media.SolidColorBrush $startColor
            $Element.Background = $cur
        }
        $anim = New-Object System.Windows.Media.Animation.ColorAnimation
        $anim.To = $to
        $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
        # 悬停这种「颜色变化」用标准 ease，不用强 ease-out —— 强曲线在
        # 这么短的时长里反而显得一顿
        $ez = New-Object System.Windows.Media.Animation.CubicEase
        $ez.EasingMode = 'EaseOut'
        $anim.EasingFunction = $ez
        $cur.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
    } catch {
        $Element.Background = New-Object System.Windows.Media.SolidColorBrush $to
    }
}

# =====================================================================
#  弹窗与提示
# ---------------------------------------------------------------------
#  以前直接用 [System.Windows.MessageBox]，那是 Win32 原生灰底方框 ——
#  界面做得再精致，一弹窗就露馅，是质感上最扎眼的一处。
#  换成 HandyControl 的：跟着皮肤走，深色模式下弹窗也是深色的。
#
#  ★ 保留原生作为兜底 ★
#    模块没载入、DLL 有问题的时候也得能弹窗报错 ——
#    那种时刻恰恰最需要告诉用户到底出了什么事。
# =====================================================================
function Show-Msg {
    <# Kind: Info / Success / Warning / Error / Ask。Ask 返回 'Yes'/'No'，其余返回 'OK' #>
    param([string]$Text, [string]$Title = '电脑调优助手', [string]$Kind = 'Info')
    try {
        if ($Script:HcTheme) {
            if ($Kind -eq 'Ask') {
                $r = [HandyControl.Controls.MessageBox]::Ask($Text, $Title)
                return $(if ("$r" -eq 'OK' -or "$r" -eq 'Yes') { 'Yes' } else { 'No' })
            }
            switch ($Kind) {
                'Success' { [HandyControl.Controls.MessageBox]::Success($Text, $Title) | Out-Null }
                'Warning' { [HandyControl.Controls.MessageBox]::Warning($Text, $Title) | Out-Null }
                'Error' { [HandyControl.Controls.MessageBox]::Error($Text, $Title) | Out-Null }
                default { [HandyControl.Controls.MessageBox]::Info($Text, $Title) | Out-Null }
            }
            return 'OK'
        }
    } catch { }
    if ($Kind -eq 'Ask') {
        return "$([System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Question'))"
    }
    $icon = switch ($Kind) { 'Warning' { 'Warning' } 'Error' { 'Error' } default { 'Information' } }
    [System.Windows.MessageBox]::Show($Text, $Title, 'OK', $icon) | Out-Null
    return 'OK'
}

function Show-Toast {
    <#
      右上角飘一条气泡，几秒后自己消失。
      用在「做完了」这种不需要点确定的场合 ——
      以前每做完一件事都弹个模态框逼人点一下，很烦。
    #>
    param([string]$Text, [string]$Kind = 'Success')
    try {
        if ($Script:HcTheme) {
            switch ($Kind) {
                'Info' { [HandyControl.Controls.Growl]::InfoGlobal($Text) }
                'Warning' { [HandyControl.Controls.Growl]::WarningGlobal($Text) }
                'Error' { [HandyControl.Controls.Growl]::ErrorGlobal($Text) }
                default { [HandyControl.Controls.Growl]::SuccessGlobal($Text) }
            }
            return
        }
    } catch { }
    try { Set-Status $Text } catch { }   # 兜底：至少写到状态栏
}

function Add-CardShadow {
    <#
      给卡片加一层很淡的投影，让它从背景上「浮」起来一点 ——
      质感差距最明显的一处，而且改动极小。

      【为什么挂在效果开关下面】
        投影是 GPU 每帧都要算的（DropShadowEffect 走像素着色器）。
        一页几十张卡片同时投影，在集显老机器上是实打实的负担，
        而这工具恰恰有一大票老机器用户。关掉效果时就不加。
    #>
    param($Element, [string]$Level = 'EffectShadow1')
    # ★ 深色皮肤一律不加阴影（design.md 4.2）★
    #   深色界面上的深度只有两个来源：表面阶梯（亮一级 = 近一层）和 1px 发丝线。
    #   在近黑底上打灰阴影是看不见的，只会白白烧 GPU；而「每张卡下面
    #   同一种灰阴影」恰恰是 SaaS 卡片套装最好认的特征。
    #   Linear 和 Raycast 都是全系统零阴影，深度全靠色阶。
    if ($Script:ThemeIsDark) { return }
    if (-not $Script:AnimEnabled) { return }
    try {
        $fx = $Script:Window.TryFindResource($Level)
        if ($fx) { $Element.Effect = $fx }
    } catch { }
}

function New-ListCard {
    <#
      列表里的一条。

      【这不再是「卡片」】
        报告单上的一行就是一行：上下留白 + 一条行间细线。
        没有圆角、没有边框盒子、没有阴影 ——
        craft-floor 拒绝「同尺寸卡片当页面结构」，
        而深色界面上的投影本来也看不见，只是白烧 GPU。

      悬停 / 按下 / 回弹统一走 Modules\Motion.ps1 的交互引擎，
      别在这儿各写各的。
    #>
    $c = New-Object System.Windows.Controls.Border
    $c.Background = [System.Windows.Media.Brushes]::Transparent
    $c.BorderBrush = Get-Brush $Script:CARD_BORDER
    $c.BorderThickness = New-Thick 0 0 0 1     # 只有行间线
    $c.Padding = New-Thick 4 12 4 12
    $c.Margin = New-Thick 0 0 0 0
    $c.Cursor = 'Hand'
    # 行不做上移（上移是卡片的语汇，表格行上移会让整列看起来在抖）
    Add-Interactive $c -BgNormal 'Transparent' -BgHover $Script:CARD_HOVER -NoLift
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
        '#66635B' { return '#E8E7E2' }   # 暖灰：中性（显式列出来——
                                         # 原来它是靠 default 恰好返回同一个值才对的，
                                         # 属于「碰巧能跑」，中性色一改就会悄悄失效）
        default   { return '#E8E7E2' }
    }
}

# =====================================================================
#  检验报告单的排版原语
# ---------------------------------------------------------------------
#  整个界面的母题是「你这台机器的检验报告」。见
#  .impeccable\surfaces\pctuner-ps1.md 的 Direction contract。
#
#  ★ 四栏骨架统治每一个列表 ★
#        项目 │ 结果 │ 标记 │ 参考范围 │ 单位
#    「参考范围」那一栏就是这个产品唯一无法被抄的机制：
#    同一项对不同使用场景，合格范围本来就不一样 ——
#    跟化验单上血红蛋白男女参考范围不同是同一回事。
#
#  ★ 分级靠标记，不靠颜色 ★
#        （空）  在参考范围内。不标色、不加粗，和别的行一模一样
#        *      需实测，脚注引到下方备注区
#        ↑ / ↓  超出上限 / 低于下限
#        ↑↑     显著超出（高风险）
#        —      本机不适用 / 读不到
#    这套标记来自真实化验单（H/L/HH 那一套的中文形态），
#    好处是**定性项目也能表达**：「已启用 / 建议已关闭」这种布尔项
#    在化验单上就是「阴性（参考：阴性）」，不需要数值区间。
#
#  ★ 颜色只在标记上 ★
#    法定墨只有一种，法定含义只有一个：超出参考范围。
#    正文字段永远消色 —— 不许给行加底色，不许给卡片加彩色左边条。
# =====================================================================

# 报告表的列轨。★ 这是模数，别在调用处手填宽度 ★
#   窄了缩列，不重排 —— 四栏的相对位置在任何宽度下都不变，
#   这样用户扫第二行时不用重新找「结果」在哪。
$Script:RptCol = @{ Result = 86; Mark = 30; Bar = 212; Ref = 104; Unit = 46 }

$Script:BarW = 204      # 血条总宽（含右边百分比）。★ 模数，别在调用处手填 ★

function New-RangeBar {
    <#
      血条。返回 @{ Host; Track; Fill; Line; Pct }

      画法：
          ████████████░░░░░░░│░░░   41%
          └─ 填了多少 ────┘   └ 安全线

        Track  整条量程的底槽
        Fill   当前值填掉的那一段
        Line   安全线（合格上限或下限所在的位置）
        Pct    填充比例，写在条子右边

      ★ 为什么不是化验单那张参考区间图 ★
        上一版照化验单画了「底槽 + 合格区间色块 + 一根刻记」。
        三个抽象符号叠在一条 168px 的线上，读者得先分清哪个代表自己
        才能开始读 —— 老板一句「一点都看不懂」，那就是设计错了，
        不是他没耐心。血条不用教：填得多就是占得多。

      ★ 越线时整条上法定墨，不是只红超出的那一段 ★
        血量告急是整条变红，这是所有人都见过的。
        只红一小段，反而要读者去比较两段颜色的长度。
    #>
    $g = New-Object System.Windows.Controls.Grid
    $g.Width = $Script:BarW
    $g.Height = 20
    $g.HorizontalAlignment = 'Left'
    $g.VerticalAlignment = 'Center'

    $barW = $Script:BarW - 44      # 右边留给百分比

    # 底槽
    $track = New-Object System.Windows.Shapes.Rectangle
    $track.Width = $barW
    $track.Height = 11
    $track.RadiusX = 1; $track.RadiusY = 1
    $track.Fill = Get-Brush '#D2D0C9'          # BorderMed，比 SurfaceSunken 深一档
    #   ★ 底槽必须在纸色上看得见 ★
    #     用 SurfaceSunken(#E5E3DC) 拍出来几乎隐形，0% 那一行只剩一根竖线，
    #     读者不知道满格在哪，血条就白画了。
    $track.HorizontalAlignment = 'Left'
    $track.VerticalAlignment = 'Center'
    $g.Children.Add($track) | Out-Null

    # 填充段
    $fill = New-Object System.Windows.Shapes.Rectangle
    $fill.Height = 11
    $fill.RadiusX = 1; $fill.RadiusY = 1
    $fill.Width = 0
    $fill.HorizontalAlignment = 'Left'
    $fill.VerticalAlignment = 'Center'
    $fill.Fill = Get-Brush '#565349'           # 中性深灰，正常值不上彩墨
    $g.Children.Add($fill) | Out-Null

    # 安全线。★ 必须比填充色深、比底槽重，否则被填充段吃掉看不见 ★
    $line = New-Object System.Windows.Shapes.Rectangle
    $line.Width = 2
    $line.Height = 18
    $line.HorizontalAlignment = 'Left'
    $line.VerticalAlignment = 'Center'
    $line.Fill = Get-Brush '#2B2A26'           # TextMain
    $line.Visibility = 'Collapsed'
    $g.Children.Add($line) | Out-Null

    # 百分比。★ 表格数位 ★ 每秒刷新时不加这句整列会左右抖
    $pct = New-TextBlock -Text '' -Size 13 -Color '#66635B'
    $pct.HorizontalAlignment = 'Right'
    $pct.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($pct, 'Tabular')
    $g.Children.Add($pct) | Out-Null

    return @{ Host = $g; Track = $track; Fill = $fill; Line = $line; Pct = $pct; W = $barW }
}

function Set-RangeBar {
    <#
      刷一条血条。
        Value  当前值（$null = 读不到，条子留空、百分比写「—」）
        Max    满量程
        Lo/Hi  安全线。Lo = 低于它就不合格（刷新率、剩余空间）
                        Hi = 高于它就不合格（温度、占用率）
        Abnormal 越线了 —— 整条上法定墨

      读不到就不填 —— 和「绝不编数字」一个道理，不画一个假的长度。
    #>
    param($Bar, $Value, [double]$Max = 100, $Lo = $null, $Hi = $null, [bool]$Abnormal = $false)
    if ($null -eq $Bar) { return }
    if ($Max -le 0) { $Max = 100 }
    $w = [double]$Bar.W

    # --- 安全线 ---
    #   两侧都有限值时（很少见）画上限那一侧 —— 用户更怕的是超上限。
    $mark = if ($null -ne $Hi) { [double]$Hi } elseif ($null -ne $Lo) { [double]$Lo } else { $null }
    if ($null -eq $mark) {
        # 没有阈值的项（瞬时占用率）：不画安全线。
        # 画了就等于对用户承诺了一个并不存在的标准。
        $Bar.Line.Visibility = 'Collapsed'
    } else {
        $mk = [math]::Max(0, [math]::Min($mark, $Max))
        $Bar.Line.Visibility = 'Visible'
        $Bar.Line.Margin = New-Thick ([math]::Max(0, $w * $mk / $Max - 1)) 0 0 0
    }

    # --- 填充 ---
    if ($null -eq $Value) {
        $Bar.Fill.Width = 0
        $Bar.Pct.Text = '—'
        $Bar.Pct.Foreground = Get-Brush '#66635B'
        return
    }
    $v = [math]::Max(0, [math]::Min([double]$Value, $Max))
    $Bar.Fill.Width = [math]::Max(0, $w * $v / $Max)
    $Bar.Fill.Fill = Get-Brush $(if ($Abnormal) { '#8A5750' } else { '#565349' })

    $Bar.Pct.Text = ('{0}%' -f [math]::Round(100 * $v / $Max))
    $Bar.Pct.Foreground = Get-Brush $(if ($Abnormal) { '#8A5750' } else { '#66635B' })
    $Bar.Pct.FontWeight = $(if ($Abnormal) { 'SemiBold' } else { 'Normal' })
}

# =====================================================================
#  指针仪表
# ---------------------------------------------------------------------
#  半圆弧 + 合格段 + 指针 + 大读数。照着万用表/压力表的面孔做的。
#
#  ★ 不做完整圆环 ★
#    整圆 + 亮色渐变 + 中间一个数字，是「性能工具」这个品类的默认长相，
#    套哪个产品上都一样。真实的量测仪器是半圆刻度盘配一根指针。
#
#  ★ 弧上必须分段 ★
#    一条单色弧只能表达「多少」，分了段才能表达「在不在合格范围」——
#    后者才是这个产品真正要说的事。
# =====================================================================

function New-ArcPath {
    <#
      画一段圆弧。角度用「仪表角」：180 = 最左，0 = 最右，顺时针。
      返回 Path。
    #>
    param(
        [double]$Cx, [double]$Cy, [double]$R,
        [double]$FromDeg, [double]$ToDeg,
        [string]$Color, [double]$Thickness = 9
    )
    $rad = [math]::PI / 180
    $p1 = New-Object System.Windows.Point (
        ($Cx + $R * [math]::Cos($FromDeg * $rad)),
        ($Cy - $R * [math]::Sin($FromDeg * $rad)))
    $p2 = New-Object System.Windows.Point (
        ($Cx + $R * [math]::Cos($ToDeg * $rad)),
        ($Cy - $R * [math]::Sin($ToDeg * $rad)))

    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = $p1
    $arc = New-Object System.Windows.Media.ArcSegment
    $arc.Point = $p2
    $arc.Size = New-Object System.Windows.Size $R, $R
    $arc.SweepDirection = 'Clockwise'
    $arc.IsLargeArc = ([math]::Abs($FromDeg - $ToDeg) -gt 180)
    $fig.Segments.Add($arc)

    $geo = New-Object System.Windows.Media.PathGeometry
    $geo.Figures.Add($fig)

    $path = New-Object System.Windows.Shapes.Path
    $path.Data = $geo
    $path.Stroke = Get-Brush $Color
    $path.StrokeThickness = $Thickness
    $path.StrokeStartLineCap = 'Round'
    $path.StrokeEndLineCap = 'Round'
    return $path
}

function New-Gauge {
    <#
      一个指针仪表。返回 @{ Host; Value; Unit; Label; Sub; Needle; OkArc; Canvas; Cfg }

      结构（从下往上画）：
          底弧      整个量程，暗
          合格弧    参考范围那一段，亮
          刻度      每 1/5 一根短线
          指针      从圆心指向当前值
          读数      弧中间的大数字 + 小单位
          标签      仪表下方的名字
    #>
    param([string]$Label, [double]$W = 200, [double]$H = 150)

    $host_ = New-Object System.Windows.Controls.StackPanel
    $host_.Width = $W
    $host_.HorizontalAlignment = 'Center'

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $W
    $cv.Height = 104

    $cx = $W / 2
    $cy = 92
    $r = 66

    # 底弧（整个量程）
    # 底弧压暗、合格弧提亮 —— 两者必须一眼分得出来，
    # 否则「在不在合格区间」这件事就没被表达出来，仪表也就白画了。
    $base = New-ArcPath -Cx $cx -Cy $cy -R $r -FromDeg 180 -ToDeg 0 -Color '#E5E3DC' -Thickness 7
    $cv.Children.Add($base) | Out-Null

    # 合格弧，运行时替换
    $okHolder = New-Object System.Windows.Controls.Canvas
    $cv.Children.Add($okHolder) | Out-Null

    # 刻度：每 1/5 一根
    for ($i = 0; $i -le 5; $i++) {
        $deg = 180 - 36 * $i
        $rad = [math]::PI / 180
        $r1 = $r + 11; $r2 = $r + 16
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $cx + $r1 * [math]::Cos($deg * $rad)
        $ln.Y1 = $cy - $r1 * [math]::Sin($deg * $rad)
        $ln.X2 = $cx + $r2 * [math]::Cos($deg * $rad)
        $ln.Y2 = $cy - $r2 * [math]::Sin($deg * $rad)
        $ln.Stroke = Get-Brush '#C6C4BC'
        $ln.StrokeThickness = 2
        $cv.Children.Add($ln) | Out-Null
    }

    # 游标：弧上一小段垂直于弧的粗线，标出当前值的位置。
    # 不从圆心出发 —— 长指针会横穿弧中央的读数。
    $needle = New-Object System.Windows.Shapes.Line
    $needle.X1 = $cx - $r - 9; $needle.Y1 = $cy
    $needle.X2 = $cx - $r + 9; $needle.Y2 = $cy
    $needle.Stroke = Get-Brush '#2B2A26'
    $needle.StrokeThickness = 4
    $needle.StrokeStartLineCap = 'Round'
    $needle.StrokeEndLineCap = 'Round'
    $cv.Children.Add($needle) | Out-Null

    # 读数（弧里面）
    #
    # ★ Canvas 里子元素的 HorizontalAlignment 不生效 ★
    #   Canvas 只认 Left/Top，对齐属性直接被忽略 ——
    #   上一版数字因此全跑到弧的最左边去了。
    #   解法是套一层定宽的 Grid：Grid 内部的对齐是生效的。
    $vhost = New-Object System.Windows.Controls.Grid
    $vhost.Width = $W
    $vrow = New-Object System.Windows.Controls.StackPanel
    $vrow.Orientation = 'Horizontal'
    $vrow.HorizontalAlignment = 'Center'
    $vrow.VerticalAlignment = 'Center'
    $val = New-TextBlock -Text ([string][char]0x2014) -Size 30 -Color '#2B2A26'
    $val.FontWeight = 'Normal'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($val, 'Tabular')
    $vrow.Children.Add($val) | Out-Null
    $unit = New-TextBlock -Text '' -Size 13 -Color '#66635B'
    $unit.VerticalAlignment = 'Bottom'
    $unit.Margin = New-Thick 3 0 0 5
    $vrow.Children.Add($unit) | Out-Null
    $vhost.Children.Add($vrow) | Out-Null
    [System.Windows.Controls.Canvas]::SetLeft($vhost, 0)
    [System.Windows.Controls.Canvas]::SetTop($vhost, 50)
    $cv.Children.Add($vhost) | Out-Null

    $host_.Children.Add($cv) | Out-Null

    # 名字
    $lb = New-TextBlock -Text $Label -Size 14.5 -Color '#2B2A26'
    $lb.HorizontalAlignment = 'Center'
    $lb.Margin = New-Thick 0 2 0 0
    $host_.Children.Add($lb) | Out-Null

    # 副注（参考范围 / 型号 / 容量）
    $sub = New-TextBlock -Text '' -Size 12.5 -Color '#66635B' -Wrap $true
    $sub.HorizontalAlignment = 'Center'
    $sub.TextAlignment = 'Center'
    $sub.Margin = New-Thick 0 3 0 0
    $sub.MaxHeight = 40
    $sub.LineHeight = 18
    $host_.Children.Add($sub) | Out-Null

    return @{
        Host = $host_; Value = $val; Unit = $unit; Label = $lb; Sub = $sub
        Needle = $needle; OkHolder = $okHolder; Canvas = $cv
        Cx = $cx; Cy = $cy; R = $r
    }
}

function Set-Gauge {
    <#
      刷一个仪表。
        Value  当前值（$null = 读不到，指针归零位并变虚）
        Max    满量程
        Lo/Hi  合格区间
      读不到就不指 —— 和「绝不编数字」一个道理，不指一个假位置。
    #>
    param($G, $Value, [double]$Max = 100, $Lo = $null, $Hi = $null,
        [int]$Decimals = 0, [string]$Unit = '', [string]$Sub = '')
    if ($null -eq $G) { return }
    if ($Max -le 0) { $Max = 100 }
    $rad = [math]::PI / 180

    # 合格弧（只画一次；量程变了要重画，比如系统盘容量）
    $G.OkHolder.Children.Clear()
    if ($null -ne $Lo -or $null -ne $Hi) {
        $lo = if ($null -ne $Lo) { [double]$Lo } else { 0 }
        $hi = if ($null -ne $Hi) { [double]$Hi } else { $Max }
        $lo = [math]::Max(0, [math]::Min($lo, $Max))
        $hi = [math]::Max(0, [math]::Min($hi, $Max))
        if ($hi -gt $lo) {
            $d1 = 180 - 180 * $lo / $Max
            $d2 = 180 - 180 * $hi / $Max
            $ok = New-ArcPath -Cx $G.Cx -Cy $G.Cy -R $G.R -FromDeg $d1 -ToDeg $d2 -Color '#4A4842' -Thickness 11
            $G.OkHolder.Children.Add($ok) | Out-Null
        }
    }

    $G.Unit.Text = $Unit
    $G.Sub.Text = $Sub

    if ($null -eq $Value) {
        $G.Value.Text = [string][char]0x2014
        $G.Value.Foreground = Get-Brush '#66635B'
        $G.Value.FontWeight = 'Normal'
        $G.Needle.Visibility = 'Collapsed'
        return
    }
    $G.Needle.Visibility = 'Visible'

    $v = [math]::Max(0, [math]::Min([double]$Value, $Max))
    $deg = 180 - 180 * $v / $Max

    # 超不超标
    $bad = $false
    if ($null -ne $Hi -and [double]$Value -gt [double]$Hi) { $bad = $true }
    if ($null -ne $Lo -and [double]$Value -lt [double]$Lo) { $bad = $true }

    $ink = if ($bad) { '#8A5750' } else { '#2B2A26' }
    $G.Value.Foreground = Get-Brush $ink
    $G.Value.FontWeight = if ($bad) { 'SemiBold' } else { 'Normal' }
    $G.Needle.Stroke = Get-Brush $ink

    # 游标滑过去（不是瞬间跳）—— 这是仪表最像仪表的地方。
    # 两端分别在 r-9 和 r+9，连线正好垂直于弧。
    $cos = [math]::Cos($deg * $rad); $sin = [math]::Sin($deg * $rad)
    $x1 = $G.Cx + ($G.R - 9) * $cos;  $y1 = $G.Cy - ($G.R - 9) * $sin
    $x2 = $G.Cx + ($G.R + 9) * $cos;  $y2 = $G.Cy - ($G.R + 9) * $sin
    if (Test-MotionOn) {
        Start-Prop $G.Needle ([System.Windows.Shapes.Line]::X1Property) $G.Needle.X1 $x1 280 $Script:Ease.Out
        Start-Prop $G.Needle ([System.Windows.Shapes.Line]::Y1Property) $G.Needle.Y1 $y1 280 $Script:Ease.Out
        Start-Prop $G.Needle ([System.Windows.Shapes.Line]::X2Property) $G.Needle.X2 $x2 280 $Script:Ease.Out
        Start-Prop $G.Needle ([System.Windows.Shapes.Line]::Y2Property) $G.Needle.Y2 $y2 280 $Script:Ease.Out
    } else {
        $G.Needle.X1 = $x1; $G.Needle.Y1 = $y1
        $G.Needle.X2 = $x2; $G.Needle.Y2 = $y2
    }

    $fmt = if ($Decimals -gt 0) { "F$Decimals" } else { 'F0' }
    $old = "$($G.Value.Text)" -replace '[^\d.\-]', ''
    $changed = $true
    if ($old -and [double]::TryParse($old, [ref]$null)) {
        $changed = ([math]::Round([double]$old, $Decimals) -ne [math]::Round([double]$Value, $Decimals))
    }
    # 位数多的读数（比如系统盘 198.7）会把仪表撑宽，按长度降一档字号
    $txt = ([double]$Value).ToString($fmt)
    $G.Value.FontSize = if ($txt.Length -ge 5) { 24 } elseif ($txt.Length -ge 4) { 27 } else { 30 }

    Start-CountUp -Target $G.Value -To ([double]$Value) -Decimals $Decimals -Ms 260
    if ($changed) { Start-ValueFlash $G.Value }
}

function New-RptGrid {
    <# 造一个符合列轨的 Grid：项目(*) 结果 标记 参考范围 单位 #>
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
    if ($Control -is [System.Windows.Controls.Control]) { $Control.Margin = New-Thick 0 0 8 6 }
    $Row.Act.Children.Add($Control) | Out-Null
    $Row.Act.Visibility = 'Visible'
}

function New-ActRow {
    <#
      一行处置项：左边项目名 + 一行小字说明，右边动作。
      返回 @{ Row; Slot; Note }

      ★ 别再用圆角卡片装这些 ★
        上一版这一页是四张带底色的圆角卡叠下来。卡片本身不携带任何信息，
        只是把页面切成四块 —— 四块一样大，读者反而分不出哪件事更重要。
        一条细线做同样的分隔，而且不抢墨。
    #>
    param([string]$Name, [string]$Note = '')
    $wrap = New-Object System.Windows.Controls.Border
    $wrap.Padding = New-Thick 0 11 0 11
    $wrap.BorderBrush = Get-Brush $Script:CARD_BORDER
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
    $nm = New-TextBlock -Text $Name -Size 15 -Color '#2B2A26' -Wrap $true
    $left.Children.Add($nm) | Out-Null
    $nt = New-TextBlock -Text $Note -Size 13 -Color '#66635B' -Wrap $true
    $nt.Margin = New-Thick 0 3 0 0
    if (-not $Note) { $nt.Visibility = 'Collapsed' }
    $left.Children.Add($nt) | Out-Null
    $g.Children.Add($left) | Out-Null

    $slot = New-Object System.Windows.Controls.StackPanel
    $slot.Orientation = 'Horizontal'
    $slot.VerticalAlignment = 'Center'
    $slot.Margin = New-Thick 18 0 0 0
    [System.Windows.Controls.Grid]::SetColumn($slot, 1)
    $g.Children.Add($slot) | Out-Null

    $wrap.Child = $g
    return @{ Row = $wrap; Slot = $slot; Note = $nt; Name = $nm }
}

function New-RptHeader {
    <# 表头行：项目 / 结果 / 参考范围 / 单位，下面一条粗线 #>
    param([string]$First = '项目')
    $sp = New-Object System.Windows.Controls.StackPanel

    $g = New-RptGrid
    $g.Margin = New-Thick 0 0 0 6
    $cells = @(
        @{ T = $First; Col = 0; Align = 'Left' },
        @{ T = '结果'; Col = 1; Align = 'Right' },
        @{ T = ''; Col = 2; Align = 'Center' },
        @{ T = '占了多少'; Col = 3; Align = 'Left' },
        @{ T = '安全范围'; Col = 4; Align = 'Right' },
        @{ T = '单位'; Col = 5; Align = 'Right' })
    foreach ($c in $cells) {
        if (-not $c.T) { continue }
        $t = New-TextBlock -Text $c.T -Size 13 -Color '#66635B'
        $t.FontWeight = 'SemiBold'
        $t.HorizontalAlignment = $c.Align
        [System.Windows.Controls.Grid]::SetColumn($t, $c.Col)
        $g.Children.Add($t) | Out-Null
    }
    $sp.Children.Add($g) | Out-Null

    # 表头下那条粗线。报告单上这条线是分隔「栏目名」和「数据」的，必须比行间线重
    $rule = New-Object System.Windows.Shapes.Rectangle
    $rule.Height = 1.5
    $rule.Fill = Get-Brush '#D2D0C9'     # BorderMed
    $sp.Children.Add($rule) | Out-Null
    return $sp
}

function New-RptRow {
    <#
      一行检验项目。返回 @{ Row; Name; Result; Mark; Ref; Unit; Note }

      Mark 取值：'' / '*' / '↑' / '↓' / '↑↑' / '—'
      只有 ↑ ↓ ↑↑ 会上法定墨并加粗；其余一律消色普通字重。
    #>
    param(
        [string]$Name = '',
        [string]$Result = '',
        [string]$Mark = '',
        [string]$Ref = '',
        [string]$Unit = '',
        [string]$Note = '',
        [bool]$Zebra = $false,
        [bool]$NoBar = $false
    )
    $wrap = New-Object System.Windows.Controls.Border
    $wrap.Padding = New-Thick 0 9 0 9
    $wrap.BorderBrush = Get-Brush $Script:CARD_BORDER
    $wrap.BorderThickness = New-Thick 0 0 0 1     # 行间细线
    if ($Zebra) { $wrap.Background = Get-Brush '#EAE9E3' }   # SurfaceAlt

    $outer = New-Object System.Windows.Controls.StackPanel
    $g = New-RptGrid

    # --- 项目名 ---
    $nm = New-TextBlock -Text $Name -Size 15 -Color '#2B2A26' -Wrap $true
    $nm.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($nm, 0)
    $g.Children.Add($nm) | Out-Null

    # --- 结果（等宽数位，右对齐）---
    #   ★ 必须表格数位 ★ 不加的话 1 比 8 窄，每秒刷新时整列左右抖
    $rs = New-TextBlock -Text $Result -Size 22 -Color '#2B2A26'
    $rs.HorizontalAlignment = 'Right'
    $rs.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($rs, 'Tabular')
    [System.Windows.Controls.Grid]::SetColumn($rs, 1)
    $g.Children.Add($rs) | Out-Null

    # --- 标记 ---
    $mk = New-TextBlock -Text $Mark -Size 15 -Color '#4A4842'
    $mk.HorizontalAlignment = 'Center'
    $mk.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($mk, 2)
    $g.Children.Add($mk) | Out-Null

    # --- 量程与合格区间 ---
    #   化验单自带的那张图：一条量程、一段合格区间、一个刻记。
    #   它比圆环多一层信息 —— 不只是「你多少」，而是「你在合格区间的哪」。
    $bar = New-RangeBar
    # 没有量程可言的项（「一键维护」这种纯操作行）不画空槽 ——
    # 画一条永远空着的量程，等于对用户承诺了一个并不存在的测量。
    if ($NoBar) { $bar.Host.Visibility = 'Collapsed' }
    [System.Windows.Controls.Grid]::SetColumn($bar.Host, 3)
    $g.Children.Add($bar.Host) | Out-Null

    # --- 参考范围 ---
    $rf = New-TextBlock -Text $Ref -Size 14 -Color '#66635B'
    $rf.HorizontalAlignment = 'Right'
    $rf.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($rf, 'Tabular')
    [System.Windows.Controls.Grid]::SetColumn($rf, 4)
    $g.Children.Add($rf) | Out-Null

    # --- 单位 ---
    $un = New-TextBlock -Text $Unit -Size 13 -Color '#66635B'
    $un.HorizontalAlignment = 'Right'
    $un.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($un, 5)
    $g.Children.Add($un) | Out-Null

    $outer.Children.Add($g) | Out-Null

    # --- 附注（项目名下方的小字，不占表格列）---
    $nt = New-TextBlock -Text $Note -Size 13 -Color '#66635B' -Wrap $true
    $nt.Margin = New-Thick 0 3 0 0
    if (-not $Note) { $nt.Visibility = 'Collapsed' }
    $outer.Children.Add($nt) | Out-Null

    # --- 处置位 ---
    #   报告单上「处置 / 医嘱」是跟在那一行结论后面的，不另开一栏。
    #   界面上同理：能对这一项做的操作就排在它的附注下面，
    #   而不是收进页尾一排按钮里让用户自己对号。
    #   没人往里塞控件就不占高度。
    #   ★ WrapPanel，不是横排 StackPanel ★
    #     刷新率那一行有八个档位按钮，横排会顶出行宽。
    #   ★ WrapPanel 在 System.Windows.Controls，不在 .Primitives ★
    #     （UniformGrid 才在 Primitives。写错了 New-Object 返回 $null，
    #       后面每一句都在 $null 上操作，界面少一块但不报错 —— 踩过。）
    $act = New-Object System.Windows.Controls.WrapPanel
    $act.Margin = New-Thick 0 7 0 0
    $act.Visibility = 'Collapsed'
    $outer.Children.Add($act) | Out-Null

    $wrap.Child = $outer
    $r = @{ Row = $wrap; Name = $nm; Result = $rs; Mark = $mk; Ref = $rf; Unit = $un; Note = $nt; Bar = $bar; Act = $act }
    Set-RptMark $r $Mark
    return $r
}

function Set-RptMark {
    <#
      设置一行的标记，并按标记决定结果值的墨色与字重。

      【正常值不标色、不加粗】
        这是报告单可信的来源：满页平静，只有真出问题的那几行跳出来。
        如果每一行都有颜色，异常就不再显眼 —— 那正是上一版的毛病。
    #>
    param($Row, [string]$Mark)
    if ($null -eq $Row) { return }
    $Row.Mark.Text = $Mark
    $abnormal = ($Mark -eq '↑' -or $Mark -eq '↓' -or $Mark -eq '↑↑' -or $Mark -eq '↓↓')
    if ($abnormal) {
        # 法定墨：色号写的是「高危」那一个，换肤映射表会把它翻成当前皮肤的法定墨
        $Row.Result.Foreground = Get-Brush '#8A5750'
        $Row.Result.FontWeight = 'SemiBold'
        $Row.Mark.Foreground = Get-Brush '#8A5750'
        $Row.Mark.FontWeight = 'SemiBold'
    } else {
        $Row.Result.Foreground = Get-Brush '#2B2A26'
        $Row.Result.FontWeight = 'Normal'
        $Row.Mark.Foreground = Get-Brush '#66635B'
        $Row.Mark.FontWeight = 'Normal'
    }
}

function New-RptSection {
    <# 分区标题 + 下方一条细线。报告单用分区把「血常规 / 肝功能」分开 #>
    param([string]$Title, [string]$Aside = '')
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 0 0 0 8

    $row = New-Object System.Windows.Controls.Grid
    $t = New-TextBlock -Text $Title -Size 17 -Bold $true
    $row.Children.Add($t) | Out-Null
    if ($Aside) {
        $a = New-TextBlock -Text $Aside -Size 13 -Color '#66635B'
        $a.HorizontalAlignment = 'Right'
        $a.VerticalAlignment = 'Bottom'
        $a.Margin = New-Thick 0 0 0 1
        $row.Children.Add($a) | Out-Null
    }
    $sp.Children.Add($row) | Out-Null

    $rule = New-Object System.Windows.Shapes.Rectangle
    $rule.Height = 1
    $rule.Fill = Get-Brush $Script:CARD_BORDER
    $rule.Margin = New-Thick 0 6 0 0
    $sp.Children.Add($rule) | Out-Null
    return $sp
}

function Add-ColHeader {
    <#
      在列表容器顶部插一行列名 + 一条表头粗线。

      直接作为 panel 的第一个子元素插进去，不动 XAML ——
      一个函数覆盖多页，而且表头跟着列表一起重建，换肤时不会留旧配色。

      ★ 宽度必须和行里的列轨完全一致 ★ 否则列名对不上下面的数。
    #>
    param($Panel, [string]$First = '检验项目', $Cols = @(), [double]$Indent = 26)
    if ($null -eq $Panel) { return }

    $wrap = New-Object System.Windows.Controls.StackPanel

    $g = New-Object System.Windows.Controls.Grid
    $cd0 = New-Object System.Windows.Controls.ColumnDefinition
    $cd0.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions.Add($cd0)
    foreach ($c in $Cols) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength ([double]$c.W)
        $g.ColumnDefinitions.Add($cd)
    }

    $t0 = New-TextBlock -Text $First -Size 13 -Color '#66635B'
    $t0.FontWeight = 'SemiBold'
    $t0.Margin = New-Thick $Indent 0 0 0
    $g.Children.Add($t0) | Out-Null

    $i = 1
    foreach ($c in $Cols) {
        $t = New-TextBlock -Text $c.T -Size 13 -Color '#66635B'
        $t.FontWeight = 'SemiBold'
        $t.TextAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetColumn($t, $i)
        $g.Children.Add($t) | Out-Null
        $i++
    }
    $wrap.Children.Add($g) | Out-Null

    $rule = New-Object System.Windows.Shapes.Rectangle
    $rule.Height = 1.5
    $rule.Fill = Get-Brush '#D2D0C9'
    $rule.Margin = New-Thick 0 6 0 0
    $wrap.Children.Add($rule) | Out-Null

    $Panel.Children.Add($wrap) | Out-Null
}

function New-Badge {
    <#
      报告单上的「标注」，不是徽章。

      【过去这里是圆角药丸 + 底色】
        一行上挂三四个彩色药丸，是 SaaS 后台的长相；
        而且它违反了这一版的核心法则 ——
        **颜色只在标记上，阅读区永远消色**（见 .impeccable\surfaces\pctuner-ps1.md）。
        一页几十个彩色色块之后，真正超差的那一项就再也跳不出来了。

      化验单上的标注长这样：小字、消色、项与项之间用竖线分开；
      只有**超出参考范围**的那一个上法定墨。
      所以这里不给底色、不给圆角，靠字号和墨色区分。

      $Bg 参数保留是为了不用改 21 处调用点 —— 它现在只用来判断
      「这是不是一个异常标注」：底色属于语义色系的就上法定墨。
    #>
    param([string]$Text, [string]$Fg, [string]$Bg)

    $b = New-Object System.Windows.Controls.Border
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b.Padding = New-Thick 0 0 0 0
    $b.Margin = New-Thick 0 0 12 2
    $b.VerticalAlignment = 'Center'      # 不加这句，标注和旁边的文字会错开半行

    # 语义色系的前景（绿/卡其/玫瑰/陶）保留原色号，换肤映射表会把它
    # 翻成当前皮肤的墨；中性色一律降成次要墨。
    $isSemantic = $Fg -in @('#556B54', '#7A6B45', '#8A5750', '#89694F')
    $tb = New-TextBlock -Text $Text -Size 11.5 -Color $(if ($isSemantic) { $Fg } else { '#66635B' })
    if ($isSemantic) { $tb.FontWeight = 'SemiBold' }
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
        default { return @{ Fg = '#66635B'; Bg = '#E8E7E2' } }
    }
}

# ---------------------------------------------------------------------
#  4. 界面布局（XAML）
# ---------------------------------------------------------------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:hc="https://handyorg.github.io/handycontrol"
        Title="电脑调优助手" Height="800" Width="1240" MinHeight="620" MinWidth="1000"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBg}" Foreground="{DynamicResource TextMain}"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="14"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
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

    <!-- ================================================================
         你没画的那些地方，一样在承载设计

         文本选中的高亮、输入光标、键盘焦点框 —— 这三样 WPF 都给了
         **系统默认值**，不属于任何设计系统：
           · 选中高亮是系统蓝 #3399FF，压在这套完全消色的界面上
             像别人的东西掉进来了
           · 焦点框是**黑色点线**，在近黑背景上等于没有 ——
             而键盘操作的人全靠它，这是无障碍问题不是美观问题
         把它们接到调色板上，是区分「做出来的」和「拼出来的」最便宜的一步。
         ================================================================ -->

    <!-- 键盘焦点：1px 实线框，用边框强调色，不是系统的黑点线 -->
    <Style x:Key="AppFocusVisual">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="-2" StrokeThickness="1" SnapsToDevicePixels="True"
                       Stroke="{DynamicResource BorderStrong}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
    </Style>
    <Style TargetType="CheckBox" BasedOn="{StaticResource {x:Type CheckBox}}">
      <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
    </Style>

    <!-- 输入框：选中高亮和光标都走调色板 -->
    <Style TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource BorderStrong}"/>
      <Setter Property="SelectionOpacity" Value="0.45"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextMain}"/>
    </Style>

    <!-- ================================================================
         v4.0 起，控件样式全部交给 HandyControl。

         这里以前有 11 个手写样式（滚动条 / 复选框 / 输入框 / 进度条 /
         按钮 / 页签 / TabControl），共两百多行，现在一条不留。

         能这么干，是因为 HandyControl 的控件模板内部引用的是
         RegionBrush / PrimaryTextBrush / BorderBrush 这些键，
         而上面那批画笔在换肤时会把这些键一起覆盖掉
         （见 Modules\Theme.ps1 的 $Script:HcBrushMap）。
         所以「库出模板、我们出颜色」，两边都不用将就。

         要强调色按钮用 {DynamicResource ButtonPrimary}，
         危险按钮用 {DynamicResource ButtonDanger}，都是库里现成的。
         ================================================================ -->

    <!-- ================================================================
         页签样式 —— ★ 全app唯一一个手写回来的控件模板 ★

         v4.0 起样式全交给 HandyControl，这里破一次例，理由：
         库自带的页签会在选中项下面画一条自己的指示线，位置和颜色都归它管。
         而我们要的是一条**在页签之间滑过去**的指示条 —— 两条线并存必然打架，
         所以得先把库那条收掉，自己画。

         模板本身刻意做得极简：没有底色、没有圆角、没有药丸。
         一排页签在报告单上就是一排栏目名，选中的那个字重一些、墨深一些，
         剩下交给下面那条会滑动的线。
         ================================================================ -->
    <!-- ================================================================
         主按钮 —— ★ 这个键盖掉了 HandyControl 的同名键 ★

         窗口自己的资源字典优先于它合并进来的库字典，所以所有写
         {DynamicResource ButtonPrimary} 和 FindResource('ButtonPrimary')
         的地方会自动拿到这一个，一处调用点都不用改。

         两件事让它比一块平色高级：
           1. 一层几乎看不见的竖向渐变（白 7% -> 透明）。纯平色看着像贴纸，
              有一点点由上到下的光就有了厚度。
           2. 悬停时一道高光斜着扫过，520ms，一次，不循环。
              循环的光是广告牌；扫一次是回应 —— 它在说「我收到你的鼠标了」。

         禁用态不上色，只掉到下沉面 + 灰字 ——「禁用即未上墨」。
         ================================================================ -->
    <Style x:Key="ButtonPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Padding" Value="18,8,18,9"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="3" Background="{TemplateBinding Background}"
                    ClipToBounds="True" SnapsToDevicePixels="True">
              <Grid>
                <!-- 厚度：一层极淡的竖向渐变 -->
                <Rectangle x:Name="Sheen" RadiusX="3" RadiusY="3">
                  <Rectangle.Fill>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#12FFFFFF" Offset="0"/>
                      <GradientStop Color="#00FFFFFF" Offset="0.62"/>
                      <GradientStop Color="#0C000000" Offset="1"/>
                    </LinearGradientBrush>
                  </Rectangle.Fill>
                </Rectangle>

                <!-- 高光。斜着放，扫过去比横着有速度感 -->
                <Rectangle x:Name="Glare" Width="70" HorizontalAlignment="Left" Opacity="0">
                  <Rectangle.Fill>
                    <LinearGradientBrush StartPoint="0,1" EndPoint="1,0">
                      <GradientStop Color="#00FFFFFF" Offset="0"/>
                      <GradientStop Color="#3DFFFFFF" Offset="0.5"/>
                      <GradientStop Color="#00FFFFFF" Offset="1"/>
                    </LinearGradientBrush>
                  </Rectangle.Fill>
                  <Rectangle.RenderTransform>
                    <TranslateTransform x:Name="GlareT" X="-90"/>
                  </Rectangle.RenderTransform>
                </Rectangle>

                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                  Margin="{TemplateBinding Padding}"
                                  RecognizesAccessKey="True"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentLight}"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="GlareT" Storyboard.TargetProperty="X"
                                       From="-90" To="340" Duration="0:0:0.52">
                        <DoubleAnimation.EasingFunction>
                          <CubicEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <DoubleAnimation Storyboard.TargetName="Glare" Storyboard.TargetProperty="Opacity"
                                       From="0" To="1" Duration="0:0:0.10"/>
                      <DoubleAnimation Storyboard.TargetName="Glare" Storyboard.TargetProperty="Opacity"
                                       To="0" BeginTime="0:0:0.26" Duration="0:0:0.26"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentDark}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SurfaceSunken}"/>
                <Setter TargetName="Sheen" Property="Opacity" Value="0"/>
                <Setter Property="Foreground" Value="{DynamicResource TextDim}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabItem" x:Key="ReportTab">
      <Setter Property="Foreground" Value="{DynamicResource TextDim}"/>
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="Padding" Value="15,9,15,11"/>
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource AppFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter x:Name="Cp" ContentSource="Header"
                                HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource TextMid}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource TextMain}"/>
                <Setter TargetName="Cp" Property="TextElement.FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
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

    <!-- ================================================================
         报告单页眉

         【不做「品牌 banner」】
           一张检验报告的抬头不是 logo 墙，是四个事实：
           这是什么报告、给哪台机器出的、什么时候出的、编号是多少。
           陌生人下载一个会改注册表的工具，第一眼要看到的就是这四条 ——
           它们合起来说明「这东西在如实记录，不是在推销加速」。

         【下面那条粗线是报告单的表头线】
           整个界面靠线重分层，不靠卡片和阴影。
         ================================================================ -->
    <Border Grid.Row="0" Background="{DynamicResource PanelBg}" Padding="28,16,28,0"
            BorderBrush="{DynamicResource BorderMed}" BorderThickness="0,0,0,1.5">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <StackPanel>
            <TextBlock x:Name="RptTitle" Text="系统检验报告" FontSize="20" FontWeight="SemiBold"
                       Foreground="{DynamicResource TextMain}"/>
            <TextBlock x:Name="SubTitle" Text="" FontSize="12" Foreground="{DynamicResource TextDim}" Margin="0,3,0,0"/>
          </StackPanel>
          <StackPanel HorizontalAlignment="Right" VerticalAlignment="Top">
            <TextBlock x:Name="RptNo" Text="" FontSize="12" Foreground="{DynamicResource TextDim}"
                       HorizontalAlignment="Right" Typography.NumeralAlignment="Tabular"/>
            <TextBlock x:Name="RptDate" Text="" FontSize="12" Foreground="{DynamicResource TextDim}"
                       HorizontalAlignment="Right" Margin="0,3,0,0" Typography.NumeralAlignment="Tabular"/>
          </StackPanel>
        </Grid>

        <!-- 全局动作跟着页眉走，不单独做一条工具栏 -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,12">
          <CheckBox x:Name="ChkRestorePoint" Content="动手前自动创建系统还原点" IsChecked="True"
                    Foreground="{DynamicResource TextDim}" FontSize="12" Margin="0,0,16,0"/>
          <Button x:Name="BtnRestorePoint" Content="立即创建还原点"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ========== 主体 ========== -->
    <!-- ★ ItemContainerStyle 必须显式指，光写隐式 Style 没用 ★
           HandyControl 的 TabControl 样式自己 set 了 ItemContainerStyle，
           而显式设的容器样式优先级高于隐式样式 ——
           所以我们写的那个 TabItem 样式压根儿没生效，
           页签下面一直是库的默认蓝 #326CF3，换什么皮肤都不变。 -->
    <TabControl Grid.Row="1" x:Name="Tabs" Background="Transparent" BorderThickness="0" Padding="0" Margin="14,10,14,0"
                ItemContainerStyle="{StaticResource ReportTab}">
      <!-- 指示条见根 Grid 最后那层 TabInkLayer -->

      <!-- ================================================================
           概览（v4.1 新增，排第一页）

           这一页的存在理由：以前打开工具，第一眼是一堆勾选框列表，
           用户不知道自己电脑现在到底什么状态、该不该动手。
           现在先给一个「体检分 + 实时硬件读数」的整体印象。

           温度 / 风扇 / 各核心频率来自 LibreHardwareMonitorLib，
           读不到的一律显示「—」，绝不编数字（见 Modules\Dash.ps1）。
           ================================================================ -->
      <TabItem Header="概览">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <Grid Margin="28,20,28,20">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="300"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Margin="0,0,40,0">

              <!-- ============================================================
                   本次检验摘要

                   【这里过去是四张圆角卡 + 大数字 + sparkline】
                     那是 craft-floor 明令拒绝的两样东西叠在一起：
                     「hero-metric 模板」和「sparkline 当内容用」。
                     换成四栏表之后，同样的四个数字多带了一栏
                     **参考范围** —— 那一栏才是这个产品真正独有的东西：
                     同一个值对不同机器、不同用途，合格线本来就不一样。
                   ============================================================ -->
              <StackPanel x:Name="DashSummary"/>

              <!-- 检验结论：一行判定 + 超差项的备注 -->
              <StackPanel x:Name="DashVerdict" Margin="0,28,0,0"/>

            </StackPanel>

            <!-- ============================================================
                 右栏：按用途选

                 放右边而不是底部，是因为它是「选择受检类别」——
                 化验单上「按年龄/性别选参考范围」也是登记信息，
                 不是结果的一部分。选了它，左边整张表的参考范围会变。
                 ============================================================ -->
            <StackPanel Grid.Column="1">
              <StackPanel x:Name="DashPickHead"/>
              <StackPanel x:Name="DashQuickPick" Margin="0,4,0,0"/>

              <!-- 签发区：报告单右下角那一块 -->
              <StackPanel x:Name="DashSignOff" Margin="0,32,0,0"/>
            </StackPanel>
          </Grid>
        </ScrollViewer>
      </TabItem>

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
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <!-- ================================================================
                 预设区。【必须可以收起】
                   12 张卡片分三组排开有 490px 高，而整个左栏只有 610px ——
                   展开着的时候，下面那个「优化项列表」会被挤成 0 高度，
                   用户在这一页上根本看不见自己要勾的东西。
                   所以点完预设（= 已经做完选择）就自动收起，
                   抬头那一行随时能再点开。
                 ================================================================ -->
            <Border Grid.Row="0" Background="{DynamicResource CardBg}" CornerRadius="8" BorderBrush="{DynamicResource BorderMed}"
                    BorderThickness="1" Padding="14,9" Margin="0,0,0,8">
              <StackPanel>
                <!-- ★ 整个预设区并成一行 ★
                       这一页的主角是下面那 55 个优化项（老板定位：鼓励用户
                       自己手动调整）。预设区原来占 200px、内容区的三分之一，
                       把列表挤得只剩 3 行，主次完全颠倒。
                       组名、四个选项、「更多」全排进同一行，压到约 44px。 -->
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>

                  <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,14,0">
                    <Border Width="3" Height="15" CornerRadius="1" VerticalAlignment="Center"
                            Background="{DynamicResource TextMid}" Margin="0,0,8,0"/>
                    <TextBlock Text="按用途选" FontSize="14" FontWeight="SemiBold"
                               Foreground="{DynamicResource TextMain}" VerticalAlignment="Center"/>
                  </StackPanel>

                  <!-- 卡片区。★ 必须是竖向 StackPanel，不能是 WrapPanel ★
                       内层 WrapPanel 的期望宽度一变，外层就会把内容横着甩乱。 -->
                  <StackPanel x:Name="PresetPrimary" Grid.Column="1" VerticalAlignment="Center"/>

                  <!-- 其余分组默认收起：12 张卡全展开有 490px 高，
                       展开着的时候下面的列表会被挤没。 -->
                  <StackPanel x:Name="PresetHeader" Grid.Column="2" Orientation="Horizontal"
                              Cursor="Hand" Background="Transparent" VerticalAlignment="Center" Margin="14,0,0,0">
                    <TextBlock x:Name="PresetMoreHint" Text="更多"
                               Foreground="{DynamicResource TextDim}" FontSize="12.5" VerticalAlignment="Center"/>
                    <TextBlock x:Name="PresetToggle" Text="展开" FontSize="12.5"
                               Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="8,0,2,0"/>
                  </StackPanel>
                </Grid>
                <StackPanel x:Name="PresetBody" Margin="0,8,0,0" Visibility="Collapsed">
                  <StackPanel x:Name="PresetBar"/>
                </StackPanel>
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
            <!-- 四栏表头。没有它，右边那三列就是三串没名字的东西 -->
            <Grid Grid.Row="2" Margin="0,4,10,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="66"/>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="76"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="检验项目" Grid.Column="0" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource TextDim}" Margin="26,0,0,0"/>
              <TextBlock Text="结果" Grid.Column="1" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource TextDim}" TextAlignment="Right"/>
              <TextBlock Text="安全范围" Grid.Column="3" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource TextDim}" TextAlignment="Right"/>
            </Grid>
            <Rectangle Grid.Row="3" Height="1.5" Fill="{DynamicResource BorderMed}" Margin="0,6,10,0"/>
            <ScrollViewer Grid.Row="4" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="TweakPanel" Margin="0,0,10,0"/>
            </ScrollViewer>
            <Border Grid.Row="5" BorderBrush="{DynamicResource BorderMed}" BorderThickness="0,1,0,0" Padding="0,12,0,0" Margin="0,10,0,0">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnApplySelected" Content="应用选中的优化" Style="{DynamicResource ButtonPrimary}"/>
                <Button x:Name="BtnRevertSelected" Content="还原选中的优化"/>
                <Button x:Name="BtnRevertAll" Content="全部还原为系统默认" Style="{DynamicResource ButtonDanger}"/>
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
              <Button x:Name="BtnScanJunk" Content="扫描可清理的垃圾" Style="{DynamicResource ButtonPrimary}"/>
              <Button x:Name="BtnPickCleanRec" Content="勾选推荐项"/>
              <Button x:Name="BtnPickCleanNone" Content="全部不选"/>
              <TextBlock x:Name="TotalJunkText" Text="还没扫描" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="CleanPanel" Margin="0,0,10,0"/>
            </ScrollViewer>
            <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0">
              <Button x:Name="BtnClean" Content="开始清理选中项" Style="{DynamicResource ButtonPrimary}"/>
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
                <TextBlock Text="大文件查找" FontSize="17" FontWeight="SemiBold"/>
                <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextDim}" Margin="0,6,0,0"
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
              <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextMid}"
                         Text="黑框一闪而过、一次弹好几个 —— 那是有程序在后台调用命令行但没把窗口藏好。这里会把所有「会在后台执行命令」的地方扫一遍，按可疑程度排序。"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnInspect" Content="开始扫描" Style="{DynamicResource ButtonPrimary}"/>
                <Button x:Name="BtnInspectFilter" Content="只看会弹黑框的"/>
                <TextBlock x:Name="InspectSummary" Text="还没扫描" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="10,0,0,0" FontSize="13"/>
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
              <!-- ★ 这里以前是两张带底色的圆角盒，标题写「① 实时监控」「② 持续记录」 ★
                     圆圈数字和 ▶ ■ 是拿 Unicode 符号当图标系统 —— 不同字体里长相不一，
                     而且它们并没有比「第一步」三个字多说任何东西。
                     改成分区 + 细线，和全app一套语汇。 -->
              <StackPanel Grid.Row="0">
                <TextBlock Text="抓现行" FontSize="17" FontWeight="SemiBold"/>
                <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextDim}" Margin="0,6,0,0"
                           Text="左边扫的是「开机会自动跑什么」。但弹窗也可能来自某个已经在运行的程序定期开的子进程 —— 那种情况扫任何自启位置都找不到。这里直接盯「新建进程」，不管它藏在哪都跑不掉。"/>

                <TextBlock Text="实时监控" FontSize="14" FontWeight="SemiBold" Margin="0,18,0,0"/>
                <Rectangle Height="1" Fill="{DynamicResource BorderSoft}" Margin="0,6,0,0"/>
                <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextDim}" Margin="0,8,0,0"
                           Text="最快，立等可取。点「开始监控」后正常用电脑，等黑框出现 —— 出现的瞬间就会记下是谁开的、它的父进程是谁。"/>
                <WrapPanel Margin="0,9,0,0">
                  <Button x:Name="BtnWatchStart" Content="开始监控" Style="{DynamicResource ButtonPrimary}"/>
                  <Button x:Name="BtnWatchStop" Content="停止" IsEnabled="False"/>
                </WrapPanel>

                <TextBlock Text="持续记录" FontSize="14" FontWeight="SemiBold" Margin="0,18,0,0"/>
                <Rectangle Height="1" Fill="{DynamicResource BorderSoft}" Margin="0,6,0,0"/>
                <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextDim}" Margin="0,8,0,0"
                           Text="打开系统自带的进程创建审核，关掉本工具也在记，之后随时回来查，带完整命令行。适合「弹窗不定时、蹲不到」的情况。"/>
                <WrapPanel Margin="0,9,0,0">
                  <Button x:Name="BtnProcAudit" Content="开启持续记录"/>
                  <Button x:Name="BtnProcLog" Content="查看进程记录"/>
                  <Button x:Name="BtnEnableTaskLog" Content="开启任务记录"/>
                  <Button x:Name="BtnRecentRuns" Content="查看任务记录"/>
                </WrapPanel>
                <TextBlock x:Name="WatchStatus" Text="" FontSize="13" Foreground="{DynamicResource TextMid}" Margin="0,12,0,0" TextWrapping="Wrap"/>
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
            <Button x:Name="BtnUninstallAppx" Content="卸载勾选的应用" Style="{DynamicResource ButtonPrimary}"/>
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
          <!-- 这里以前是一个带底色的圆角提示条。底色条是「这句话比别的话重要」的意思，
               而它只是一句背景说明 —— 抬得比内容还高。改成普通正文。 -->
          <TextBlock Grid.Row="0" TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextMid}" Margin="0,0,10,14"
                     Text="换肤只改界面的底色、卡片和主色。表示危险程度的那一种墨色是故意不跟着变的 —— 「高危」永远是红的，不能因为换了皮肤看错。选好立刻生效，下次打开自动记住。"/>
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
          <!-- ★ 一屏只能有一个主按钮 ★
                 原来「重新体检」和「为什么我帧数没变？」都是主按钮样式，
                 两个一样重就等于都不重，用户不知道该先点哪个。
                 WrapPanel：窗口拉窄的时候按钮换行，不会被顶出可视区。 -->
          <WrapPanel Grid.Row="0" Margin="0,0,0,10">
            <Button x:Name="BtnHealthScan" Content="重新体检" Style="{DynamicResource ButtonPrimary}"/>
            <Button x:Name="BtnFpsDiag" Content="为什么我帧数没变？"/>
            <Button x:Name="BtnOcCoach" Content="我能超频吗？"/>
            <Button x:Name="BtnVendor" Content="该装哪个厂商工具"/>
            <Button x:Name="BtnAddExclusion" Content="把游戏文件夹加入杀毒白名单"/>
            <Button x:Name="BtnSfc" Content="检查系统文件完整性"/>
            <Button x:Name="BtnCopyReport" Content="复制体检报告"/>
            <Button x:Name="BtnExportReport" Content="导出诊断报告到桌面"/>
          </WrapPanel>
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
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="BtnOpenBackup" Content="打开备份 / 日志文件夹"/>
            <Button x:Name="BtnCopyLog" Content="复制全部日志"/>
            <TextBlock Text="所有修改的原始值都保存在备份文件夹里，「还原」功能依赖它，请不要删除。"
                       Foreground="{DynamicResource TextDim}" VerticalAlignment="Center" Margin="8,0,0,0" FontSize="13"/>
          </StackPanel>
          <!-- ★ 这里以前是一个只读 TextBox ★
                 HandyControl 的输入框样式把内容竖着居中了，几行日志飘在一个大空框正中间，
                 看着像出了 bug。而且时间、级别、内容挤在一行纯文本里，扫不出任何结构。
                 改成三列表：时间 | 类别 | 内容，和全app一套语汇。 -->
          <ScrollViewer Grid.Row="1" x:Name="LogScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="LogPanel" Margin="0,0,10,0"/>
          </ScrollViewer>
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
  
    <!-- ================================================================
         页签指示条

         一条会滑动的线。切页时它从上一个页签滑到下一个，220ms，缓出。
         为什么值得专门做：这排页签有十个，瞬间跳的线只告诉你「现在在哪」，
         滑过去的线还告诉你「你刚从哪儿来」—— 后者是免费的方向感。

         IsHitTestVisible="False"：它压在所有东西上面，绝不能吃掉点击。
         ================================================================ -->
    <Canvas Grid.Row="0" Grid.RowSpan="3" x:Name="TabInkLayer" IsHitTestVisible="False">
      <Rectangle x:Name="TabInk" Height="2.5" Width="0" Fill="{DynamicResource TextMain}" Visibility="Collapsed"/>
    </Canvas>
</Grid>
</Window>
'@

[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Script:Window = [Windows.Markup.XamlReader]::Load($reader)

# ★ 必须再往窗口上挂一份 HandyControl 主题 ★
#   XamlReader.Load 构建出来的树，资源查找链接不到 Application.Resources，
#   只挂在 Application 上的话窗口里的控件照样找不到样式。
#   这里 new 一个新实例而不是复用 Application 那个 ——
#   同一个 ResourceDictionary 实例挂到两个父级上会出怪问题。
if ($Script:HcTheme) {
    try { $Script:Window.Resources.MergedDictionaries.Add((New-Object HandyControl.Themes.Theme)) } catch { }
}

# 把随包字体套到整个窗口。
# 必须在这里做而不是写死在 XAML 里 —— 字体路径是运行时算出来的
# （取决于程序被解压到哪儿），XAML 里写不了。
try {
    $Script:Window.FontFamily = New-Object System.Windows.Media.FontFamily $Script:FontStack
} catch { }

# 把所有命名控件收集到 $Script:UI
$Script:UI = @{}
foreach ($n in @(
        'SubTitle', 'RptNo', 'RptDate', 'ChkRestorePoint', 'BtnRestorePoint', 'Tabs',
        'DashSummary', 'DashVerdict', 'DashPickHead', 'DashQuickPick', 'DashSignOff',
        'TweakPanel', 'TweakDetail', 'BtnPickRecommended', 'BtnPickNone', 'BtnRescan', 'PresetBar',
        'PresetHeader', 'PresetToggle', 'PresetBody', 'PresetPrimary', 'PresetMoreHint',
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
        'InfoPanel', 'AdvicePanel', 'BtnHealthScan', 'BtnFpsDiag', 'BtnOcCoach', 'BtnVendor', 'BtnAddExclusion', 'BtnSfc', 'BtnCopyReport', 'BtnExportReport',
        'LogPanel', 'LogScroll', 'BtnOpenBackup', 'BtnCopyLog', 'StatusText', 'BusyBar',
        'TabInkLayer', 'TabInk', 'RptTitle')) {
    $Script:UI[$n] = $Script:Window.FindName($n)
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
    $b.Padding = New-Thick 0 7 0 7

    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in @(28.0, 78.0, 58.0, 0.0)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq 0) {
            New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        } else {
            New-Object System.Windows.GridLength $w
        }
        $g.ColumnDefinitions.Add($cd)
    }

    $mk = New-TextBlock -Text $mark -Size 13.5 -Color $(if ($abn) { '#8A5750' } else { '#66635B' })
    if ($abn) { $mk.FontWeight = 'SemiBold' }
    $mk.VerticalAlignment = 'Top'
    $g.Children.Add($mk) | Out-Null

    # ★ 表格数位 ★ 时间列不加这句，1 比 8 窄，整列时间对不齐
    $tm = New-TextBlock -Text $Time -Size 13 -Color '#66635B'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($tm, 'Tabular')
    $tm.VerticalAlignment = 'Top'
    [System.Windows.Controls.Grid]::SetColumn($tm, 1)
    $g.Children.Add($tm) | Out-Null

    $lv = New-TextBlock -Text $Level -Size 13 -Color $(if ($abn) { '#8A5750' } else { '#66635B' })
    if ($abn) { $lv.FontWeight = 'SemiBold' }
    $lv.VerticalAlignment = 'Top'
    [System.Windows.Controls.Grid]::SetColumn($lv, 2)
    $g.Children.Add($lv) | Out-Null

    $ms = New-TextBlock -Text $Message -Size 13.5 -Color '#2B2A26' -Wrap $true
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
    # ★ 列名要和行里的列轨对齐 ★ 前三列 28+78+58 = 164
    $hdr = $p.Children[0].Children[0]
    foreach ($c in @(@{ T = '时间'; X = 28.0 }, @{ T = '类别'; X = 106.0 })) {
        $t = New-TextBlock -Text $c.T -Size 13 -Color '#66635B'
        $t.FontWeight = 'SemiBold'
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






function Start-DashTimer {
    if ($Script:DashTimer) { $Script:DashTimer.Start(); return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Add_Tick({ try { Update-DashUI } catch { } })
    $Script:DashTimer = $t
    $t.Start()
}

function Stop-DashTimer {
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

# 分组 -> 色条颜色（用语义色，跟着皮肤走）
$Script:PresetGroupColor = @{
    '按用途选'   = '#55606F'
    '竞技射击'   = '#556B54'
    '浏览器瘦身' = '#7A6B45'
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
      概览页 = 一张检验报告。

      【这里过去是四张圆角卡 + 76px 大数字 + 走纸曲线】
        craft-floor 把这三样都点名拒绝了：hero-metric 模板、
        sparkline 当内容用、同尺寸卡片当页面结构。
        换成四栏表之后信息反而更多了 —— 多出来的那一栏「参考范围」
        才是这个产品真正独有的东西。
    #>
    $Script:DashRows = @{}

    # ---------- 摘要：四个指针仪表 ----------
    #
    #  老板拍板要仪表盘（「看都看不懂，就得给我改成仪表盘」）。
    #  做成万用表那种半圆刻度 + 指针，不做霓虹圆环 ——
    #  弧上分合格段和超标段，指针一指，不用读字就知道在不在绿区。
    $sum = $Script:UI.DashSummary
    $sum.Children.Clear()
    $sum.Children.Add((New-RptSection -Title '本次检验摘要' -Aside '实时读数，每秒刷新')) | Out-Null

    $Script:DashGauges = @{}
    $defs = @(
        @{ K = 'CpuTemp'; N = '处理器温度'; U = '°C' },
        @{ K = 'GpuTemp'; N = '显卡温度'; U = '°C' },
        @{ K = 'Ram'; N = '内存占用'; U = '%' },
        @{ K = 'Disk'; N = '系统盘可用'; U = 'GB' })

    # ★ UniformGrid 在 System.Windows.Controls.Primitives，不在 Controls ★
    #   写错命名空间时 New-Object 找不到类型，而本脚本的
    #   $ErrorActionPreference = 'Continue' 会让它**静默跳过**，
    #   $wrap 变成 $null，后面所有 .Children.Add 全部落空 ——
    #   界面上就是「四个仪表一个都没出现」，还不报错。
    #   这里直接用 Grid 定义四等分列，省掉这个坑。
    $wrap = New-Object System.Windows.Controls.Grid
    $wrap.Margin = New-Thick 0 10 0 0
    for ($ci = 0; $ci -lt 4; $ci++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $wrap.ColumnDefinitions.Add($cd)
    }
    $ci = 0
    foreach ($d in $defs) {
        $g = New-Gauge -Label $d.N
        $Script:DashGauges[$d.K] = $g
        [System.Windows.Controls.Grid]::SetColumn($g.Host, $ci)
        $wrap.Children.Add($g.Host) | Out-Null
        $ci++
    }
    $sum.Children.Add($wrap) | Out-Null

    # 占用率这两项没有合格阈值，不配仪表（配了就等于编一个不存在的阈值），
    # 放在仪表下面一行当附注读数。
    $line = New-Object System.Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    $line.HorizontalAlignment = 'Center'
    $line.Margin = New-Thick 0 16 0 0
    $Script:DashPlain = @{}
    foreach ($d in @(@{ K = 'CpuLoad'; N = '处理器占用' }, @{ K = 'GpuLoad'; N = '显卡占用' })) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = New-Thick 0 0 36 0
        $l = New-TextBlock -Text $d.N -Size 13 -Color '#66635B'
        $l.VerticalAlignment = 'Bottom'
        $l.Margin = New-Thick 0 0 8 1
        $sp.Children.Add($l) | Out-Null
        $v = New-TextBlock -Text ([string][char]0x2014) -Size 18 -Color '#2B2A26'
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        $sp.Children.Add($v) | Out-Null
        $u = New-TextBlock -Text '%' -Size 12.5 -Color '#66635B'
        $u.VerticalAlignment = 'Bottom'
        $u.Margin = New-Thick 2 0 0 2
        $sp.Children.Add($u) | Out-Null
        $Script:DashPlain[$d.K] = $v
        $line.Children.Add($sp) | Out-Null
    }
    $sum.Children.Add($line) | Out-Null

    # ---------- 按用途选（右栏）----------
    $ph = $Script:UI.DashPickHead
    $ph.Children.Clear()
    $ph.Children.Add((New-RptSection -Title '受检类别')) | Out-Null
    $hint = New-TextBlock -Size 12 -Color '#66635B' -Wrap $true -Text (
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
    $rule.Margin = New-Thick 0 0 0 10
    $so.Children.Add($rule) | Out-Null
    foreach ($ln in @(
            @{ L = '检验'; V = "电脑调优助手 v$Script:AppVersion" },
            @{ L = '依据'; V = '本机原始值备份' },
            @{ L = '日期'; V = (Get-Date).ToString('yyyy-MM-dd') })) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = New-Thick 0 0 0 5
        $cd1 = New-Object System.Windows.Controls.ColumnDefinition
        $cd1.Width = New-Object System.Windows.GridLength 44
        $cd2 = New-Object System.Windows.Controls.ColumnDefinition
        $cd2.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $g.ColumnDefinitions.Add($cd1); $g.ColumnDefinitions.Add($cd2)
        $a = New-TextBlock -Text $ln.L -Size 11.5 -Color '#66635B'
        $b = New-TextBlock -Text $ln.V -Size 12 -Color '#4A4842' -Wrap $true
        [System.Windows.Controls.Grid]::SetColumn($b, 1)
        $g.Children.Add($a) | Out-Null
        $g.Children.Add($b) | Out-Null
        $so.Children.Add($g) | Out-Null
    }
}

function Update-DashScore {
    <#
      检验结论。

      【不做健康度大数字】
        「96 分」是 hero-metric 模板，而且分数本身不可行动 ——
        用户拿着 96 分不知道该干什么。
        报告单的结论是一行计数加一段备注：核对了多少项、合格多少、
        超差的是哪几项 —— 每一条都能直接点进去处理。
    #>
    $s = Get-DashScore
    $Script:DashScoreCache = $s

    $box = $Script:UI.DashVerdict
    $box.Children.Clear()
    $box.Children.Add((New-RptSection -Title '检验结论')) | Out-Null

    $total = @($Script:Tweaks).Count
    $bad = @($s.Items).Count
    $ok = [math]::Max(0, $total - $bad)

    # 判定行：四个计数横排，只有「超差」那个上法定墨
    $tally = New-Object System.Windows.Controls.StackPanel
    $tally.Orientation = 'Horizontal'
    $tally.Margin = New-Thick 0 2 0 14
    $cells = @(
        @{ L = '已核对'; V = "$total"; Bad = $false },
        @{ L = '合格'; V = "$ok"; Bad = $false },
        @{ L = '超差'; V = "$bad"; Bad = ($bad -gt 0) })
    foreach ($c in $cells) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = New-Thick 0 0 28 0
        $l = New-TextBlock -Text $c.L -Size 13 -Color '#66635B'
        $l.VerticalAlignment = 'Bottom'
        $l.Margin = New-Thick 0 0 6 1
        $sp.Children.Add($l) | Out-Null
        $v = New-TextBlock -Text $c.V -Size 22 -Color $(if ($c.Bad) { '#8A5750' } else { '#2B2A26' })
        if ($c.Bad) { $v.FontWeight = 'SemiBold' }
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        $sp.Children.Add($v) | Out-Null
        $tally.Children.Add($sp) | Out-Null
    }
    $box.Children.Add($tally) | Out-Null

    # 备注区：超差项逐条列出。★ 备注在表格下方，不塞进表格 ★
    if ($bad -gt 0) {
        $nh = New-TextBlock -Text '备注' -Size 12 -Color '#66635B'
        $nh.FontWeight = 'SemiBold'
        $nh.Margin = New-Thick 0 0 0 6
        $box.Children.Add($nh) | Out-Null
        foreach ($it in $s.Items) {
            $g = New-Object System.Windows.Controls.Grid
            $g.Margin = New-Thick 0 0 0 9
            $cd1 = New-Object System.Windows.Controls.ColumnDefinition
            $cd1.Width = New-Object System.Windows.GridLength 26
            $cd2 = New-Object System.Windows.Controls.ColumnDefinition
            $cd2.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            $g.ColumnDefinitions.Add($cd1); $g.ColumnDefinitions.Add($cd2)

            $mk = New-TextBlock -Text '↑' -Size 13 -Color '#8A5750'
            $mk.FontWeight = 'SemiBold'
            $g.Children.Add($mk) | Out-Null

            $sp = New-Object System.Windows.Controls.StackPanel
            [System.Windows.Controls.Grid]::SetColumn($sp, 1)
            $t1 = New-TextBlock -Text $it.Name -Size 14.5 -Color '#2B2A26' -Wrap $true
            $sp.Children.Add($t1) | Out-Null
            $t2 = New-TextBlock -Text $it.Why -Size 13 -Color '#66635B' -Wrap $true
            $t2.Margin = New-Thick 0 2 0 0
            $sp.Children.Add($t2) | Out-Null
            $g.Children.Add($sp) | Out-Null
            $box.Children.Add($g) | Out-Null
        }
    } else {
        $t = New-TextBlock -Size 12.5 -Color '#66635B' -Wrap $true -Text '全部项目在参考范围内，没有需要处理的。'
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
    Start-CountUp -Target $row.Result -To ([double]$Value) -Decimals $Decimals -Ms 220
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
    $Script:DashTick++
    Update-DashSensors

    $c = Get-DashCpu
    $rg = Get-RptRange 'CpuTemp'
    Set-Gauge $Script:DashGauges['CpuTemp'] $c.Temp $rg.Max $rg.Lo $rg.Hi 0 '°C' $(
        if ($null -eq $c.Temp) { '读不到（需管理员权限）' } else { '合格 ' + $rg.Text + ' °C' })

    $g = Get-DashGpu
    $rg = Get-RptRange 'GpuTemp'
    $gsub = if ($g.Name) { ($g.Name -replace 'NVIDIA GeForce |AMD |\(TM\)| Laptop GPU', '') } else { '没检测到显卡' }
    Set-Gauge $Script:DashGauges['GpuTemp'] $g.Temp $rg.Max $rg.Lo $rg.Hi 0 '°C' $gsub

    $r = Get-DashRam
    $rg = Get-RptRange 'Ram'
    if ($r) {
        Set-Gauge $Script:DashGauges['Ram'] $r.Percent $rg.Max $rg.Lo $rg.Hi 0 '%' (
            "已用 $($r.UsedGB) / 共 $($r.TotalGB) GB")
    }

    $d = Get-DashDisk
    if ($d) {
        # 系统盘的满量程就是这块盘的实际容量 —— 用 100 当量程是错的
        Set-Gauge $Script:DashGauges['Disk'] $d.FreeGB ([double]$d.TotalGB) 20 $null 1 'GB' (
            "$($d.Drive) 共 $($d.TotalGB) GB，已用 $($d.UsedPct)%")
    }

    # 占用率：没有合格阈值，只报数
    foreach ($p in @(@{ K = 'CpuLoad'; V = $c.Load }, @{ K = 'GpuLoad'; V = $g.Load })) {
        $t = $Script:DashPlain[$p.K]
        if ($null -eq $t) { continue }
        if ($null -eq $p.V) { $t.Text = [string][char]0x2014; continue }
        Start-CountUp -Target $t -To ([double]$p.V) -Decimals 0 -Ms 220
    }
}

function New-PresetCard {
    <#
      一个「受检类别」选项。返回 Border，Tag 挂着预设对象。

      【这里过去是圆角卡片 + 4px 彩色左边条 + 阴影】
        craft-floor 同时拒绝这三样：
          · 同尺寸卡片（图标+标题+说明）当页面结构 —— 卡片是偷懒的容器
          · 卡片/列表项上超过 1px 的彩色左右边条
          · 深色界面上的投影（深度只能来自表面阶梯和发丝线）

      报告单上的「参考人群」不是卡片，是一组勾选行：
        ○ 大型单机 3A      黑神话 / 艾尔登法环，要的是不卡顿
        ● 不玩游戏         办公上网刷视频，只想电脑别这么卡
      选中的那一行换实心记号，并且整行压一条粗下划线 ——
      层次靠线重和字重，一点颜色都不用。

      【记号用几何图形画，不用 Unicode 字符】
        craft-floor：「Unicode 字符或 emoji 冒充图标系统」是被禁的。
        ○ ● 这种字符在不同字体里大小位置都不一样，还会跟着字重变形。
        这里用 Ellipse 画，描边粗细和直径由模数定死。
    #>
    param($Preset, [bool]$Big = $false, [bool]$Compact = $false)

    $row = New-Object System.Windows.Controls.Border
    $row.Background = [System.Windows.Media.Brushes]::Transparent
    $row.BorderBrush = Get-Brush $Script:CARD_BORDER
    # 紧凑模式是横排一行，不画行间线（那是竖排列表的语汇）
    $row.BorderThickness = $(if ($Compact) { New-Thick 0 } else { New-Thick 0 0 0 1 })
    $row.Padding = $(if ($Compact) { New-Thick 0 5 12 5 } else { New-Thick 2 9 2 9 })
    $row.Cursor = 'Hand'
    $row.Tag = $Preset

    $g = New-Object System.Windows.Controls.Grid
    $cdA = New-Object System.Windows.Controls.ColumnDefinition
    $cdA.Width = New-Object System.Windows.GridLength 22
    $cdB = New-Object System.Windows.Controls.ColumnDefinition
    $cdB.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $g.ColumnDefinitions.Add($cdA); $g.ColumnDefinitions.Add($cdB)

    # --- 勾选记号：空心圆 / 选中时中间加实心点 ---
    $markBox = New-Object System.Windows.Controls.Grid
    $markBox.Width = 18; $markBox.Height = 18
    $markBox.VerticalAlignment = $(if ($Compact) { 'Center' } else { 'Top' })
    $markBox.Margin = $(if ($Compact) { New-Thick 0 } else { New-Thick 0 2 0 0 })

    $ring = New-Object System.Windows.Shapes.Ellipse
    $ring.Width = 11; $ring.Height = 11
    $ring.StrokeThickness = 1.2
    $ring.Stroke = Get-Brush '#66635B'
    $ring.HorizontalAlignment = 'Left'
    $ring.VerticalAlignment = 'Center'
    $markBox.Children.Add($ring) | Out-Null

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 5; $dot.Height = 5
    $dot.Fill = Get-Brush '#2B2A26'
    $dot.HorizontalAlignment = 'Left'
    $dot.VerticalAlignment = 'Center'
    $dot.Margin = New-Thick 3 0 0 0
    $dot.Visibility = 'Collapsed'
    $markBox.Children.Add($dot) | Out-Null
    $g.Children.Add($markBox) | Out-Null

    # --- 名称 + 说明 ---
    $sp = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)

    $title = New-TextBlock -Text $Preset.Name -Size 14.5 -Wrap (-not $Compact)
    $title.VerticalAlignment = 'Center'
    $title.FontWeight = 'SemiBold'
    $sp.Children.Add($title) | Out-Null

    # 紧凑模式不画副标题 —— 信息不丢，点选之后右栏会显示完整说明
    $subText = $Script:PresetSubtitle["$($Preset.Id)"]
    if ($subText -and -not $Compact) {
        $sub = New-TextBlock -Text $subText -Size 12 -Color '#66635B' -Wrap $true
        $sub.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($sub) | Out-Null
    }
    $g.Children.Add($sp) | Out-Null
    $row.Child = $g

    # 记号和标题存起来，选中时要改
    $row.Resources['__preset'] = @{ Ring = $ring; Dot = $dot; Title = $title }

    Add-Interactive $row -BgNormal 'Transparent' -BgHover $Script:CARD_HOVER -NoLift

    # ★ 按下的瞬间就把记号打上，不等松手 ★
    #   背景变深和下沉 1px 这两样加起来只有两三个灰阶的变化，太微妙 ——
    #   而「回答用户『我点上了吗』」是按下反馈唯一的职责。
    #   在报告单的语汇里，这个回答就是**勾上**：像在纸上打勾，
    #   笔还没抬起来，记号已经在那儿了。
    $row.Add_PreviewMouseLeftButtonDown({
            try {
                $m = $this.Resources['__preset']
                $m.Dot.Visibility = 'Visible'
                $m.Ring.Stroke = Get-Brush '#2B2A26'
            } catch { }
        })
    $row.Add_MouseLeftButtonUp({
            Select-PresetCard $this
            Select-Preset $this.Tag
        })
    return $row
}

function Select-PresetCard {
    <#
      切换选中的「受检类别」。
      选中的表现：记号填实 + 整行下划线加粗 —— 不换底色、不上强调色。
      报告单上「当前适用的参考人群」就是这么标的。
    #>
    param($Card)
    if ($Script:SelectedPresetCard -and $Script:SelectedPresetCard -ne $Card) {
        $old = $Script:SelectedPresetCard
        try {
            $m = $old.Resources['__preset']
            $m.Dot.Visibility = 'Collapsed'
            $m.Ring.Stroke = Get-Brush '#66635B'
            $old.BorderThickness = New-Thick 0 0 0 1
            $old.BorderBrush = Get-Brush $Script:CARD_BORDER
            $old.Background = [System.Windows.Media.Brushes]::Transparent
        } catch { }
    }
    $Script:SelectedPresetCard = $Card
    if ($null -eq $Card) { return }
    try {
        $m = $Card.Resources['__preset']
        $m.Dot.Visibility = 'Visible'
        $m.Ring.Stroke = Get-Brush '#2B2A26'
        $Card.BorderThickness = New-Thick 0 0 0 2
        $Card.BorderBrush = Get-Brush '#565349'
        $Card.Background = [System.Windows.Media.Brushes]::Transparent
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
        $head.Margin = New-Thick 2 $(if ($slot.Children.Count -eq 0) { 0 } else { 8 }) 0 7
        $accent = $Script:PresetGroupColor[$grp]
        if (-not $accent) { $accent = '#55606F' }
        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 3; $dot.Height = 14
        $dot.CornerRadius = New-Object System.Windows.CornerRadius 2
        $dot.Background = Get-Brush $accent
        $dot.VerticalAlignment = 'Center'
        $dot.Margin = New-Thick 0 0 8 0
        $head.Children.Add($dot) | Out-Null
        $ht = New-TextBlock -Text $grp -Size 13 -Bold $true
        $ht.VerticalAlignment = 'Center'
        $head.Children.Add($ht) | Out-Null
        if ($groupHint[$grp]) {
            $hh = New-TextBlock -Text $groupHint[$grp] -Size 11.5 -Color '#66635B'
            $hh.VerticalAlignment = 'Center'
            $hh.Margin = New-Thick 10 1 0 0
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
        $t = New-TextBlock -Text ("· " + $tw.Name) -Size 12 -Color '#565349' -Wrap $true
        $t.Margin = New-Thick 0 0 0 3
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
        $p.Children.Add((New-TextBlock -Text '怎么用这一页' -Size 16 -Bold $true)) | Out-Null
        $tip = New-TextBlock -Wrap $true -Size 12.5 -Color '#565349' -Text @'

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

    $p.Children.Add((New-TextBlock -Text $Tweak.Name -Size 17 -Bold $true -Wrap $true)) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = New-Thick 0 10 0 12
    $rc = Get-RiskColors $Tweak.Risk
    $wrap.Children.Add((New-Badge -Text $Tweak.Category -Fg '#66635B' -Bg '#E8E7E2')) | Out-Null
    $wrap.Children.Add((New-Badge -Text ("风险 " + $Tweak.Risk) -Fg $rc.Fg -Bg $rc.Bg)) | Out-Null
    if ($Tweak.Reboot) { $wrap.Children.Add((New-Badge -Text '需要重启生效' -Fg '#7A6B45' -Bg '#EDE7D9')) | Out-Null }
    if ($Tweak.Recommended) { $wrap.Children.Add((New-Badge -Text '推荐' -Fg '#55606F' -Bg '#E4E7EC')) | Out-Null }
    $p.Children.Add($wrap) | Out-Null

    $p.Children.Add((New-TextBlock -Text ("预期效果：" + $Tweak.Effect) -Size 12.5 -Color '#4A4842' -Wrap $true)) | Out-Null

    # ---- 对各类使用场景的影响 ----
    #
    # v3.0 之前这里只讲「对三个 FPS 游戏的影响」，不玩 FPS 的人
    # 每一项都看到一堆跟自己无关的内容。现在覆盖八种使用场景。
    #
    # 八张卡全平铺会很长，所以分两层：
    #   第一层「一眼看懂」—— 按结论等级把场景名归拢成几行，扫一眼就知道
    #   第二层  详细卡片  —— 结论和理由都相同的场景自动合并成一张
    $gt = New-TextBlock -Text '这一项对各类使用场景意味着什么' -Size 13 -Bold $true -Color '#55606F'
    $gt.Margin = New-Thick 0 16 0 8
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
    $sumBox.Background = Get-Brush '#FBFAF8'
    $sumBox.BorderBrush = Get-Brush '#E0DED8'
    $sumBox.BorderThickness = New-Thick 1
    $sumBox.CornerRadius = New-Object System.Windows.CornerRadius 6
    $sumBox.Padding = New-Thick 11 9 11 6
    $sumBox.Margin = New-Thick 0 0 0 10
    $sumSp = New-Object System.Windows.Controls.StackPanel
    foreach ($vk in ($byVerdict.Keys | Sort-Object { $order["$_"] })) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Thick 0 0 0 4
        $vcol = Get-VerdictColor $vk
        $b = New-Badge -Text $vk -Fg $vcol -Bg (Get-TintBg $vcol)
        $b.Margin = New-Thick 0 0 8 0
        $row.Children.Add($b) | Out-Null
        $names = New-TextBlock -Text (($byVerdict[$vk]) -join ' · ') -Size 12 -Color '#4A4842' -Wrap $true
        $names.VerticalAlignment = 'Center'
        $row.Children.Add($names) | Out-Null
        $sumSp.Children.Add($row) | Out-Null
    }
    $sumBox.Child = $sumSp
    $p.Children.Add($sumBox) | Out-Null

    # ---- 第二层：逐条理由 ----
    foreach ($m in $merged) {
        $col = Get-VerdictColor $m.V

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
        $gname = New-TextBlock -Text (($m.Names) -join ' / ') -Size 12.5 -Bold $true -Wrap $true
        $hdr.Children.Add($gname) | Out-Null
        $vb = New-Badge -Text $m.V -Fg $col -Bg (Get-TintBg $col)
        $vb.Margin = New-Thick 8 0 0 0
        $hdr.Children.Add($vb) | Out-Null
        $gsp.Children.Add($hdr) | Out-Null

        $gn = New-TextBlock -Text $m.N -Size 12 -Color '#565349' -Wrap $true
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
        $cnt = New-TextBlock -Text '' -Size 11.5 -Color '#66635B'
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

            # 列轨：勾选框 / 项目 / 结果 / 标记 / 参考范围
            # 后三列定宽，整列右边缘对齐，一眼能顺着扫下来 ——
            # 这是表格相对于卡片最实在的好处。
            $g = New-Object System.Windows.Controls.Grid
            foreach ($w in @(0, -1, 66, 24, 76)) {
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
            $cb.Margin = New-Thick 0 0 2 0
            $cb.Tag = $tw
            $cb.Add_Click({ Show-TweakDetail $this.Tag; Update-TweakSelCount })
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)
            $g.Children.Add($cb) | Out-Null

            $sp = New-Object System.Windows.Controls.StackPanel
            $nameTb = New-TextBlock -Text $tw.Name -Size 15
            $nameTb.TextWrapping = 'Wrap'
            $sp.Children.Add($nameTb) | Out-Null
            $meta = New-TextBlock -Text ("风险 {0}　{1}" -f $tw.Risk, $tw.Effect) -Size 12.5 -Color '#66635B'
            $meta.TextWrapping = 'Wrap'
            $meta.Margin = New-Thick 0 3 0 0
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
            $res = New-TextBlock -Text '检测中' -Size 15 -Color '#2B2A26'
            $res.TextAlignment = 'Right'
            $res.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($res, 2)
            $g.Children.Add($res) | Out-Null

            $mk = New-TextBlock -Text '' -Size 15 -Color '#66635B'
            $mk.TextAlignment = 'Center'
            $mk.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($mk, 3)
            $g.Children.Add($mk) | Out-Null

            $rf = New-TextBlock -Size 13 -Color '#66635B' -Text $(if ($tw.Recommended) { '建议 开启' } else { '可选' })
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
            $row.Badge.Foreground = Get-Brush '#66635B'
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
            $row.Badge.Foreground = Get-Brush '#2B2A26'
            $row.Badge.FontWeight = 'Normal'
            $row.Mark.Text = ''
            $row.Mark.Foreground = Get-Brush '#66635B'
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
            $row.Badge.Foreground = Get-Brush '#2B2A26'
            $row.Badge.FontWeight = 'Normal'
            $row.Mark.Text = ''
            $row.Mark.Foreground = Get-Brush '#66635B'
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
    # 需要重启这种要紧事还是弹模态框，确保看见；其余飘个气泡就够了
    if ($needReboot) { Show-Msg -Text $msg -Kind 'Success' | Out-Null } else { Show-Toast "成功应用 $ok / $($List.Count) 项优化" }
}

function Invoke-RevertTweaks {
    param($List)
    $List = @($List)
    if ($List.Count -eq 0) {
        Show-Msg -Text '还没有勾选任何项目。' | Out-Null
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
        $p.Children.Add((New-TextBlock -Text "点左边任意一项，这里会说明它清的是什么、安不安全。`r`n`r`n建议先点「扫描可清理的垃圾」看看各项能清多少，再决定。" -Color '#66635B' -Wrap $true)) | Out-Null
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
    Add-ColHeader $panel -First '清理项目' -Cols @(@{ T = '可清理'; W = 92 })

    foreach ($it in $Script:CleanItems) {
        $card = New-ListCard
        $card.Tag = $it
        $card.Add_MouseLeftButtonUp({ Show-CleanDetail $this.Tag })

        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(0, -1, 92)) {
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
        $cb.Margin = New-Thick 0 0 2 0
        $cb.IsChecked = [bool]$it.Recommended
        $cb.Tag = $it
        $cb.Add_Click({ Show-CleanDetail $this.Tag; Update-CleanSelCount })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $g.Children.Add($cb) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        $nameTb = New-TextBlock -Text $it.Name -Size 15
        $nameTb.TextWrapping = 'Wrap'
        $sp.Children.Add($nameTb) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null

        # 扫描结果：等宽数位右对齐，和别的表一个语汇。
        # 不加粗 —— 加粗是留给「超出参考范围」的。
        $size = New-TextBlock -Text ([string][char]0x2014) -Size 16 -Color '#2B2A26'
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
            $row.Size.Foreground = Get-Brush '#66635B'
        } elseif ($sz -eq 0) {
            $row.Size.Text = '无'
            $row.Size.Foreground = Get-Brush '#66635B'
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
    Show-Toast $msg
}

# ---------------------------------------------------------------------
#  7. 启动项页
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#  个性化（换肤）页
# ---------------------------------------------------------------------
function New-ThemeSwatchBar {
    <#
      一套皮肤的色带：窗口底 / 面板底 / 主色三段拼成一条，满格宽。

      ★ 必须直接 ConvertFromString，不能走 Get-Brush ★
        Get-Brush 会按当前皮肤做重映射，那样每条预览都会被改成
        当前皮肤的颜色，十二套皮肤长得一模一样。（踩过。）

      ★ 方角，不是圆角小块 ★
        圆角小色块是「标签」的样子；这里要的是一段真实的界面剖面，
        像油漆色卡那样三段贴在一起，边界清楚才好比。
    #>
    param([string[]]$Colors, [double]$H = 44)
    $g = New-Object System.Windows.Controls.Grid
    $g.Height = $H
    for ($i = 0; $i -lt $Colors.Count; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $g.ColumnDefinitions.Add($cd)
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Fill = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString($Colors[$i]))
        [System.Windows.Controls.Grid]::SetColumn($r, $i)
        $g.Children.Add($r) | Out-Null
    }
    # 浅色皮肤的色带贴在浅色纸上会糊掉边界，描一条细线圈住
    $frame = New-Object System.Windows.Shapes.Rectangle
    $frame.Stroke = Get-Brush '#D2D0C9'
    $frame.StrokeThickness = 1
    $frame.Fill = [System.Windows.Media.Brushes]::Transparent
    [System.Windows.Controls.Grid]::SetColumnSpan($frame, $Colors.Count)
    $g.Children.Add($frame) | Out-Null
    return $g
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
    $b.BorderBrush = Get-Brush '#DDDBD5'
    $b.BorderThickness = New-Thick 1 0 0 0
    $b.Padding = New-Thick 16 0 0 0
    $b.Child = $Element
    $Panel.Children.Add($b) | Out-Null
}

function New-SettingCheck {
    <#
      一个带说明的开关。返回可以直接塞进面板的那一块（勾 + 说明）。

      ★ 说明不能塞进 CheckBox.Content ★
        试过了：HandyControl 的模板里那个方框是**垂直居中**的，内容再高它也不跟，
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
    $cb.Content = $Title
    $cb.FontSize = 13.5
    $cb.IsChecked = $Checked
    $cb.IsEnabled = $Enabled
    if ($OnClick) { $cb.Add_Click($OnClick) }
    $wrap.Children.Add($cb) | Out-Null

    $noteText = if ($Enabled) { $Note } else { $WhyOff }
    if ($noteText) {
        $n = New-TextBlock -Text $noteText -Size 13 -Color '#66635B' -Wrap $true
        # 左边缩到和标题文字对齐（方框 16 + 间距 8），说明才像是这个勾的
        $n.Margin = New-Thick 24 5 0 0
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
    $panel = $Script:UI.ThemePanel
    $panel.Children.Clear()
    $cur = Get-ThemeSetting

    # ==================== 纯色皮肤 ====================
    #   ★ 三列网格，不是十二张竖排的卡 ★
    #     选皮肤要做的是「一眼比完」。上一版一行一张卡、一屏只看得见五张，
    #     等于逼用户滚着比色差 —— 比色最忌讳的就是不能并排看。
    $panel.Children.Add((New-RptSection -Title '皮肤' -Aside '点一下立刻生效，下次打开自动记住')) | Out-Null

    $themes = Get-BuiltinThemes
    $names = @($themes.Keys)
    $cols = 3
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Thick 0 4 0 0
    for ($c = 0; $c -lt $cols; $c++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $grid.ColumnDefinitions.Add($cd)
    }
    $rows = [math]::Ceiling($names.Count / [double]$cols)
    for ($r = 0; $r -lt $rows; $r++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = New-Object System.Windows.GridLength -1, ([System.Windows.GridUnitType]::Auto)
        $grid.RowDefinitions.Add($rd)
    }

    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = $names[$i]
        $th = $themes[$name]
        $on = ($name -eq $cur.Name)

        $cell = New-Object System.Windows.Controls.Border
        $cell.Background = [System.Windows.Media.Brushes]::Transparent
        $cell.Padding = New-Thick 0 0 0 16
        $cell.Margin = New-Thick $(if ($i % $cols -eq 0) { 0 } else { 14 }) 0 0 0
        $cell.Cursor = 'Hand'
        $cell.Tag = $name
        $cell.Add_MouseLeftButtonUp({
                Set-AppTheme -Name $this.Tag -Image $Script:ThemeImage -Opacity $Script:ThemeOpacity -Frost $Script:ThemeFrost
                Redraw-AllPages
                Set-Status "皮肤已换成「$($this.Tag)」"
            })
        # 色样格值得端详一下，给它光斑跟随
        Add-Interactive -Border $cell -BgNormal '#E4E3DE' -BgHover '#EDECE8' -NoLift -Spotlight

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-ThemeSwatchBar -Colors $th.Swatch)) | Out-Null

        # 选中就在色带底下压一条实线 —— 不用彩色描边，
        # 那会和「法定墨只有一种含义」打架。
        $ul = New-Object System.Windows.Shapes.Rectangle
        $ul.Height = 3
        $ul.Fill = Get-Brush $(if ($on) { '#2B2A26' } else { '#00000000' })
        if (-not $on) { $ul.Visibility = 'Hidden' }
        $sp.Children.Add($ul) | Out-Null

        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $head.Margin = New-Thick 0 8 0 0
        $nm = New-TextBlock -Text $name -Size 15 -Color '#2B2A26'
        if ($on) { $nm.FontWeight = 'SemiBold' }
        $head.Children.Add($nm) | Out-Null
        $tagBits = @()
        if ($on) { $tagBits += '使用中' }
        if (Test-ThemeIsDark $name) { $tagBits += '深色' }
        if ($tagBits.Count -gt 0) {
            $tg = New-TextBlock -Text ($tagBits -join ' · ') -Size 13 -Color '#66635B'
            $tg.VerticalAlignment = 'Center'
            $tg.Margin = New-Thick 8 0 0 0
            $head.Children.Add($tg) | Out-Null
        }
        $sp.Children.Add($head) | Out-Null

        $ds = New-TextBlock -Text $th.Desc -Size 13 -Color '#66635B' -Wrap $true
        $ds.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($ds) | Out-Null

        $cell.Child = $sp
        [System.Windows.Controls.Grid]::SetColumn($cell, $i % $cols)
        [System.Windows.Controls.Grid]::SetRow($cell, [math]::Floor($i / $cols))
        $grid.Children.Add($cell) | Out-Null
    }
    $panel.Children.Add($grid) | Out-Null

    # ==================== 背景图 ====================
    $sec2 = New-RptSection -Title '背景图' -Aside '可选'
    $sec2.Margin = New-Thick 0 22 0 8
    $panel.Children.Add($sec2) | Out-Null

    $tip = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text (
        '选一张图铺在窗口背景上。图片会被复制到工具自己的文件夹里保存，' +
        '所以选完之后原图删掉、U 盘拔掉都不影响。' + "`r`n" +
        '建议选颜色比较淡、内容不太花的图 —— 太花的图会让上面的字看不清。' +
        '下面的「面板不透明度」就是用来调这个的：拉低一点图更明显，拉高一点字更清楚。')
    $panel.Children.Add($tip) | Out-Null

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Thick 0 10 0 0

    $btnPick = New-Object System.Windows.Controls.Button
    $btnPick.Content = '选择图片…'
    $btnPick.Margin = New-Thick 0 0 8 0
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
    $btnClear.Margin = New-Thick 0
    $btnClear.Add_Click({
            $st = Get-ThemeSetting
            Set-AppTheme -Name $st.Name -Image '' -Opacity $st.Opacity -Frost $st.Frost
            Redraw-AllPages
            Set-Status '已恢复纯色背景'
        })
    $row.Children.Add($btnClear) | Out-Null
    $panel.Children.Add($row) | Out-Null

    # ★ PowerShell 5.1 里 if 不能当表达式用在参数位置上 ★
    #   写成 -Text (if (...) {...} else {...}) 会静默传进去一个 $null，
    #   然后在下一行 .Margin 上炸掉。先算到变量里再传。
    # ★ 这一句决定下面两项能不能用 ★
    #   没有背景图的时候，「面板不透明度」和「磨砂」一个都不起作用。
    #   上一版它们照样是完全可用的样子 —— 点磨砂会重绘闪一下、
    #   状态栏报「已开磨砂」，但什么都没发生。有反应而反应是假的，
    #   比没反应更坏。
    $hasImg = [bool]$cur.Image -and (Test-Path -LiteralPath "$($cur.Image)")
    $nowText = if ($hasImg) { "当前背景图：$($cur.Image)" } else { '当前是纯色背景。下面两项要选了图才用得上。' }
    $now = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text $nowText
    $now.Margin = New-Thick 0 10 0 0
    $panel.Children.Add($now) | Out-Null

    $ol = New-TextBlock -Size 14 -Bold $true -Text ('面板不透明度　{0}%' -f [int]($cur.Opacity * 100))
    $ol.Margin = New-Thick 0 18 0 6
    $ol.Foreground = Get-Brush $(if ($hasImg) { '#2B2A26' } else { '#66635B' })
    Add-SubItem $panel $ol

    $sld = New-Object System.Windows.Controls.Slider
    $sld.Minimum = 0.35; $sld.Maximum = 1.0
    $sld.Value = $cur.Opacity
    $sld.TickFrequency = 0.05
    $sld.IsSnapToTickEnabled = $true
    $sld.Width = 320
    $sld.HorizontalAlignment = 'Left'
    $sld.Tag = $ol
    # ★ 没背景图就禁用 ★
    #   拖一个此刻不影响任何东西的滑块，是在浪费用户的动作。
    #   守我们自己定的「禁用即未上墨」：用不上的控件不能长得跟能用的一样。
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
    Add-SubItem $panel $sld

    $on2 = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text (
        '100% = 完全挡住背景图（和纯色一样），拉低才能看见图。')
    $on2.Margin = New-Thick 0 8 0 0
    Add-SubItem $panel $on2

    # 磨砂：背景图那一组的第二个子项
    $fcb = New-SettingCheck -Title '磨砂 —— 把背景图模糊掉' `
        -Note '图上的细节会糊成大块的颜色，压在上面的字就清楚了。想看清自己那张图就关掉它。' `
        -WhyOff '选了背景图才用得上。' `
        -Checked ([bool]$cur.Frost) -Enabled $hasImg -OnClick {
        $st = Get-ThemeSetting
        Set-AppTheme -Name $st.Name -Image $st.Image -Opacity $st.Opacity -Frost ([bool]$this.IsChecked)
        Redraw-AllPages
        Set-Status $(if ($this.IsChecked) { '已开磨砂' } else { '已关磨砂，背景图恢复原清晰度' })
    }
    $fcb.Margin = New-Thick 0 18 0 2
    Add-SubItem $panel $fcb

    # ==================== 界面动画 ====================
    $sec3 = New-RptSection -Title '界面动画'
    $sec3.Margin = New-Thick 0 22 0 8
    $panel.Children.Add($sec3) | Out-Null

    $acb = New-SettingCheck -Title '开启界面动画' `
        -Note '切换页面、点开详情时淡入，页签底下那条线也会滑过去。如果你的机器点哪都要等一下，关掉它操作反馈会更干脆 —— 关了之后所有切换都是瞬间完成，功能一模一样。' `
        -Checked ([bool]$Script:AnimEnabled) -OnClick {
        $Script:AnimEnabled = [bool]$this.IsChecked
        $st = Get-ThemeSetting
        Save-ThemeSetting -Name $st.Name -Image $st.Image -Opacity $st.Opacity -Anim $Script:AnimEnabled -Frost $st.Frost
        Set-Status $(if ($Script:AnimEnabled) { '界面动画已开启 —— 切一下页签就能看见' } else { '界面动画已关闭' })
    }
    $panel.Children.Add($acb) | Out-Null
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
    # ★ 概览页也必须重建 ★ 漏了它的话换皮肤之后整张摘要表还是旧配色
    try { if ($Script:DashRows -and $Script:DashRows.Count -gt 0) { Build-DashUI; Update-DashScore; Update-DashUI } } catch { }
    try { Build-CleanUI } catch { }
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
            '解决办法：关掉这个窗口，改成双击「电脑调优助手.exe」——' +
            '它用的是系统自带的 PowerShell 5.1，这一页就正常了。'
        } elseif ($Script:AppxFailReason) {
            $why = "原因：$Script:AppxFailReason"
        }
        $panel.Children.Add((New-TextBlock -Wrap $true -Color '#66635B' -Text (
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
        $card.Padding = New-Thick 4 10 4 10
        $card.Margin = New-Thick 0 0 0 0

        # 列轨：勾选框 / 项目 / 结果 / 参考范围
        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(0, -1, 76, 88)) {
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
            $sz = New-Badge -Text $it.Size -Fg '#66635B' -Bg '#E8E7E2'
            $sz.Margin = New-Thick 4 0 0 0
            $head.Children.Add($sz) | Out-Null
        }
        $sp.Children.Add($head) | Out-Null

        $tx = New-TextBlock -Text (Format-Reflow $it.Text) -Size 12 -Color '#66635B' -Wrap $true
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
        Show-Msg -Text '还没有勾选要卸载的应用。' | Out-Null
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
        $panel.Children.Add((New-TextBlock -Text '没有发现任何开机启动项，很干净。' -Color '#66635B')) | Out-Null
        Set-Status '就绪'
        return
    }

    Add-ColHeader $panel -First '开机启动项' -Cols @(@{ T = '结果'; W = 76 }, @{ T = '安全范围'; W = 88 })
    foreach ($it in $items) {
        # 行式表，和别的页一个语汇：没有圆角、没有底色、没有边框盒子，
        # 只有一条行间细线。深度靠表面阶梯，不靠盒子。
        $card = New-Object System.Windows.Controls.Border
        $card.Background = [System.Windows.Media.Brushes]::Transparent
        $card.BorderBrush = Get-Brush $Script:CARD_BORDER
        $card.BorderThickness = New-Thick 0 0 0 1
        $card.Padding = New-Thick 4 10 4 10
        $card.Margin = New-Thick 0 0 0 0

        # 列轨：勾选框 / 项目 / 结果 / 参考范围
        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in @(0, -1, 76, 88)) {
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
        $nm = New-TextBlock -Text $it.Name -Size 15
        $head.Children.Add($nm) | Out-Null
        $sc = New-TextBlock -Text $it.Scope -Size 11.5 -Color '#66635B'
        $sc.Margin = New-Thick 10 2 0 0
        $head.Children.Add($sc) | Out-Null
        $sp.Children.Add($head) | Out-Null

        $adv = New-TextBlock -Text $it.AdviceText -Size 12 -Color '#66635B' -Wrap $true
        $adv.Margin = New-Thick 0 5 0 0
        $sp.Children.Add($adv) | Out-Null

        $cmd = New-TextBlock -Text $it.Command -Size 11 -Color '#66635B' -Wrap $true
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
        $res = New-TextBlock -Size 15 -Color '#2B2A26' -Text $(if ($it.Enabled) { '已开启' } else { '已关闭' })
        $res.TextAlignment = 'Right'
        $res.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($res, 2)

        # AdviceLevel 本身就是「建议保留」这种说法，前面再拼一个「建议」就重了
        $rf = New-TextBlock -Text $(if ($it.AdviceLevel -like '建议*') { $it.AdviceLevel } else { '建议 ' + $it.AdviceLevel }) -Size 12 -Color '#66635B'
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
    Set-Status ("共 {0} 个开机启动项" -f $items.Count)
}

# ---------------------------------------------------------------------
#  7.5 日常维护页
# ---------------------------------------------------------------------

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
    Show-Msg -Text $msg | Out-Null
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
    $win.Title = '确认刷新率'
    $win.Width = 420; $win.SizeToContent = 'Height'
    $win.WindowStartupLocation = 'CenterScreen'
    $win.ResizeMode = 'NoResize'
    $win.Background = Get-Brush '#F6F5F2'
    # ★ 子窗口不继承主窗口的 FontFamily ★
    #   WPF 的属性继承走的是可视树，而新建的 Window 是另一棵树的根。
    #   不显式设的话，弹窗会退回系统默认字 —— 主界面是随包字体、
    #   弹窗是微软雅黑，一眼就看出是两套东西拼的。
    $win.FontFamily = New-Object System.Windows.Media.FontFamily $Script:FontStack
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
    [void]$sb.AppendLine(('工具版本：v{0}（{1}）' -f $Script:AppVersion, $Script:AppVersionDate))
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
        Show-Msg -Text "保存失败：$($_.Exception.Message)" | Out-Null
    }
}

function Build-MaintainUI {
    <#
      这一页是报告单末尾的「处置」栏：能测的先报数，能做的就跟在那一行后面。

      ★ 全页只有两种行 ★
        New-RptRow  —— 有数可报的项（刷新率、硬盘寿命、占用）
        New-ActRow  —— 只有动作的项（一键维护、开关、打开某个设置）
      上一版是四张一模一样的圆角卡，四件轻重完全不同的事看起来一样重。
    #>
    $p = $Script:UI.MaintainPanel
    $p.Children.Clear()

    function Add-Sec {
        param([string]$Title, [string]$Aside = '', [bool]$First = $false)
        $sec = New-RptSection -Title $Title -Aside $Aside
        $sec.Margin = New-Thick 0 $(if ($First) { 0 } else { 24 }) 0 8
        $p.Children.Add($sec) | Out-Null
    }

    # ==================== 例行处置 ====================
    Add-Sec -Title '例行处置' -Aside '每月一次就够' -First $true

    $r1 = New-ActRow -Name '一键日常维护' `
        -Note '清垃圾 + 刷新 DNS + 优化系统盘，一条龙。不会改任何性能设置，也不碰你的文件。'
    $bAll = New-ToolButton -Text '开始维护' -OnClick { Invoke-DailyMaintenance }
    try { $bAll.Style = $Script:Window.FindResource('ButtonPrimary') } catch { }
    # ★ 别给它加 Padding ★ HandyControl 的按钮模板自己算高度，
    #   再塞上下内边距，文字会超出按钮高度被竖着切掉。
    $bAll.Margin = New-Thick 0
    $r1.Slot.Children.Add($bAll) | Out-Null
    $p.Children.Add($r1.Row) | Out-Null

    $r2 = New-ActRow -Name '每周自动清理' `
        -Note '建一个计划任务，每周日 12:00 在后台静默跑一遍「垃圾清理」页的推荐项。不弹窗、不影响你用电脑、不碰性能设置。人不在电脑前错过了，下次开机自动补跑。'
    $cbAuto = New-Object System.Windows.Controls.CheckBox
    $cbAuto.Content = '开启'
    $cbAuto.FontSize = 13.5
    $cbAuto.VerticalAlignment = 'Center'
    $cbAuto.IsChecked = (Test-AutoCleanEnabled)
    $cbAuto.Add_Click({
            if ($this.IsChecked) {
                $ok = Enable-AutoClean -ScriptPath $PSCommandPath
                if ($ok) { Set-Status '已开启每周自动清理（每周日 12:00）' }
                else { $this.IsChecked = $false; Show-Msg -Text '创建计划任务失败，详见日志页。' | Out-Null }
            } else {
                Disable-AutoClean | Out-Null
                Set-Status '已关闭每周自动清理'
            }
        })
    $r2.Slot.Children.Add($cbAuto) | Out-Null
    $p.Children.Add($r2.Row) | Out-Null

    # ==================== 显示器 ====================
    # 买了高刷屏却还跑在 60Hz 非常常见（换线、重装驱动、接新屏都会退回去）。
    # 对 FPS 玩家来说这个差距比任何注册表优化都大，所以排在第二位。
    $cur = Get-CurrentDisplayMode
    $opts = @(Get-DisplayRefreshOptions)
    if ($cur -and $opts.Count -gt 0) {
        $maxHz = $opts[0]
        Add-Sec -Title '显示器' -Aside ("{0} × {1}" -f $cur.Width, $cur.Height)
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
                try { $b.Style = $Script:Window.FindResource('ButtonPrimary') } catch { }
                $b.Content = "{0} Hz（最高）" -f $hz
            }
            Add-RptAct $rHz $b
        }
        $p.Children.Add($rHz.Row) | Out-Null

        $t15 = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text '切换后会弹一个 15 秒倒计时确认框。万一切完黑屏或花屏，什么都别动，倒计时结束会自动切回原来的设置 —— 和 Windows 自己改分辨率时的行为一样。'
        $t15.Margin = New-Thick 0 9 0 0
        $p.Children.Add($t15) | Out-Null
    }

    # ==================== 硬盘健康 ====================
    $disks = @(Get-DiskHealthReport)
    if ($disks.Count -gt 0) {
        Add-Sec -Title '硬盘健康' -Aside '读 SMART 数据'
        $p.Children.Add((New-RptHeader -First '硬盘')) | Out-Null
        foreach ($d in $disks) {
            $abn = ($d.Level -ne '良好')
            $mark = switch ($d.Level) { '严重' { '↑↑' } '建议' { '↑' } default { '' } }

            # 固态看写入寿命，机械看通电时长 —— 各有各的参考范围。
            # 两个都读不到就只报「—」，不编数字。
            if ($null -ne $d.Wear) {
                $val = [double]$d.Wear; $max = 100; $hi = 70
                $res = [string]$d.Wear; $ref = '< 70'; $unit = '% 寿命'; $nobar = $false
            } elseif ($null -ne $d.Hours) {
                $val = [double]$d.Hours; $max = 44000; $hi = 35000
                $res = [string]$d.Hours; $ref = '< 35000'; $unit = '小时'; $nobar = $false
            } else {
                $val = $null; $max = 100; $hi = $null
                $res = '—'; $ref = ''; $unit = ''; $nobar = $true
                if (-not $abn) { $mark = '—' }
            }

            $extra = @($d.Media, $d.Size)
            if ($null -ne $d.Hours -and $null -ne $d.Wear) { $extra += "已通电 $($d.Hours) 小时" }
            if ($null -ne $d.Temp -and $d.Temp -gt 0) { $extra += "$($d.Temp) °C" }
            $extra += $d.Verdict

            $rd = New-RptRow -Name $d.Name -Result $res -Mark $mark -Ref $ref -Unit $unit `
                -Note ($extra -join '   ·   ') -NoBar $nobar
            if (-not $nobar) { Set-RangeBar $rd.Bar -Value $val -Max $max -Hi $hi -Abnormal $abn }
            $p.Children.Add($rd.Row) | Out-Null
        }
    }

    # ==================== 磁盘优化 ====================
    $vols = @(Get-VolumesToOptimize)
    if ($vols.Count -gt 0) {
        Add-Sec -Title '磁盘优化' -Aside '半年一次'
        $sd = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text '自动认介质：固态做 TRIM（恢复写入速度），机械做碎片整理。不会对固态盘做碎片整理 —— 那只会白白消耗寿命。'
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
    Add-Sec -Title '微信 / QQ 占用' -Aside '只统计，不删'
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
            $t = New-TextBlock -Text '没有找到微信或 QQ 的数据目录（可能没装，或者装在非默认位置）。' -Size 13 -Color '#66635B' -Wrap $true
            $t.Margin = New-Thick 0 10 0 0
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
            $h = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text '嫌大的话用软件自带的清理挑着删：微信 → 设置 → 文件管理 → 清理微信存储空间；QQ → 设置 → 文件管理 → 清理。它们能按聊天对象和时间筛选，比无脑全删安全得多。'
            $h.Margin = New-Thick 0 10 0 0
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
    Add-Sec -Title '快捷工具' -Aside '藏得很深的系统功能'

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
        $bt.MinWidth = 76
        $rt.Slot.Children.Add($bt) | Out-Null
        $p.Children.Add($rt.Row) | Out-Null
    }
    $tip2 = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text '顺带一提：游戏里画面卡死、显卡驱动假死的时候，按 Win + Ctrl + Shift + B 可以直接重启显卡驱动，屏幕会黑一下然后恢复，不用重启电脑。这是 Windows 自带的快捷键，不需要本工具。'
    $tip2.Margin = New-Thick 0 10 0 0
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
    $t1 = New-TextBlock -Text '还没扫描' -Size 15 -Color '#4A4842'
    $sp.Children.Add($t1) | Out-Null
    $t2 = New-TextBlock -Wrap $true -Size 13 -Color '#66635B' -Text '点上面的盘符开始。扫描期间可以切到别的页干活，结果出来会留在这儿。'
    $t2.Margin = New-Thick 0 6 0 0
    $sp.Children.Add($t2) | Out-Null
    $t3 = New-TextBlock -Wrap $true -Size 13 -Color '#66635B' -Text '扫的是「超过 300MB 的文件」，最大的 40 个。WinSxS、回收站、系统卷信息这三处跳过 —— 它们的大小是假的（硬链接），或者有专门的清理入口。'
    $t3.Margin = New-Thick 0 14 0 0
    $sp.Children.Add($t3) | Out-Null
    $panel.Children.Add($sp) | Out-Null
}

function Invoke-BigFileScan {
    param([string]$Root)
    $panel = $Script:UI.BigFilePanel
    $panel.Children.Clear()
    $panel.Children.Add((New-TextBlock -Text '正在扫描，请稍候…' -Size 13.5 -Color '#66635B')) | Out-Null
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
        $panel.Children.Add((New-TextBlock -Text ("{0} 里没有找到超过 300MB 的文件。" -f $Root) -Size 13.5 -Color '#66635B' -Wrap $true)) | Out-Null
        Set-Status '扫描完成'
        return
    }

    $hint = New-TextBlock -Size 13 -Color '#66635B' -Wrap $true -Text '点任意一行会在资源管理器里定位到它。删之前想清楚：大文件里有很多是系统必需的（pagefile.sys 虚拟内存、hiberfil.sys 休眠文件、install.wim 等），别乱删。游戏安装包、下载的视频、旧的备份文件才是该清的。'
    $hint.Margin = New-Thick 0 0 0 12
    $panel.Children.Add($hint) | Out-Null

    # 列名 + 表头线。四十个文件是一张表，不是四十张卡片 ——
    # 卡片会让每个文件看起来都是一件独立的事，而用户要做的是**比大小**。
    Add-ColHeader -Panel $panel -First '文件' -Cols @(@{ T = '大小'; W = 96 }) -Indent 0

    foreach ($f in $files) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = [System.Windows.Media.Brushes]::Transparent
        $b.BorderBrush = Get-Brush $Script:CARD_BORDER
        $b.BorderThickness = New-Thick 0 0 0 1
        $b.Padding = New-Thick 0 9 0 9
        $b.Cursor = 'Hand'
        $b.Tag = $f.Path
        $b.Add_MouseLeftButtonUp({
                try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $this.Tag) } catch { }
            })
        # 底色给的是右栏面板自己的底色（= 看着透明），悬停才浮出一层。
        # -NoLift：表格行不该上下浮动，那是卡片的语汇。
        Add-Interactive -Border $b -BgNormal '#FBFAF8' -BgHover '#F0EFEB' -NoLift

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
        $sp.Children.Add((New-TextBlock -Text $leaf -Size 14 -Color '#2B2A26' -Wrap $true)) | Out-Null
        $dir = try { [System.IO.Path]::GetDirectoryName($f.Path) } catch { '' }
        if ($dir) {
            $t = New-TextBlock -Text $dir -Size 12.5 -Color '#66635B' -Wrap $true
            $t.Margin = New-Thick 0 2 0 0
            $sp.Children.Add($t) | Out-Null
        }
        $g.Children.Add($sp) | Out-Null

        # ★ 表格数位 ★ 不加的话 1 比 8 窄，整列大小对不齐，比大小就费劲
        $sz = New-TextBlock -Text (Format-Size $f.Size) -Size 14.5 -Color '#2B2A26'
        $sz.FontWeight = 'SemiBold'
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
        '无用'     { return '#66635B' }
        '已知打扰' { return '#55606F' }
        default    { return '#66635B' }
    }
}

function Set-InspectEmpty {
    <# 扫描前的左栏。空着一大片白什么也不说，是在浪费用户的一次注视。 #>
    $p = $Script:UI.InspectPanel
    if ($null -eq $p -or $p.Children.Count -gt 0) { return }
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Thick 0 30 0 0
    $t1 = New-TextBlock -Text '还没扫描' -Size 15 -Color '#4A4842'
    $sp.Children.Add($t1) | Out-Null
    foreach ($line in @(
            '点上面的「开始扫描」。全程只读不改，扫完你再决定关谁。',
            '会扫这些地方：计划任务、注册表 Run、启动文件夹、服务、WMI 事件订阅 —— 也就是所有「能让一个程序自己跑起来」的位置。',
            '扫完按可疑程度排序：会弹黑框的排最前，然后是高危、可疑，最后是「无用」和「已知打扰」（不危险，只是没必要留着）。',
            '扫不出来也别慌 —— 定期弹的黑框多半来自某个已经在跑的程序，那种要用右边的「抓现行」。')) {
        $t = New-TextBlock -Wrap $true -Size 13 -Color '#66635B' -Text $line
        $t.Margin = New-Thick 0 12 0 0
        $sp.Children.Add($t) | Out-Null
    }
    $p.Children.Add($sp) | Out-Null
}

function Invoke-Inspect {
    $Script:UI.InspectPanel.Children.Clear()
    $Script:UI.InspectPanel.Children.Add((New-TextBlock -Text '正在扫描，请稍候…' -Size 13.5 -Color '#66635B')) | Out-Null
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
        $p.Children.Add((New-TextBlock -Wrap $true -Size 13.5 -Color '#4A4842' -Text "扫描完成，没有发现可疑项。`r`n`r`n如果还是会弹黑框，用右边的「抓现行」：先点「开启持续记录」，等下次黑框出现之后马上回来点「查看进程记录」，就能看到那一刻到底是谁在跑。")) | Out-Null
        Set-Status '扫描完成，没有发现可疑项'
        return
    }
    if ($list.Count -eq 0) {
        $p.Children.Add((New-TextBlock -Wrap $true -Size 13.5 -Color '#4A4842' -Text '按当前筛选条件没有内容 —— 也就是说没有「高危」和「会弹黑框」的项，这是好事。点「显示全部」可以看其余条目。')) | Out-Null
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
        $row.Padding = New-Thick 0 12 14 13

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
        $mk = New-TextBlock -Text $mark -Size 15 -Color $(if ($abn) { '#8A5750' } else { '#66635B' })
        if ($abn) { $mk.FontWeight = 'SemiBold' }
        $mk.VerticalAlignment = 'Top'
        $mk.Margin = New-Thick 0 1 0 0
        $g.Children.Add($mk) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)

        $nm = New-TextBlock -Text $f.Name -Size 15 -Color '#2B2A26' -Wrap $true
        if ($abn) { $nm.FontWeight = 'SemiBold' }
        $sp.Children.Add($nm) | Out-Null

        # 来源 + 会不会弹黑框，一行小字说清，不用药丸
        $kindBits = @($f.Kind)
        if ($f.Extra) { $kindBits += $f.Extra }
        $kd = New-TextBlock -Text ($kindBits -join '   ·   ') -Size 13 -Color '#66635B' -Wrap $true
        $kd.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($kd) | Out-Null

        if ($f.Command) {
            # 原始命令行。底色是「下沉面」—— 报告单上引用原始值就是这么做的，
            # 不换字体：随包字体的意义就在于不依赖系统装了什么，
            # 而且 craft-floor 拒绝「拿等宽当技术感的戏服」。
            $cb = New-Object System.Windows.Controls.Border
            $cb.Background = Get-Brush '#E5E3DC'
            $cb.Padding = New-Thick 10 7 10 7
            $cb.Margin = New-Thick 0 8 0 0
            $ct = New-TextBlock -Text $f.Command -Size 12.5 -Color '#565349' -Wrap $true
            [System.Windows.Documents.Typography]::SetNumeralAlignment($ct, 'Tabular')
            $cb.Child = $ct
            $sp.Children.Add($cb) | Out-Null
        }

        foreach ($r in $f.Reasons) {
            $rt = New-TextBlock -Text ('· ' + $r) -Size 13 -Color '#565349' -Wrap $true
            $rt.Margin = New-Thick 0 6 0 0
            $sp.Children.Add($rt) | Out-Null
        }

        # 建议。★ 只有真该警觉的那两档上墨 ★
        # 建议只在最高档上墨。「可疑」也上墨的话一页下来红字太多，真高危就不跳了。
        $ad = New-TextBlock -Text $f.Advice -Size 13 -Color $(if ($mark -eq '↑↑') { '#8A5750' } else { '#565349' }) -Wrap $true
        $ad.Margin = New-Thick 0 8 0 0
        $sp.Children.Add($ad) | Out-Null

        # ---- 处置 ----
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
            $cbx.FontSize = 13
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
            $t = New-TextBlock -Text '这一项工具不会自动改动 —— 涉及系统核心设置，误改会开不了机。请先杀毒，确认之后手动处理。' -Size 13 -Color '#66635B' -Wrap $true
            $t.Margin = New-Thick 0 10 0 0
            $sp.Children.Add($t) | Out-Null
        }

        $g.Children.Add($sp) | Out-Null

        # --- 判定（右列，和列名对齐）---
        # 会弹黑框的那条就把「会弹黑框」写在判定里 ——
        # 标记是 ↑↑ 而判定写「可疑」，两处对不上，读者会先以为自己看错了。
        $lvText = if ($f.Flash) { '会弹黑框' } else { $f.Level }
        $lv = New-TextBlock -Text $lvText -Size 13.5 -Color $(if ($abn) { '#8A5750' } else { '#66635B' })
        if ($abn) { $lv.FontWeight = 'SemiBold' }
        $lv.TextAlignment = 'Right'
        $lv.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetColumn($lv, 2)
        $g.Children.Add($lv) | Out-Null

        $row.Child = $g
        $p.Children.Add($row) | Out-Null
    }
    Set-Status ("扫描完成：" + $Script:UI.InspectSummary.Text)
}

# ---- 抓现行：实时进程监控 ----
$Script:WatchTimer = $null

function New-ProcRow {
    <# 一条进程记录的卡片。会弹黑框的用醒目颜色标出来。 #>
    param([string]$Head, [string]$Sub, [string]$Cmd, [bool]$Hot)
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush $(if ($Hot) { '#F0EADC' } else { '#FBFAF8' })
    $b.BorderBrush = Get-Brush $(if ($Hot) { '#7A6B45' } else { '#DDDBD5' })
    $b.BorderThickness = New-Thick $(if ($Hot) { 3 } else { 0 }) 0 0 0
    $b.CornerRadius = New-Object System.Windows.CornerRadius 4
    $b.Padding = New-Thick 10 7 10 8
    $b.Margin = New-Thick 0 0 0 5
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((New-TextBlock -Text $Head -Size 12 -Bold $true -Color $(if ($Hot) { '#89694F' } else { '#4A4842' }) -Wrap $true)) | Out-Null
    if ($Sub) {
        $t = New-TextBlock -Text $Sub -Size 11.5 -Color '#66635B' -Wrap $true
        $t.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($t) | Out-Null
    }
    if ($Cmd) {
        $t2 = New-TextBlock -Text $Cmd -Size 10.5 -Color '#66635B' -Wrap $true
        $t2.Margin = New-Thick 0 3 0 0
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
    $Script:UI.RecentRunPanel.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#66635B' -Text '监控已启动。现在正常用电脑，等黑框出现——出现的瞬间这里就会多出几条记录。带橙色标记的就是控制台进程（也就是黑框本身），看它的「父进程」是谁，那就是元凶。')) | Out-Null
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
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#66635B' -Text '最近 3 小时没有记录到控制台进程。如果刚开启记录，要等下次弹窗之后再来看。')) | Out-Null
        Set-Status '就绪'
        return
    }
    $h = New-TextBlock -Wrap $true -Size 11.5 -Color '#66635B' -Text '最近 3 小时内创建过的控制台进程（也就是黑框），按次数从多到少排。次数特别多的那条，基本就是你看到的规律性弹窗。重点看「父进程」——那是真正开出黑框的程序。'
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
        $p.Children.Add((New-TextBlock -Wrap $true -Size 12 -Color '#66635B' -Text '过去 24 小时没有任务运行记录。如果刚刚才开启记录，那要等下次任务运行才会有内容。')) | Out-Null
        return
    }

    $h = New-TextBlock -Wrap $true -Size 11.5 -Color '#66635B' -Text '按最近运行时间排序。跑得特别频繁（次数很多）的那几条，最可能就是你看到的规律性弹窗。'
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
        $t1 = New-TextBlock -Text $r.TaskName -Size 11.5 -Color '#565349' -Wrap $true
        $t1.Margin = New-Thick 0 3 0 0
        $sp.Children.Add($t1) | Out-Null
        if ($r.Exe) {
            $t2 = New-TextBlock -Text $r.Exe -Size 10.5 -Color '#66635B' -Wrap $true
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

    # ==================== 登记信息 ====================
    #   化验单最上面那一栏：姓名、年龄、送检科室。
    #   两列对齐（标签 | 值），细线分隔 —— 这样才扫得快。
    $info.Children.Add((New-RptSection -Title '受检机器')) | Out-Null

    foreach ($row in (Get-SystemReport)) {
        $b = New-Object System.Windows.Controls.Border
        $b.BorderBrush = Get-Brush $Script:CARD_BORDER
        $b.BorderThickness = New-Thick 0 0 0 1
        $b.Padding = New-Thick 0 9 0 9

        $g = New-Object System.Windows.Controls.Grid
        $cdK = New-Object System.Windows.Controls.ColumnDefinition
        $cdK.Width = New-Object System.Windows.GridLength 108.0
        $g.ColumnDefinitions.Add($cdK)
        $cdV = New-Object System.Windows.Controls.ColumnDefinition
        $cdV.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        $g.ColumnDefinitions.Add($cdV)

        $k = New-TextBlock -Text $row.Key -Size 13 -Color '#66635B' -Wrap $true
        $k.VerticalAlignment = 'Top'
        $g.Children.Add($k) | Out-Null

        $v = New-TextBlock -Text $row.Value -Size 14 -Color '#2B2A26' -Wrap $true
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        [System.Windows.Controls.Grid]::SetColumn($v, 1)
        $g.Children.Add($v) | Out-Null

        $b.Child = $g
        $info.Children.Add($b) | Out-Null
        [void]$sb.AppendLine("$($row.Key)：$($row.Value)")
    }

    # ==================== 体检结论 ====================
    Set-Status '正在做系统体检…'
    Sync-UI
    $ap = $Script:UI.AdvicePanel
    $ap.Children.Clear()
    $ap.Children.Add((New-RptSection -Title '检验结论' -Aside '按性价比从高到低排')) | Out-Null
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('===== 体检结论 =====')

    foreach ($a in (Get-HealthAdvice)) {
        # ★ 判读标记，不是彩色药丸 ★
        #   上一版每条是「圆角卡 + 整块底色 + 4px 彩色左边条 + 彩色标签」，
        #   三档各一种颜色，满屏都是色块 —— 真正「严重」的那条反而不跳。
        $mark = switch ($a.Level) { '严重' { '↑↑' } '建议' { '↑' } default { '' } }
        $abn = [bool]$mark

        $row = New-Object System.Windows.Controls.Border
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.BorderBrush = Get-Brush $Script:CARD_BORDER
        $row.BorderThickness = New-Thick 0 0 0 1
        $row.Padding = New-Thick 0 13 14 14

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

        $mk = New-TextBlock -Text $mark -Size 15 -Color $(if ($abn) { '#8A5750' } else { '#66635B' })
        if ($abn) { $mk.FontWeight = 'SemiBold' }
        $mk.VerticalAlignment = 'Top'
        $mk.Margin = New-Thick 0 1 0 0
        $g.Children.Add($mk) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $ttl = New-TextBlock -Text $a.Title -Size 15.5 -Color '#2B2A26' -Wrap $true
        if ($abn) { $ttl.FontWeight = 'SemiBold' }
        $sp.Children.Add($ttl) | Out-Null
        $bd = New-TextBlock -Text (Format-Reflow $a.Text) -Size 13.5 -Color '#565349' -Wrap $true
        $bd.Margin = New-Thick 0 7 0 0
        $sp.Children.Add($bd) | Out-Null
        $g.Children.Add($sp) | Out-Null

        $lv = New-TextBlock -Text $a.Level -Size 13.5 -Color $(if ($abn) { '#8A5750' } else { '#66635B' })
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
            '信息'   { @{ Line = '#55606F'; Bg = '#E4E7EC' } }
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

function Build-AdviceCards {
    <#
      把一串 @{ Kind; Title; Text } 画成右边那一列卡片。
      超频陪练和厂商软件两页共用这个 —— 卡片长相和帧数诊断保持一致，
      用户不用再学一套新的看法。
    #>
    param([string]$Head, [string]$Sub, $Items)

    $ap = $Script:UI.AdvicePanel
    $ap.Children.Clear()

    $t = New-TextBlock -Text $Head -Size 15 -Bold $true
    $t.Margin = New-Thick 0 0 0 4
    $ap.Children.Add($t) | Out-Null
    if ($Sub) {
        $s = New-TextBlock -Text $Sub -Size 12.5 -Color '#565349' -Wrap $true
        $s.Margin = New-Thick 0 0 0 12
        $ap.Children.Add($s) | Out-Null
    }

    foreach ($d in @($Items)) {
        # 颜色沿用全局那套语义色：红=当心、卡其=要动手、蓝=背景、绿=流程
        $c = switch ($d.Kind) {
            '当心' { @{ Line = '#8A5750'; Bg = '#EFE3E0' } }
            '动手' { @{ Line = '#7A6B45'; Bg = '#F0EADC' } }
            '步骤' { @{ Line = '#556B54'; Bg = '#E7EBE4' } }
            default { @{ Line = '#55606F'; Bg = '#E4E7EC' } }
        }
        $card = New-Object System.Windows.Controls.Border
        $card.Background      = Get-Brush $c.Bg
        $card.BorderBrush     = Get-Brush $c.Line
        $card.BorderThickness = New-Thick 4 0 0 0
        $card.CornerRadius    = New-Object System.Windows.CornerRadius 6
        $card.Padding         = New-Thick 14 12 14 12
        $card.Margin          = New-Thick 0 0 0 10

        $sp = New-Object System.Windows.Controls.StackPanel
        $h = New-Object System.Windows.Controls.StackPanel
        $h.Orientation = 'Horizontal'
        $h.Children.Add((New-Badge -Text $d.Kind -Fg $c.Line -Bg (Get-TintBg $c.Line))) | Out-Null
        $sp.Children.Add($h) | Out-Null
        $ttl = New-TextBlock -Text $d.Title -Size 14 -Bold $true -Wrap $true
        $ttl.Margin = New-Thick 0 4 0 6
        $sp.Children.Add($ttl) | Out-Null
        $sp.Children.Add((New-TextBlock -Text (Format-Reflow $d.Text) -Size 12.5 -Color '#565349' -Wrap $true)) | Out-Null
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
$Script:UI.CleanSearch.Add_TextChanged({ Update-CleanFilter })
$Script:UI.BtnApplySelected.Add_Click({ Invoke-ApplyTweaks (Get-CheckedTweaks) })
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
$Script:UI.BtnCopyLog.Add_Click({
        # 表格不像 TextBox 能直接框选复制，所以给一个「全拿走」的出口
        try {
            [System.Windows.Clipboard]::SetText(($Script:LogLines -join [Environment]::NewLine))
            Set-Status ('已复制 {0} 条日志到剪贴板' -f $Script:LogLines.Count)
        } catch { Set-Status '复制失败，日志文件在备份文件夹里' }
    })
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
$Script:UI.BtnHealthScan.Add_Click({ Build-HealthUI })
$Script:UI.BtnFpsDiag.Add_Click({ Build-FpsDiagUI })
$Script:UI.BtnOcCoach.Add_Click({ Build-OcCoachUI })
$Script:UI.BtnVendor.Add_Click({ Build-VendorUI })
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
            Show-Msg -Text "添加失败：$($_.Exception.Message)`r`n`r`n如果你装了第三方杀毒软件（360/火绒/腾讯管家），Windows Defender 会被自动关闭，这个功能就用不了了 —— 请去那个杀毒软件里手动添加信任目录。" | Out-Null
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
            Show-Msg -Text '体检报告已复制到剪贴板，可以直接粘贴发给别人看。' | Out-Null
        } catch {
            Show-Msg -Text "复制失败：$($_.Exception.Message)" | Out-Null
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
    # 动画开关和皮肤存在同一份配置里，启动时一起读回来
    $Script:AnimEnabled = [bool]$savedTheme.Anim
    # 系统级「减弱动效」优先于用户开关 —— 会关这个的人多半有晕动症或机器太慢
    $Script:SystemAnimOff = Test-SystemReducedMotion
    if ($Script:SystemAnimOff) { Write-Log '检测到系统已关闭「显示动画」，界面动效自动减弱（保留淡入，去掉位移）' '信息' }
    Set-AppTheme -Name $savedTheme.Name -Image $savedTheme.Image -Opacity $savedTheme.Opacity -Frost $savedTheme.Frost
    Apply-PanelOpacity
} catch { Write-Log "套用皮肤失败，用默认配色：$($_.Exception.Message)" '警告' }

$Script:Window.Title = "电脑调优助手 v$Script:AppVersion"

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
        # 所有按钮挂上按下反馈。
        # HandyControl 自带的是颜色变化，在这套完全消色的界面上几乎看不出来；
        # 缩放是尺寸变化，任何配色下都能感知，而且走 RenderTransform 不触发重排。
        try { Add-PressFeedbackAll $Script:Window } catch { }
        Build-StartupUI
        Build-MaintainUI
        Build-BigFileDrives
        Build-RecentRuns
        Set-InspectEmpty        # 弹窗排查页扫描前的空状态
        Build-LogUI             # 把窗口出来之前记下的那几条日志补画出来
        try { Update-TabInk $false } catch { }
        try { Start-TitleReveal } catch { }
        Build-ThemeUI
        # 概览页：先建壳子再开硬件监控。
        # Initialize-Dash 要枚举全部硬件，实测约 3 秒，所以放在
        # 窗口已经显示出来之后做 —— 不然用户会觉得「双击了半天不出来」。
        Build-DashUI
        Initialize-Dash
        Update-DashScore
        Start-DashTimer
        if (Test-ProcAuditEnabled) { $Script:UI.BtnProcAudit.Content = '关闭持续记录' }
        Build-HealthUI
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
# ---------------------------------------------------------------------
#  头部标题逐字淡入
# ---------------------------------------------------------------------
function Start-TitleReveal {
    <#
      「系统检验报告」六个字逐个淡入 + 上移，每字错开 38ms。
      照 React Bits 的 SplitText 做的克制版。

      ★ 只在程序启动时跑这一次 ★
        每切一次页都演一遍就成了表演。开场演一次是「报告正在出」，
        演第二次就是在耽误人干活。

      ★ 做法是把整块标题换成一串单字 ★
        换完之后每个字自带同一个隐式 TextBlock 样式，
        换肤时照样跟着 DynamicResource 走，不会留旧配色。
    #>
    if ($Script:TitleRevealed) { return }
    $Script:TitleRevealed = $true
    $old = $Script:UI.RptTitle
    if ($null -eq $old) { return }
    $parent = $old.Parent -as [System.Windows.Controls.StackPanel]
    if ($null -eq $parent) { return }
    $text = "$($old.Text)"
    if (-not $text) { return }

    $strip = New-Object System.Windows.Controls.StackPanel
    $strip.Orientation = 'Horizontal'
    $idx = $parent.Children.IndexOf($old)
    $parent.Children.Remove($old)
    $parent.Children.Insert($idx, $strip)

    $anim = [bool]$Script:AnimEnabled
    $i = 0
    foreach ($ch in $text.ToCharArray()) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "$ch"
        $t.FontSize = $old.FontSize
        $t.FontWeight = $old.FontWeight
        $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextMain')
        $strip.Children.Add($t) | Out-Null

        if (-not $anim) { $i++; continue }

        $t.Opacity = 0
        $tt = New-Object System.Windows.Media.TranslateTransform 0, 10
        $t.RenderTransform = $tt

        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $begin = [TimeSpan]::FromMilliseconds(38 * $i)
        $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(300))

        $fa = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fa.From = 0; $fa.To = 1; $fa.Duration = $dur; $fa.BeginTime = $begin
        $t.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fa)

        $ya = New-Object System.Windows.Media.Animation.DoubleAnimation
        $ya.From = 10; $ya.To = 0; $ya.Duration = $dur; $ya.BeginTime = $begin
        $ya.EasingFunction = $ease
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ya)

        $i++
    }
}

# ---------------------------------------------------------------------
#  页签指示条：滑过去，不是跳过去
# ---------------------------------------------------------------------
function Update-TabInk {
    <#
      把指示条挪到当前页签底下。
        $Animate = $false 时直接落位（窗口刚出来、拉伸窗口时用），
        $true 时用 220ms 缓出滑过去。

      ★ 位置必须现算 ★
        页签宽度随字数变，窗口一拉伸整排都会挪。
        写死坐标的话换一套字体、改一个页签名就全歪了。
    #>
    param([bool]$Animate = $true)
    $ink = $Script:UI.TabInk
    $layer = $Script:UI.TabInkLayer
    if ($null -eq $ink -or $null -eq $layer) { return }
    $item = $Script:UI.Tabs.SelectedItem -as [System.Windows.Controls.TabItem]
    if ($null -eq $item -or -not $item.IsVisible) { return }

    # ★ 不能向 $layer 求变换 ★
    #   TransformToAncestor 要求对方真是祖先，而这层 Canvas 是页签的**兄弟**。
    #   向它求会抛异常，而且被 catch 吞掉 —— 表现是指示条永远不出现，不报错。
    #   改向根 Grid 求；Canvas 跨满整个根 Grid，两者原点重合，坐标直接用。
    $root = $layer.Parent
    if ($null -eq $root) { return }
    try {
        $pt = $item.TransformToAncestor($root).Transform((New-Object System.Windows.Point 0, 0))
    } catch { return }
    $w = $item.ActualWidth
    $h = $item.ActualHeight
    if ($w -le 0) { return }

    # 线画在页签文字下面一点，不贴着底边 —— 贴着会和下面的内容挤在一起
    $top = $pt.Y + $h - 3
    [System.Windows.Controls.Canvas]::SetTop($ink, $top)
    $ink.Visibility = 'Visible'

    $fromX = [double][System.Windows.Controls.Canvas]::GetLeft($ink)
    if ([double]::IsNaN($fromX)) { $fromX = $pt.X }

    if (-not $Animate -or -not $Script:AnimEnabled) {
        [System.Windows.Controls.Canvas]::SetLeft($ink, $pt.X)
        $ink.Width = $w
        return
    }

    # ★ 动 Canvas.Left 而不是 RenderTransform ★
    #   Canvas 上的元素不参与布局，改 Left 不会触发任何重排；
    #   而且 Left 是附加属性，动画目标要写成 (Canvas.Left)。
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(220))

    $aL = New-Object System.Windows.Media.Animation.DoubleAnimation
    $aL.From = $fromX; $aL.To = $pt.X; $aL.Duration = $dur; $aL.EasingFunction = $ease
    $aW = New-Object System.Windows.Media.Animation.DoubleAnimation
    $aW.From = $ink.ActualWidth; $aW.To = $w; $aW.Duration = $dur; $aW.EasingFunction = $ease

    $sb = New-Object System.Windows.Media.Animation.Storyboard
    [System.Windows.Media.Animation.Storyboard]::SetTarget($aL, $ink)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($aL,
        (New-Object System.Windows.PropertyPath '(Canvas.Left)'))
    [System.Windows.Media.Animation.Storyboard]::SetTarget($aW, $ink)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($aW,
        (New-Object System.Windows.PropertyPath 'Width'))
    $sb.Children.Add($aL) | Out-Null
    $sb.Children.Add($aW) | Out-Null
    $sb.Begin()
}

$Script:AppxBuilt = $false
$Script:UI.Tabs.Add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $Script:UI.Tabs) { return }
        # 切页签时让新页面淡入，比瞬间闪过去舒服
        try { Start-FadeSlideIn $Script:UI.Tabs.SelectedContent -Ms 160 -SlideY 6 } catch { }
        # 指示条滑到新页签底下。要排到布局算完之后，不然拿到的是旧宽度。
        try {
            $Script:Window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Loaded,
                [action] { Update-TabInk $true }) | Out-Null
        } catch { }
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
    try {
        $bp = $Script:Window.FindResource('ButtonPrimary')
        $tpl = ($bp.Setters | Where-Object { $_.Property.Name -eq 'Template' }).Value
        if (-not $tpl) { $styleBad += 'ButtonPrimary 没有 Template' }
        else {
            $hit = @($tpl.Triggers | Where-Object { "$($_.Property)" -eq 'IsMouseOver' -and $_.EnterActions.Count -gt 0 })
            if ($hit.Count -eq 0) { $styleBad += 'ButtonPrimary 的悬停高光没挂上（可能又被库的同名键盖了）' }
        }
    } catch { $styleBad += "ButtonPrimary 解不出来：$($_.Exception.Message)" }
    try {
        $ics = $Script:UI.Tabs.ItemContainerStyle
        if ($null -eq $ics) { $styleBad += '页签没有用我们的 ItemContainerStyle，会退回库的默认蓝下划线' }
    } catch { $styleBad += '页签容器样式查不了' }
    # 点「说明文字」能不能切勾。
    # 老板点名的就是这个交互 —— 转发不生效等于根本没改。
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
    # 悬停光斑：Start-Spotlight 整个包在 try/catch 里，
    # 里面出事它会静静地什么也不做 —— 这种形状必须有人盯。
    try {
        $probe = New-Object System.Windows.Controls.Border
        Add-Interactive -Border $probe -BgNormal '#E4E3DE' -BgHover '#EDECE8' -NoLift -Spotlight
        Start-Spotlight $probe
        if ($probe.Background -isnot [System.Windows.Media.RadialGradientBrush]) {
            $styleBad += '悬停光斑没生效（Start-Spotlight 里抛了异常并被吞掉）'
        } elseif ($probe.Background.GradientStops.Count -lt 2) {
            $styleBad += '悬停光斑的渐变停止点不对'
        }
    } catch { $styleBad += "悬停光斑自检报错：$($_.Exception.Message)" }
    if ($styleBad.Count -gt 0) {
        Write-Host ('自检失败：控件样式' + [Environment]::NewLine + '  ' + ($styleBad -join ([Environment]::NewLine + '  '))) -ForegroundColor Red
        exit 5
    }

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
    Build-OcCoachUI
    $ocCards = $Script:UI.AdvicePanel.Children.Count
    Build-VendorUI
    $vendorCards = $Script:UI.AdvicePanel.Children.Count
    Build-HealthUI
    Write-Host ('自检通过：优化项 {0} / 预设 {1} / 清理项 {2} / 启动项 {3} / 维护项 {4} / 盘符 {5} / 排查结果 {6} / 运行记录 {7} / 体检卡片 {8} / 帧数诊断 {9} / 自带应用 {10} / 皮肤 {11} / 超频陪练 {12} / 厂商建议 {13}' -f `
            $Script:UI.TweakPanel.Children.Count, $Script:Presets.Count,
        $Script:UI.CleanPanel.Children.Count, $Script:UI.StartupPanel.Children.Count,
        $Script:UI.MaintainPanel.Children.Count, $Script:UI.BigFileDrives.Children.Count,
        $Script:UI.InspectPanel.Children.Count, $Script:UI.RecentRunPanel.Children.Count,
        $Script:UI.AdvicePanel.Children.Count, $fpsCards, $Script:UI.AppxPanel.Children.Count, $themeCards, $ocCards, $vendorCards)
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
$Script:Window.Add_SizeChanged({ try { Update-TabInk $false } catch { } })
$Script:Window.Add_Closed({ try { if ($Script:WatchTimer) { $Script:WatchTimer.Stop() }; Stop-ProcWatch } catch { } })
$Script:Window.Add_Closed({ try { Stop-DashTimer; Close-Dash } catch { } })

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
                $file = Join-Path $Shot ($name + '.png')
                try {
                    $w = [int]$Script:Window.ActualWidth
                    $h = [int]$Script:Window.ActualHeight
                    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap `
                        $w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
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
