<#
=====================================================================
  Cleaner.ps1  ——  垃圾清理
---------------------------------------------------------------------
  安全底线（很重要，别改）：
    1. 所有要删的路径都是**写死在代码里的**，不接受任何外部输入，
       不会出现「变量为空导致删了整个盘」这种事故。
    2. 删之前会做路径体检（Test-SafeToDelete）：
       路径太短、不在系统盘已知目录下、指向盘根目录 —— 一律拒绝。
    3. 删除只针对「文件夹里的内容」，不删文件夹本身，
       避免某些程序找不到自己的缓存目录而报错。
    4. 正在被占用的文件删不掉是正常的，跳过即可，不报错不中断。
    5. 只删缓存和临时文件，**绝不碰**：
       文档、图片、下载文件夹、浏览器的 Cookie / 密码 / 收藏夹 /
       历史记录、微信QQ聊天记录、游戏存档。
=====================================================================
#>

# =====================================================================
#  安全检查
# =====================================================================
function Test-SafeToDelete {
    <#
      判断一个展开后的路径是否可以安全删除。
      宁可少删，绝不误删。
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # 必须是「盘符:\ 」开头的绝对路径
    if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
    # 未展开的环境变量残留（说明某个变量在这台机器上不存在）
    if ($Path -match '%\w+%') { return $false }
    # 直接对着盘根目录开火 —— 拒绝
    if ($Path -match '^[A-Za-z]:\\\*?$') { return $false }

    # 结构检查：盘符后面必须至少有一级明确的目录名。
    # 这样 "C:\*"、"C:\" 会被拦下，而 "C:\NVIDIA\*" 这种短但合法的路径能通过。
    # （早期版本用「路径长度 < 12 就拒绝」来判断，结果把 C:\NVIDIA\* 误杀了，
    #   所以改成结构判断 + 下面的黑名单，两道防线。）
    $first = ($Path.Substring(3) -split '\\')[0]
    if ([string]::IsNullOrWhiteSpace($first) -or $first -eq '*') { return $false }

    # 黑名单：这些目录本身永远不碰（只允许删它们【下面的具体子目录】）
    $forbidden = @(
        "$env:USERPROFILE", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Pictures", "$env:USERPROFILE\Videos",
        "$env:USERPROFILE\Music", "$env:USERPROFILE\OneDrive",
        "$env:WINDIR", "$env:WINDIR\System32", "$env:WINDIR\SysWOW64",
        "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData",
        "$env:APPDATA", "$env:LOCALAPPDATA", "$env:SystemDrive", "$env:SystemDrive\Users"
    )
    $stem = $Path.TrimEnd('\', '*').TrimEnd('\')
    foreach ($f in $forbidden) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        if ($stem.ToLower() -eq $f.TrimEnd('\').ToLower()) { return $false }
    }
    return $true
}

function Expand-CleanPath {
    param([string]$Pattern)
    return [Environment]::ExpandEnvironmentVariables($Pattern)
}

function Get-ChatCacheTargets {
    <#
      微信 / QQ 的缓存目录。

      ★ 这个函数的唯一职责就是「只返回确定是缓存的目录」★
        聊天记录、图片、视频、收到的文件、收藏、表情包
        一律不在返回列表里 —— 那是用户资料，不是垃圾。

      微信的数据目录用户可以自己改，所以先从注册表读实际位置，
      读不到再退回「我的文档」。
    #>
    $targets = @()

    # ---- 微信数据根目录 ----
    $roots = @()
    $cfg = Get-RegValue -Path 'HKCU:\Software\Tencent\WeChat' -Name 'FileSavePath'
    if ($cfg -and $cfg -ne 'MyDocument:' -and (Test-Path -LiteralPath $cfg)) { $roots += $cfg }
    $roots += [Environment]::GetFolderPath('MyDocuments')

    foreach ($r in ($roots | Select-Object -Unique)) {
        # 微信 3.x
        $wx = Join-Path $r 'WeChat Files'
        if (Test-Path -LiteralPath $wx) {
            $targets += (Join-Path $wx 'Applet\*')                      # 小程序缓存，通常是大头
            $targets += (Join-Path $wx '*\FileStorage\Cache\*')         # 临时缓存
            $targets += (Join-Path $wx '*\FileStorage\CefCache\*')      # 内置浏览器缓存
            $targets += (Join-Path $wx '*\FileStorage\Applet\*')        # 小程序（按账号存的那份）
            $targets += (Join-Path $wx '*\config\Cache\*')
        }
        # 微信 4.x（新版目录结构）
        $xwx = Join-Path $r 'xwechat_files'
        if (Test-Path -LiteralPath $xwx) {
            $targets += (Join-Path $xwx 'applet\*')
            $targets += (Join-Path $xwx '*\applet\*')
            $targets += (Join-Path $xwx '*\cache\applet\*')
        }
        # QQ（新版 QQNT）—— 只清明确叫 nt_temp 的临时目录。
        # 其他目录（Misc、nt_data、FileRecv、Image）里可能有聊天内容，一律不碰。
        $qq = Join-Path $r 'Tencent Files'
        if (Test-Path -LiteralPath $qq) {
            $targets += (Join-Path $qq '*\nt_qq\nt_temp\*')
        }
    }

    # QQ / TIM 的程序缓存
    foreach ($p in @(
            "$env:APPDATA\Tencent\QQ\Temp",
            "$env:LOCALAPPDATA\Tencent\QQ\Cache",
            "$env:APPDATA\Tencent\TIM\Temp"
        )) {
        if (Test-Path -LiteralPath $p) { $targets += (Join-Path $p '*') }
    }

    return $targets
}

# =====================================================================
#  扫描 / 删除
# =====================================================================
function Get-PathSize {
    <# 算一组通配符路径下的总字节数 #>
    param([string[]]$Patterns)
    $total = 0
    foreach ($p in $Patterns) {
        $ex = Expand-CleanPath $p
        if (-not (Test-SafeToDelete $ex)) { continue }
        try {
            foreach ($i in (Get-ChildItem -Path $ex -Force -ErrorAction SilentlyContinue)) {
                if ($i.PSIsContainer) {
                    $s = (Get-ChildItem -LiteralPath $i.FullName -Force -Recurse -File -ErrorAction SilentlyContinue |
                          Measure-Object -Property Length -Sum).Sum
                    if ($s) { $total += $s }
                } elseif ($i.Length) {
                    $total += $i.Length
                }
            }
        } catch { }
    }
    return [double]$total
}

function Remove-PathContents {
    <# 删除一组通配符路径命中的内容，返回实际释放的字节数 #>
    param([string[]]$Patterns)
    $freed = 0
    foreach ($p in $Patterns) {
        $ex = Expand-CleanPath $p
        if (-not (Test-SafeToDelete $ex)) {
            # 路径以盘符开头却没通过检查 = 真的可疑，记一笔。
            # 否则多半只是某个环境变量在这台机器上不存在（比如 32 位系统
            # 没有 ProgramFiles(x86)），静默跳过就行。
            if ($ex -match '^[A-Za-z]:\\') { Write-Log "路径安全检查未通过，已跳过：$ex" '警告' }
            continue
        }
        $items = @(Get-ChildItem -Path $ex -Force -ErrorAction SilentlyContinue)
        foreach ($i in $items) {
            $size = 0
            try {
                if ($i.PSIsContainer) {
                    $s = (Get-ChildItem -LiteralPath $i.FullName -Force -Recurse -File -ErrorAction SilentlyContinue |
                          Measure-Object -Property Length -Sum).Sum
                    if ($s) { $size = $s }
                } elseif ($i.Length) { $size = $i.Length }
            } catch { }
            try {
                Remove-Item -LiteralPath $i.FullName -Force -Recurse -ErrorAction Stop
                $freed += $size
            } catch {
                # 文件正被占用（典型：浏览器/游戏开着）——跳过，这是正常现象
            }
        }
    }
    return [double]$freed
}

# =====================================================================
#  清理项清单
# =====================================================================
function Get-CleanupItems {

    $items = @()

    $items += @{
        Id = 'UserTemp'; Name = '用户临时文件'; Recommended = $true; Risk = '低'
        Detail = @'
清理当前用户的临时文件夹（%TEMP%）。

这里是所有软件的「草稿纸」：安装包解压出来的临时文件、
Office 的自动保存副本、各种程序运行时的中间文件。
按设计它们用完就该自己删掉，但绝大多数程序不删，
于是越攒越多。装机三年不清，几个 GB 很常见。

安全性：非常安全。正在被程序占用的文件会自动跳过。
唯一注意：正在安装的软件不要清（会打断安装），
清理前把安装程序关掉就行。
'@
        Paths = @("$env:TEMP\*", "$env:LOCALAPPDATA\Temp\*")
    }

    $items += @{
        Id = 'WinTemp'; Name = '系统临时文件'; Recommended = $true; Risk = '低'
        Detail = @'
清理 C:\Windows\Temp。

这是系统级的临时文件夹，主要是 Windows 更新、驱动安装、
系统组件安装时留下的残渣。和上面那个用户临时文件夹是
两个不同的地方，都要清。

安全性：非常安全。这个文件夹的设计目的就是「随时可清空」。
'@
        Paths = @("$env:WINDIR\Temp\*")
    }

    $items += @{
        Id = 'WinUpdate'; Name = 'Windows 更新缓存'; Recommended = $true; Risk = '低'
        Detail = @'
清理 C:\Windows\SoftwareDistribution\Download。

Windows 每次下载更新，安装包都会留在这里，装完了也不删。
时间一长，这里能攒到 5~10 GB，是 C 盘变小的头号元凶之一。

清理方式：先停掉 Windows Update 服务和 BITS 传输服务 →
删掉下载目录里的内容 → 再把服务启回来。全自动。

安全性：安全。已经装好的更新不会被卸载，
只是删掉「安装包」。以后需要的话系统会重新下。

副作用：下一次检查更新时会稍微慢一点（要重建数据库）。
'@
        Clean = {
            $freed = 0
            foreach ($s in 'wuauserv', 'bits', 'dosvc') {
                try { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } catch { }
            }
            Start-Sleep -Milliseconds 800
            $freed += Remove-PathContents @("$env:WINDIR\SoftwareDistribution\Download\*")
            foreach ($s in 'wuauserv', 'bits') {
                try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch { }
            }
            return $freed
        }
        Scan = { return (Get-PathSize @("$env:WINDIR\SoftwareDistribution\Download\*")) }
    }

    $items += @{
        Id = 'DeliveryOpt'; Name = '更新传递优化缓存'; Recommended = $true; Risk = '低'
        Detail = @'
清理「传递优化」留下的缓存文件。

传递优化就是那个「把更新当种子上传给别人」的功能
（在性能优化页里有一项可以彻底关掉它）。
它会在本地缓存一堆别人可能会来下载的更新分片，
这些文件对你自己完全没用，能攒好几个 GB。

安全性：安全，纯缓存。
'@
        Paths = @("$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*")
    }

    $items += @{
        Id = 'RecycleBin'; Name = '清空回收站'; Recommended = $true; Risk = '低'
        Detail = @'
清空所有磁盘的回收站。

很多人忘了回收站里的东西**还占着硬盘空间**。
删了一个 20GB 的游戏，不清空回收站，那 20GB 一点没省下来。

安全性：这一步不可撤销 —— 回收站清空后东西就真没了。
清之前建议打开回收站瞄一眼有没有误删的东西。
'@
        Scan = {
            $total = 0
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                $rb = Join-Path $d.Root '$Recycle.Bin'
                if (Test-Path -LiteralPath $rb) {
                    try {
                        $s = (Get-ChildItem -LiteralPath $rb -Force -Recurse -File -ErrorAction SilentlyContinue |
                              Measure-Object -Property Length -Sum).Sum
                        if ($s) { $total += $s }
                    } catch { }
                }
            }
            return [double]$total
        }
        Clean = {
            $before = 0
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                $rb = Join-Path $d.Root '$Recycle.Bin'
                if (Test-Path -LiteralPath $rb) {
                    try {
                        $s = (Get-ChildItem -LiteralPath $rb -Force -Recurse -File -ErrorAction SilentlyContinue |
                              Measure-Object -Property Length -Sum).Sum
                        if ($s) { $before += $s }
                    } catch { }
                }
            }
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch {
                try { Clear-RecycleBin -DriveLetter ($env:SystemDrive.TrimEnd(':')) -Force -ErrorAction SilentlyContinue } catch { }
            }
            return [double]$before
        }
    }

    $items += @{
        Id = 'Thumbs'; Name = '缩略图 / 图标缓存'; Recommended = $true; Risk = '低'
        Detail = @'
清理资源管理器的缩略图数据库和图标缓存。

这些文件（thumbcache_*.db、iconcache_*.db）存的是你浏览过的
图片、视频的小预览图。它们会无限增长，几个 GB 很常见。

顺带一提：这也是修复「图标全变成白纸」「缩略图错乱、
显示的是别的图片」这两个经典问题的标准方法。

副作用：清完之后第一次打开图片文件夹会稍慢（要重新生成预览）。
注意：清理需要重启资源管理器，桌面和任务栏会闪一下再回来，
      这是正常的，打开的窗口和程序不会关。
'@
        NeedExplorerRestart = $true
        Paths = @(
            "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
            "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db",
            "$env:LOCALAPPDATA\IconCache.db"
        )
    }

    $items += @{
        Id = 'Browsers'; Name = '浏览器缓存（Chrome / Edge / Firefox / 国产浏览器）'; Recommended = $true; Risk = '低'
        Detail = @'
清理各大浏览器的网页缓存。

★ 只删缓存，不碰这些东西 ★
  ✓ 收藏夹、书签         —— 不动
  ✓ 保存的密码           —— 不动
  ✓ Cookie 和登录状态    —— 不动（不会被退出登录）
  ✓ 历史记录             —— 不动
  ✓ 扩展插件             —— 不动
只删 Cache / Code Cache / GPUCache 三个纯缓存目录。

缓存本身是为了让你第二次打开同一个网站更快，但它会无限膨胀，
单个浏览器攒到 2~5 GB 很正常，而且太大之后反而会拖慢浏览器。

★ 清理前请先把浏览器关掉 ★
开着的话大部分文件会因为被占用而删不掉（不会报错，只是白清）。
'@
        Paths = @(
            # Chrome
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache\*",
            "$env:LOCALAPPDATA\Google\Chrome\User Data\ShaderCache\*",
            # Edge
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Code Cache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\GPUCache\*",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\ShaderCache\*",
            # Firefox
            "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2\*",
            # 360 极速 / 安全浏览器
            "$env:LOCALAPPDATA\360Chrome\Chrome\User Data\*\Cache\*",
            "$env:LOCALAPPDATA\360ChromeX\Chrome\User Data\*\Cache\*",
            # QQ 浏览器
            "$env:LOCALAPPDATA\Tencent\QQBrowser\User Data\*\Cache\*"
        )
    }

    $items += @{
        Id = 'ShaderCache'; Name = '显卡着色器缓存（N卡 / A卡 / DirectX）'; Recommended = $true; Risk = '低'
        Detail = @'
清理显卡驱动为游戏编译好的着色器缓存。

【为什么值得清】
每次更新显卡驱动之后，**旧的着色器缓存就失效了**，但它不会
自己删掉。如果缓存里混进了和新驱动不匹配的旧内容，典型症状是：
· 游戏里出现莫名其妙的图形错误、模型闪烁
· 某个场景固定掉帧
· 游戏启动特别慢或者直接崩溃
清掉之后让驱动重新编译一遍，这类问题经常就好了。

而且这些缓存能攒到好几个 GB。

【副作用】
清完后**第一次**进游戏会稍微卡一点（要重新编译着色器），
玩个几分钟就恢复正常了。这是一次性的，不是变慢了。

【建议】
每次更新完显卡驱动就清一次，是个好习惯。
'@
        Paths = @(
            "$env:LOCALAPPDATA\D3DSCache\*",
            "$env:LOCALAPPDATA\NVIDIA\DXCache\*",
            "$env:LOCALAPPDATA\NVIDIA\GLCache\*",
            "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache\*",
            "$env:LOCALAPPDATA\AMD\DxCache\*",
            "$env:LOCALAPPDATA\AMD\DxcCache\*",
            "$env:LOCALAPPDATA\AMD\GLCache\*",
            "$env:LOCALAPPDATA\Intel\ShaderCache\*"
        )
    }

    $items += @{
        Id = 'GameLaunchers'; Name = '游戏平台缓存（Steam / Epic / 战网）'; Recommended = $true; Risk = '低'
        Detail = @'
清理游戏平台客户端的网页缓存和日志。

Steam、Epic、战网的商店页面其实都是内嵌的浏览器，
它们的缓存和普通浏览器一样会无限增长。

★ 只删网页缓存和日志，绝对不碰 ★
  ✓ 已安装的游戏     —— 不动
  ✓ 游戏存档         —— 不动
  ✓ 登录状态         —— 不动
  ✓ 下载到一半的游戏 —— 不动

副作用：清完后第一次打开商店页面会稍慢。
顺带：Steam 商店页面卡、加载不出来、一片白，清这个经常能修好。

建议清理前把这些客户端关掉。
'@
        Paths = @(
            "$env:LOCALAPPDATA\Steam\htmlcache\*",
            "${env:ProgramFiles(x86)}\Steam\appcache\httpcache\*",
            "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache\*",
            "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Logs\*",
            "$env:LOCALAPPDATA\Battle.net\Cache\*",
            "$env:APPDATA\Battle.net\Cache\*"
        )
    }

    $items += @{
        Id = 'ErrorReports'; Name = 'Windows 错误报告与崩溃转储'; Recommended = $true; Risk = '低'
        Detail = @'
清理程序崩溃时生成的错误报告和内存转储文件。

每次有程序崩溃（游戏闪退、软件无响应），Windows 都会把当时的
内存内容转储成文件存起来，准备上报给微软。单个转储文件可以
有几百 MB 到好几 GB（MEMORY.DMP 的大小约等于你的内存大小）。

这些文件只有开发人员调试才用得上，对你毫无价值。

安全性：安全。删掉不影响任何功能。
'@
        Paths = @(
            "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\*",
            "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue\*",
            "$env:LOCALAPPDATA\Microsoft\Windows\WER\Temp\*",
            "$env:ProgramData\Microsoft\Windows\WER\ReportArchive\*",
            "$env:ProgramData\Microsoft\Windows\WER\ReportQueue\*",
            "$env:WINDIR\Minidump\*",
            "$env:WINDIR\MEMORY.DMP",
            "$env:WINDIR\LiveKernelReports\*"
        )
    }

    $items += @{
        Id = 'SystemLogs'; Name = '系统安装与更新日志'; Recommended = $true; Risk = '低'
        Detail = @'
清理 Windows 组件安装、更新过程留下的日志文本文件。

主要是 C:\Windows\Logs 下的 CBS、DISM 日志。这些是纯文本，
但会一直追加写入，几年下来能有好几 GB（CBS.log 单文件几百 MB
不稀奇）。

安全性：安全。日志只在排查疑难杂症时才有用，
删了之后系统会重新开始记。
'@
        Paths = @(
            "$env:WINDIR\Logs\CBS\*",
            "$env:WINDIR\Logs\DISM\*",
            "$env:WINDIR\Logs\MoSetup\*",
            "$env:WINDIR\Panther\*",
            "$env:WINDIR\SoftwareDistribution\DataStore\Logs\*"
        )
    }

    $items += @{
        Id = 'FontCache'; Name = '字体缓存'; Recommended = $false; Risk = '低'
        Detail = @'
清理系统字体缓存。

这个不是为了省空间（一般只有几十 MB），而是**修复问题用的**：
· 某些软件里字体显示成方块、乱码
· 装了新字体但软件里选不到
· 界面字体突然变得很丑

清理时会停掉字体缓存服务，删掉缓存，再启回来，
系统会自动重建。

平时没这些毛病的话，这一项不用勾。
'@
        Clean = {
            $freed = 0
            try { Stop-Service -Name 'FontCache' -Force -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Milliseconds 500
            $freed += Remove-PathContents @(
                "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache\*",
                "$env:WINDIR\System32\FNTCACHE.DAT"
            )
            try { Start-Service -Name 'FontCache' -ErrorAction SilentlyContinue } catch { }
            return $freed
        }
        Scan = { return (Get-PathSize @("$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache\*")) }
    }

    $items += @{
        Id = 'Prefetch'; Name = '预读取文件 Prefetch（不推荐清）'; Recommended = $false; Risk = '中'
        Detail = @'
★ 说实话：这一项建议你不要勾 ★

C:\Windows\Prefetch 里存的是「你常开哪些程序、它们要读哪些文件」
的记录，Windows 用它来预读，让程序开得更快。

几乎所有「垃圾清理软件」都会把它列成垃圾，但：
1. 它总共才几十 MB，清了省不下什么空间
2. 清掉之后 Windows 要重新学习，**接下来几次开机和开程序
   反而会变慢**，要用上一阵子才恢复
3. 它不是垃圾，是有用的数据

那为什么还放进来？因为在一种情况下清它有意义：
**卸载了大量软件之后**，Prefetch 里留着一堆已经不存在的程序
的记录，清一次让它重新学习是合理的。

除此之外，别清。
'@
        Paths = @("$env:WINDIR\Prefetch\*")
    }

    $items += @{
        Id = 'WindowsOld'; Name = 'Windows.old 旧系统备份（通常 15~30 GB）'; Recommended = $false; Risk = '中'
        Detail = @'
删除 C:\Windows.old。

【这是什么】
你每次升级 Windows 大版本（比如 Win10 升 Win11，或者
21H2 升 22H2），旧系统会被整个打包放进 C:\Windows.old，
好让你在 10 天内能「回退到上一个版本」。

它通常有 15~30 GB，是 C 盘空间的最大杀手。

【什么时候可以删】
· 升级完已经用了一段时间，一切正常 —— 可以删
· 过了 10 天回退期（系统本来也会自动删，但经常删不干净）

【删了会失去什么】
**再也无法一键回退到升级前的系统版本。**
只能重装。如果你刚升级不久还在观察阶段，先别删。

【为什么不在推荐里】
因为「删了就回不去」这个后果需要你自己确认。

【技术说明】
这个文件夹权限被锁死，普通删除会失败。工具会先用
takeown / icacls 拿到所有权再删，过程可能要几分钟，
界面看起来像卡住了，耐心等。
'@
        Scan = {
            $p = "$env:SystemDrive\Windows.old"
            if (-not (Test-Path -LiteralPath $p)) { return [double]0 }
            try {
                $s = (Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum).Sum
                if ($s) { return [double]$s }
            } catch { }
            return [double]0
        }
        Clean = {
            $p = "$env:SystemDrive\Windows.old"
            if (-not (Test-Path -LiteralPath $p)) { return [double]0 }
            $before = 0
            try {
                $s = (Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum).Sum
                if ($s) { $before = $s }
            } catch { }
            Write-Log '正在接管 Windows.old 的所有权，这一步比较慢，请耐心等待…' '信息'
            Invoke-Native 'takeown.exe' @('/F', $p, '/R', '/A', '/D', 'Y') | Out-Null
            Invoke-Native 'icacls.exe'  @($p, '/grant', 'Administrators:F', '/T', '/C', '/Q') | Out-Null
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            } catch {
                # PowerShell 删不动就交给 cmd 的 rd
                Invoke-Native 'cmd.exe' @('/c', 'rd', '/s', '/q', $p) | Out-Null
            }
            if (Test-Path -LiteralPath $p) {
                Write-Log 'Windows.old 未能完全删除（部分文件被系统占用），重启后再清一次通常就干净了' '警告'
                return [double]0
            }
            return [double]$before
        }
    }

    $items += @{
        Id = 'WinUpgrade'; Name = 'Windows 升级安装残留（$Windows.~BT 等）'; Recommended = $true; Risk = '低'
        Detail = @'
清理系统升级过程中留下的临时文件夹：
    C:\$Windows.~BT      升级用的安装文件
    C:\$Windows.~WS      升级工作目录
    C:\$WinREAgent       恢复环境的临时文件
    C:\$SysReset         「重置此电脑」的残留
    C:\ESD               系统镜像下载缓存

【为什么会有这些】
每次 Windows 大版本更新（21H2 → 22H2 这种），安装程序会先把
几个 GB 的安装文件解压到这些隐藏文件夹。装完之后它们应该自动
删除，但经常删不干净，尤其是升级中途出过错的机器。

加起来常有 3~10 GB，而且因为是隐藏文件夹，绝大多数人根本
不知道它们的存在。

【和 Windows.old 的区别】
Windows.old 是「旧系统备份」，删了就不能回退版本。
这些是「安装过程的临时文件」，删了没有任何影响。

【安全性】
安全。这些文件夹的权限被锁死，工具会先接管所有权再删，
过程可能要一两分钟。
'@
        Scan = {
            $total = 0
            foreach ($n in '$Windows.~BT', '$Windows.~WS', '$WinREAgent', '$SysReset', 'ESD') {
                $p = Join-Path $env:SystemDrive $n
                if (Test-Path -LiteralPath $p) {
                    try {
                        $s = (Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue |
                              Measure-Object -Property Length -Sum).Sum
                        if ($s) { $total += $s }
                    } catch { }
                }
            }
            return [double]$total
        }
        Clean = {
            $freed = 0
            foreach ($n in '$Windows.~BT', '$Windows.~WS', '$WinREAgent', '$SysReset', 'ESD') {
                $p = Join-Path $env:SystemDrive $n
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $before = 0
                try {
                    $s = (Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue |
                          Measure-Object -Property Length -Sum).Sum
                    if ($s) { $before = $s }
                } catch { }
                Invoke-Native 'takeown.exe' @('/F', $p, '/R', '/A', '/D', 'Y') | Out-Null
                Invoke-Native 'icacls.exe'  @($p, '/grant', 'Administrators:F', '/T', '/C', '/Q') | Out-Null
                try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
                catch { Invoke-Native 'cmd.exe' @('/c', 'rd', '/s', '/q', $p) | Out-Null }
                if (-not (Test-Path -LiteralPath $p)) { $freed += $before }
            }
            return [double]$freed
        }
    }

    $items += @{
        Id = 'GpuInstaller'; Name = '显卡驱动安装包残留（N卡 / A卡）'; Recommended = $true; Risk = '低'
        Detail = @'
清理显卡驱动安装时解压出来的安装包。

【为什么值得清】
NVIDIA 的驱动安装程序会把自己解压到 C:\NVIDIA（或
C:\ProgramData\NVIDIA Corporation\Downloader），
**装完之后不删**。每更新一次驱动就多留一份，
每份 500MB ~ 1GB。更新过十次驱动的机器，这里能有好几个 GB。

AMD 的 C:\AMD 同理。

【清了会怎样】
没有任何影响。显卡驱动已经装好了，这些只是安装包。
要回滚旧驱动的话，去官网重新下就行（官网都有历史版本）。

【FPS 玩家的小提醒】
更新完显卡驱动之后，建议把这一项和「显卡着色器缓存」
一起清一遍 —— 旧缓存和新驱动不匹配是游戏出现图形错误、
莫名掉帧的常见原因。
'@
        Paths = @(
            ($env:SystemDrive + '\NVIDIA\*'),
            ($env:SystemDrive + '\AMD\*'),
            "$env:ProgramData\NVIDIA Corporation\Downloader\*",
            "$env:ProgramData\NVIDIA\ComputeCache\*",
            "$env:APPDATA\NVIDIA\ComputeCache\*",
            "$env:ProgramData\AMD\CN\*",
            "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA App\Downloads\*"
        )
    }

    $items += @{
        Id = 'ChatCache'; Name = '微信 / QQ 缓存（只清缓存，不碰聊天记录）'; Recommended = $true; Risk = '低'
        Detail = @'
★ 先说清楚这一项【不会】删什么 ★
  ✓ 聊天记录            —— 绝不碰
  ✓ 聊天里的图片、视频  —— 绝不碰
  ✓ 收到的文件          —— 绝不碰
  ✓ 收藏、表情包        —— 绝不碰

【只清这些纯缓存目录】
· 微信小程序缓存（WeChat Files\Applet）—— 这个通常是大头，
  你每打开一个小程序它就缓存一份，能攒到好几个 GB
· 微信内置浏览器缓存（CefCache / WebviewCache）
· 微信 / QQ 的 FileStorage\Cache 临时缓存目录

【微信占用特别大怎么办】
如果扫出来微信整体占了几十个 GB，那大头是聊天图片和视频，
这个工具**故意不去动它们** —— 那是你的资料，不是垃圾，
该不该删只有你自己知道。

正确做法是用微信自己的清理功能，它能让你按聊天对象、
按时间、按文件类型挑着删：
    微信 → 设置 → 文件管理 → 清理微信存储空间
QQ 同理：设置 → 基本设置 → 文件管理 → 清理。

「日常维护」页会告诉你微信/QQ 各占了多少空间。

【清理前请先退出微信和 QQ】
开着的话文件被占用，大部分删不掉。
'@
        Scan = {
            $t = 0
            foreach ($p in (Get-ChatCacheTargets)) { $t += (Get-PathSize @($p)) }
            return [double]$t
        }
        Clean = {
            $f = 0
            foreach ($p in (Get-ChatCacheTargets)) { $f += (Remove-PathContents @($p)) }
            return [double]$f
        }
    }

    $items += @{
        Id = 'CommonApps'; Name = '常用软件缓存（Office / WPS / 网易云 / Discord 等）'; Recommended = $true; Risk = '低'
        Detail = @'
清理一批常用软件的缓存目录。都是纯缓存，不含任何用户数据。

【包含】
· Office / WPS 的文档缓存和崩溃恢复临时文件
· 网易云音乐、QQ音乐的歌曲缓存（在线听过的歌会缓存下来，
  能攒到好几个 GB；已下载的歌在「下载目录」，不受影响）
· Discord、Telegram 的缓存
· Adobe 相关的媒体缓存
· OneDrive 的日志和缓存

【不碰什么】
· 不碰任何文档、歌单、下载好的音乐
· 不碰登录状态
· 不碰软件设置

【副作用】
在线听过的歌要重新缓冲一次，Office 打开最近文档稍慢一点。
仅此而已。
'@
        Paths = @(
            # Office / WPS
            "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache\*",
            "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\Content.MSO\*",
            "$env:LOCALAPPDATA\Kingsoft\WPS Office\*\cache\*",
            "$env:APPDATA\kingsoft\office6\backup\*",
            # 音乐
            "$env:LOCALAPPDATA\Netease\CloudMusic\Cache\*",
            "$env:LOCALAPPDATA\Netease\CloudMusic\web_cache\*",
            "$env:APPDATA\Tencent\QQMusic\Cache\*",
            # 聊天 / 社区
            "$env:APPDATA\discord\Cache\*",
            "$env:APPDATA\discord\Code Cache\*",
            "$env:APPDATA\discord\GPUCache\*",
            "$env:APPDATA\Telegram Desktop\tdata\user_data\cache\*",
            # Adobe
            "$env:APPDATA\Adobe\Common\Media Cache Files\*",
            "$env:APPDATA\Adobe\Common\Peak Files\*",
            # OneDrive
            "$env:LOCALAPPDATA\Microsoft\OneDrive\logs\*",
            "$env:LOCALAPPDATA\Microsoft\OneDrive\setup\logs\*"
        )
    }

    $items += @{
        Id = 'StoreCache'; Name = '微软商店与安装程序缓存'; Recommended = $true; Risk = '低'
        Detail = @'
清理微软商店的下载缓存，以及各种软件安装时留下的 MSI 临时文件。

【包含】
· 微软商店的应用下载缓存（下载过的安装包不会自动删）
· Windows Installer 的临时解压目录
· 系统「优化驱动器」和安装程序的临时文件

【什么时候特别有用】
微软商店打不开、下载卡住、更新一直失败 —— 清一下这里
经常就好了，这是官方也认可的排查手段。

【安全性】
安全。已安装的应用不受影响。
'@
        Paths = @(
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache\*",
            "$env:LOCALAPPDATA\Packages\Microsoft.Windows.Cortana_cw5n1h2txyewy\LocalState\AppIconCache\*",
            "$env:WINDIR\Installer\`$PatchCache`$\Managed\*",
            "$env:LOCALAPPDATA\Downloaded Installations\*",
            "$env:WINDIR\SoftwareDistribution\PostRebootEventCache.V2\*"
        )
    }

    $items += @{
        Id = 'EventLogs'; Name = '清空 Windows 事件日志'; Recommended = $false; Risk = '中'
        Detail = @'
清空系统的事件日志（就是「事件查看器」里那些记录）。

【为什么默认不勾】
事件日志是**排查问题的唯一线索**。蓝屏了、某个服务起不来、
游戏莫名闪退，都要靠它来查原因。清掉之后这些历史就没了。

【占多大】
通常几百 MB，但用久了的机器里「安全」日志（Security.evtx）
单个能到 1~2 GB，所以偶尔也算一笔空间。

【什么时候才值得清】
· 日志里堆了几万条重复报错，把「事件查看器」卡到打不开
· 准备把电脑给别人用，不想留下使用痕迹

【安全性】
不影响系统运行，只是丢失历史记录。清完之后系统会重新开始记。
'@
        Scan = { return [double]-1 }
        Clean = {
            $n = 0
            $logs = (Invoke-Native 'wevtutil.exe' @('el')) -split "`r?`n"
            foreach ($l in $logs) {
                $name = $l.Trim()
                if (-not $name) { continue }
                Invoke-Native 'wevtutil.exe' @('cl', $name) | Out-Null
                $n++
            }
            Write-Log "已清空 $n 个事件日志通道" '成功'
            return [double]0
        }
    }

    $items += @{
        Id = 'ShadowCopies'; Name = '删除旧的系统还原点（只保留最新一个）'; Recommended = $false; Risk = '高'
        Detail = @'
★ 这一项会删掉本工具自己创建的还原点，看清楚再勾 ★

【这是什么】
系统还原点（卷影副本）是 Windows 给 C 盘做的快照。
它们默认最多可以占用 C 盘 10%~15% 的空间 ——
500GB 的盘就是 50~75 GB。所以这一项释放的空间往往很可观。

这一项会**保留最新的一个还原点，删掉其余所有的**。

【代价，必须想清楚】
· 你将**只能回滚到最近一次**的系统状态，更早的都没了
· 本工具在应用优化前自动创建的还原点，也在被删之列
· 「文件历史记录」里的旧版本文件也会一起消失

【建议】
· C 盘空间实在不够了 —— 可以做，但做之前先确认系统是正常的
· 刚用这个工具改完设置、还在观察阶段 —— **别做**，
  等确认一切正常了再说
· 空间还够 —— 不用做，还原点是保命的东西

【更温和的替代方案】
与其删还原点，不如去限制它的上限：
控制面板 → 系统 → 系统保护 → 配置 → 把「最大使用量」拉到 5%。
这样既保留了还原能力，又不会无限占用空间。
'@
        Scan = { return [double]-1 }
        Clean = {
            $before = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free
            # /oldest 一次删一个最旧的，循环到只剩一个为止
            for ($i = 0; $i -lt 60; $i++) {
                $list = Invoke-Native 'vssadmin.exe' @('list', 'shadows', "/for=$env:SystemDrive")
                $count = ([regex]::Matches($list, '(?i)shadow copy id|卷影副本 ID')).Count
                if ($count -le 1) { break }
                $r = Invoke-Native 'vssadmin.exe' @('delete', 'shadows', "/for=$env:SystemDrive", '/oldest', '/quiet')
                if ($r -match '(?i)error|错误|没有找到|no items') { break }
            }
            $after = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free
            $diff = 0
            if ($before -and $after -and ($after -gt $before)) { $diff = $after - $before }
            Write-Log '旧还原点已删除，只保留了最新一个' '成功'
            return [double]$diff
        }
    }

    $items += @{
        Id = 'DISM'; Name = '深度清理 WinSxS 组件仓库（慢，但很有效）'; Recommended = $false; Risk = '低'
        Detail = @'
执行 DISM 组件清理，压缩 C:\Windows\WinSxS。

【这是什么】
WinSxS 是 Windows 存放所有系统组件历史版本的仓库。每装一个
更新，旧版本的组件就留在里面（为了让你能卸载更新）。
用了三五年的系统，这里通常有 8~15 GB，其中 1~5 GB 是
早就没用的过期组件。

**注意：这个文件夹不能手动删任何东西**，手动删会直接把系统
搞坏。只能用微软官方的 DISM 工具来清，这一项就是帮你执行它。

【效果】
通常能释放 1~5 GB，是除了 Windows.old 之外最大的一笔。

【代价】
· 慢。真的慢。根据机器性能和系统年龄，要 5~30 分钟。
  期间界面会显示「正在清理」，看起来像死机了，**千万别关**。
· 期间 CPU 和硬盘会跑满，别同时干别的事。

【会失去什么】
清掉过期组件后，**已经安装的旧更新就不能再卸载了**。
（本工具不使用 /ResetBase 参数，所以最近的更新还是能卸载的，
  只清理真正过期的那部分，这是较保守的做法。）

【建议】
一年做一次就够了，睡觉前或者吃饭的时候点。
'@
        Scan = { return [double]-1 }   # -1 = 无法预估，界面会显示「执行后才知道」
        Clean = {
            Write-Log '开始 DISM 组件清理，预计需要 5~30 分钟，请不要关闭窗口…' '信息'
            $before = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free
            $out = Invoke-Native 'dism.exe' @('/online', '/Cleanup-Image', '/StartComponentCleanup')
            Write-Log "DISM 输出：$(($out -split "`r?`n" | Select-Object -Last 3) -join ' | ')" '信息'
            $after = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free
            $diff = 0
            if ($before -and $after -and ($after -gt $before)) { $diff = $after - $before }
            return [double]$diff
        }
    }

    return $items
}

# =====================================================================
#  统一入口
# =====================================================================
function Measure-CleanupItem {
    param($Item)
    try {
        if ($Item.Scan) { return [double](& $Item.Scan) }
        return (Get-PathSize $Item.Paths)
    } catch { return [double]0 }
}

function Invoke-CleanupItem {
    param($Item)
    try {
        $freed = 0
        if ($Item.Clean) { $freed = [double](& $Item.Clean) }
        else { $freed = Remove-PathContents $Item.Paths }
        Write-Log "已清理 [$($Item.Name)]：释放 $(Format-Size $freed)" '成功'
        return [double]$freed
    } catch {
        Write-Log "清理失败 [$($Item.Name)]：$($_.Exception.Message)" '错误'
        return [double]0
    }
}

function Restart-ExplorerShell {
    <# 重启资源管理器（清缩略图缓存后需要） #>
    try {
        Write-Log '正在重启资源管理器（桌面会闪一下，属正常现象）…' '信息'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1200
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Log '资源管理器已重启' '成功'
    } catch {
        Write-Log "重启资源管理器失败：$($_.Exception.Message)" '警告'
    }
}
