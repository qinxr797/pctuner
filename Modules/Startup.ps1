<#
=====================================================================
  Startup.ps1  ——  开机启动项管理
---------------------------------------------------------------------
  做的事和「任务管理器 → 启动」那一页一样，但多了两点：
    1. 把 4 个来源（当前用户注册表、系统注册表、32 位注册表、
       启动文件夹）合并在一起显示，任务管理器有时会漏。
    2. 对每一项给出「建议」—— 这个能不能关、关了会怎样。
       很多人不敢关就是因为看不懂那些程序名。

  禁用的方式和任务管理器**完全一样**：不是删掉启动项，而是在
  StartupApproved 里打一个「禁用」标记。所以随时可以再开回来，
  而且在任务管理器里也能看到一致的状态。
=====================================================================
#>

# 禁用 / 启用标记（和任务管理器写的是同一种数据）
$Script:APPROVE_ENABLED  = [byte[]](0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$Script:APPROVE_DISABLED = [byte[]](0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

# 启动项来源定义：Run 键 <-> 对应的 StartupApproved 键
$Script:STARTUP_SOURCES = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';                 Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Scope = '当前用户' }
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Scope = '所有用户' }
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Scope = '所有用户(32位)' }
)

function Get-StartupAdvice {
    <#
      根据程序名/路径给一句人话建议。
      返回 @{ Level = '可关' / '建议保留' / '看情况'; Text = '...' }
    #>
    param([string]$Name, [string]$Command)
    $s = "$Name $Command".ToLower()

    # --- 建议保留：关掉会真的出问题 ---
    if ($s -match 'sogou|qqpinyin|baidu.*input|microsoft.*ime|输入法|weasel|rime') {
        return @{ Level = '建议保留'; Text = '输入法。关掉后可能要手动启动才能打中文。' }
    }
    if ($s -match 'nvidia|nvcontainer|igfx|radeon|amdow|atieclxx|hkcmd|intel.*graphics') {
        return @{ Level = '建议保留'; Text = '显卡驱动相关。关掉可能导致游戏内的显卡设置（如 N 卡滤镜、帧数限制）失效、亮度调节失灵。' }
    }
    if ($s -match 'realtek|rtkaudio|nahimic|dolby|waves.*maxx|audiodg|sound') {
        return @{ Level = '建议保留'; Text = '声卡驱动 / 音效增强。关掉可能导致耳机麦克风插上不弹窗、音效设置失效。' }
    }
    if ($s -match 'synaptics|elan|touchpad|precision.*touchpad') {
        return @{ Level = '建议保留'; Text = '触控板驱动。笔记本关掉后多指手势会失效。' }
    }
    if ($s -match 'defender|msmpeng|securityhealth|360tray|360safe|huorong|火绒|kaspersky|avast|avp|mcafee|norton|bitdefender') {
        return @{ Level = '建议保留'; Text = '杀毒软件的实时防护。除非你打算换一个杀毒软件，否则别关。' }
    }
    if ($s -match 'onedrive') {
        return @{ Level = '看情况'; Text = '微软网盘。你用它同步文件就留着；不用的话可以关，它会占后台和网络。' }
    }

    # --- 可以关：典型的「没什么必要还占资源」 ---
    if ($s -match 'updat|upgrade|检查更新|autoupd|.*update.*\.exe') {
        return @{ Level = '可关'; Text = '软件自动更新检查器。关掉只是不会主动提示新版本，软件本身照常能用。' }
    }
    if ($s -match 'steam|epicgames|battle\.net|uplay|ubisoft|origin|eadesktop|gog') {
        return @{ Level = '可关'; Text = '游戏平台客户端。想玩的时候双击图标打开就行，没必要开机就挂着吃内存。' }
    }
    if ($s -match 'cloudmusic|netease|qqmusic|kugou|kuwo|iqiyi|youku|tencentvideo|bilibili|thunder|xunlei|迅雷') {
        return @{ Level = '可关'; Text = '娱乐类软件。要用的时候再打开，没必要开机自启。' }
    }
    if ($s -match '管家|卫士|加速|优化|大师|清理|guanjia|360|tencentdl|driverboost|drivergenius|驱动人生|驱动精灵') {
        return @{ Level = '可关'; Text = '国产「安全/优化」类工具。这类软件常驻吃资源、弹广告，本身就是拖慢机器的元凶之一。建议关掉，甚至直接卸载。' }
    }
    if ($s -match 'adobe|acrobat|creative.*cloud|ccxprocess|reader') {
        return @{ Level = '可关'; Text = 'Adobe 的后台服务。关掉不影响用 PDF 阅读器或 PS，只是启动时慢一两秒。' }
    }
    if ($s -match 'java|jusched|quicktime|itunes|ipod') {
        return @{ Level = '可关'; Text = '基本是历史遗留的更新检查器，关掉没有影响。' }
    }
    if ($s -match 'wechat|微信|wemeet|dingtalk|钉钉|feishu|飞书') {
        return @{ Level = '看情况'; Text = '通讯软件。你需要随时收消息就留着，否则可以关，用的时候再开。' }
    }
    if ($s -match '\bqq\b|tencent.*qq') {
        return @{ Level = '看情况'; Text = '通讯软件。同上，看你需不需要随时在线。' }
    }
    if ($s -match 'printer|scan|epson|canon|hp.*|brother|佳能|爱普生') {
        return @{ Level = '可关'; Text = '打印机/扫描仪的厂商管理程序。关掉后打印功能照常，只是少了厂商那个花哨的面板。' }
    }

    # --- 外设驱动 / 灯效软件 ---
    if ($s -match 'razer|logitech|ghub|lghub|corsair|icue|steelseries|wooting|vgc|armoury|aura|msi.*center|omen') {
        return @{ Level = '看情况'; Text = '外设厂商的驱动/灯效软件。你靠它做按键映射、DPI 切换、宏或灯效的话就留着；只是插着用不调设置的话可以关。' }
    }
    # --- 浏览器预加载 ---
    if ($s -match 'msedge.*win-session-start|chrome.*startup|browser.*preload') {
        return @{ Level = '可关'; Text = '浏览器的开机预加载，目的是让你第一次打开浏览器快一两秒。代价是一直占着内存。关掉没有副作用。' }
    }
    # --- 电源/性能锁定类小工具 ---
    if ($s -match 'lockpowerplan|powerplan|throttlestop|quickcpu') {
        return @{ Level = '看情况'; Text = '电源方案锁定/调频类小工具。如果是你自己装来锁高性能模式的，留着；没印象的话关掉观察一下。' }
    }
    # --- 自己写的脚本（常见于开发机）---
    if ($s -match '\.ps1|\.bat|\.cmd|\.vbs') {
        return @{ Level = '看情况'; Text = '这是一个脚本，不是普通软件。多半是你自己（或某个工具）放进来的。认得就留着，不认得建议点开「弹窗排查」页看看它到底在干什么。' }
    }

    # 兜底：保持一句话。
    # （这段文字会在每一个认不出来的条目下面重复出现，写长了整页看起来像复读机，
    #   所以详细的判断方法统一放在页面顶部说明里讲一次就够。）
    return @{ Level = '看情况'; Text = '认不出这个程序。认得就留着，完全没印象可以先关掉试一天。' }
}

function Test-StartupEnabled {
    param([string]$ApprovedPath, [string]$Key)
    $v = Get-RegValue -Path $ApprovedPath -Name $Key
    if ($null -eq $v) { return $true }          # 没有记录 = 启用中
    try { return (([byte[]]$v)[0] -band 1) -eq 0 } catch { return $true }
}

function Get-StartupItems {
    <# 汇总所有开机启动项 #>
    $list = New-Object System.Collections.ArrayList

    # --- 注册表 Run 键 ---
    foreach ($src in $Script:STARTUP_SOURCES) {
        if (-not (Test-Path -LiteralPath $src.Run)) { continue }
        $item = Get-Item -LiteralPath $src.Run -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($name in $item.GetValueNames()) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $cmd = "$($item.GetValue($name))"
            $adv = Get-StartupAdvice -Name $name -Command $cmd
            [void]$list.Add([PSCustomObject]@{
                    Name         = $name
                    Command      = $cmd
                    Scope        = $src.Scope
                    Kind         = '注册表'
                    RunPath      = $src.Run
                    ApprovedPath = $src.Approved
                    ApprovedKey  = $name
                    Enabled      = (Test-StartupEnabled -ApprovedPath $src.Approved -Key $name)
                    AdviceLevel  = $adv.Level
                    AdviceText   = $adv.Text
                })
        }
    }

    # --- 启动文件夹 ---
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = '当前用户' }
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = '所有用户' }
    )
    foreach ($f in $folders) {
        if ([string]::IsNullOrWhiteSpace($f.Path) -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $adv = Get-StartupAdvice -Name $file.BaseName -Command $file.FullName
            [void]$list.Add([PSCustomObject]@{
                    Name         = $file.BaseName
                    Command      = $file.FullName
                    Scope        = $f.Scope
                    Kind         = '启动文件夹'
                    RunPath      = $f.Path
                    ApprovedPath = $f.Approved
                    ApprovedKey  = $file.Name
                    Enabled      = (Test-StartupEnabled -ApprovedPath $f.Approved -Key $file.Name)
                    AdviceLevel  = $adv.Level
                    AdviceText   = $adv.Text
                })
        }
    }

    return ($list | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)
}

function Set-StartupItemEnabled {
    <#
      启用 / 禁用一个启动项。
      写的是和任务管理器同一份数据，所以两边状态始终一致，
      而且**不会删除任何文件或注册表项**，随时可以改回来。
    #>
    param($Item, [bool]$Enabled)
    try {
        $bytes = if ($Enabled) { $Script:APPROVE_ENABLED } else { $Script:APPROVE_DISABLED }
        if (-not (Test-Path -LiteralPath $Item.ApprovedPath)) {
            New-Item -Path $Item.ApprovedPath -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $Item.ApprovedPath -Name $Item.ApprovedKey -PropertyType Binary -Value $bytes -Force | Out-Null
        Write-Log ("启动项「{0}」已{1}" -f $Item.Name, $(if ($Enabled) { '启用' } else { '禁用' })) '成功'
        return $true
    } catch {
        Write-Log "修改启动项 [$($Item.Name)] 失败：$($_.Exception.Message)" '错误'
        return $false
    }
}
