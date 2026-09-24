<#
=====================================================================
  Inspect.ps1  ——  弹窗排查 / 可疑项检测
---------------------------------------------------------------------
  专治这个症状：
      「黑色的框突然弹出来，里面什么都没有，一闪就没了，
        有时候一下子弹四五个」

  ★ 那是什么东西 ★
    那是**控制台窗口**（cmd.exe / powershell.exe / cscript.exe）。
    有程序在后台调用了命令行工具，但没有把窗口隐藏起来，
    于是你就看到一个黑框一闪而过。框里没东西是因为它执行得太快。

  ★ 本工具的核心判断：「这一项会不会弹黑框」★
    一个东西要弹出黑框，必须【同时】满足三个条件：
        1. 它跑的是控制台程序（cmd / powershell / cscript / 批处理）
        2. 它运行在你的登录会话里（不是系统后台会话）
        3. 它没有加隐藏窗口参数（-WindowStyle Hidden 之类）
    三个条件缺一个就不会弹。工具会逐条判断并直接标出
    「⚡ 会弹黑框」，让你一眼看到该抓谁。

    顺带说明一个反直觉的点：命令行里写着 Hidden 的那些
    **恰恰是不会弹框的**（人家已经规规矩矩把窗口藏起来了）。
    早期版本把 "hidden" 当成可疑特征，结果把 Razer 驱动、
    正经的开机脚本、甚至本工具自己的清理任务全判成了高危，
    属于典型的误报。现在只有「隐藏窗口 + 编码命令」这种
    组合拳才算可疑。

  ★ 这个功能不做什么 ★
    它**不是杀毒软件**。它找的是「持久化驻留点」和「会弹黑框的东西」，
    不做病毒特征比对。如果扫出「高危」条目，正确做法是
    用 Windows Defender 或火绒做一次全盘扫描，而不是只把它禁用。

  ★ 安全原则 ★
    所有操作都是【禁用】而不是【删除】，随时可以再启用。
=====================================================================
#>

# ---------------------------------------------------------------------
#  特征表
# ---------------------------------------------------------------------

# 会在屏幕上弹出黑框的控制台程序
# 注意 wscript.exe 不在这里：它是「无窗口」版的脚本宿主，不弹框；
#      cscript.exe 才是控制台版的，会弹框。这两个只差一个字母，别搞混。
$Script:CONSOLE_HOSTS = @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'cscript.exe', 'schtasks.exe', 'wmic.exe', 'netsh.exe', 'reg.exe')

# 批处理脚本也会弹框
$Script:SCRIPT_EXT = @('.bat', '.cmd')

# 「窗口已经被藏起来了」的写法 —— 命中这些说明它不会弹框
$Script:HIDDEN_MARKERS = @(
    '(?i)(-|--|/)w(indowstyle)?\s+h(idden)?\b',
    '(?i)windowstyle\s*=\s*hidden',
    '(?i)-force-hidden|--launch-force-hidden|-hidden\b|=hidden\b',
    '(?i)\bstart\s+/(min|b)\b'
)

# 真正值得警惕的命令行特征。
# ★ 全部用带边界的正则，绝不用「包含子串」★
#   之前用 Contains('iex') 的后果是：msiexec.exe 里含有 iex，
#   于是 Windows Installer 这个系统核心服务被判成了高危。
$Script:BAD_PATTERNS = @(
    @{ Rx = '(?i)(^|[\s"])[-/]e(nc|c|ncodedcommand)?\s+[A-Za-z0-9+/=]{30,}'
       Why = 'PowerShell 编码命令（-enc 后面跟一长串 Base64）—— 把真正要执行的代码藏起来，是脚本木马的招牌手法'
       Level = '高危' }
    @{ Rx = '(?i)frombase64string'
       Why = '运行时把 Base64 解码成代码再执行 —— 藏代码的典型写法'
       Level = '高危' }
    @{ Rx = '(?i)(^|[\s;(''"|])(iex|invoke-expression)([\s(]|$)'
       Why = '把一段文本当命令直接执行（IEX）—— 配合下载就是「下载即执行」'
       Level = '高危' }
    @{ Rx = '(?i)downloadstring|downloadfile|net\.webclient|start-bitstransfer'
       Why = '会从网络下载内容 —— 计划任务里出现这个要非常小心'
       Level = '高危' }
    @{ Rx = '(?i)(^|[\s"\\])(mshta|regsvr32|certutil|bitsadmin)\.exe'
       Why = '调用了 mshta / regsvr32 / certutil / bitsadmin 这类系统自带工具 —— 它们常被恶意程序借用来绕过安全拦截'
       Level = '可疑' }
)

# 可执行文件待在这些地方 = 高度可疑（正经软件不会装在这儿）
$Script:BAD_PATHS = @(
    '\appdata\local\temp\', '\windows\temp\', '\users\public\',
    '\downloads\', '\$recycle.bin\', '\programdata\temp\'
)

# 本工具自己建的东西，别把自己判成病毒
$Script:SELF_MARKERS = @('PCTuner', 'PCTuner.ps1', '每周自动清理')

# 已知的「正经但确实会弹黑框 / 白占资源」的东西
$Script:KNOWN_NOISY = @(
    @{ Match = 'OfficeBackgroundTaskHandler';     Who = 'Microsoft Office 后台任务'; Note = '★ 这是「每隔几分钟闪一个黑框」最经典的元凶。它只做 Office 的后台登记，关掉对 Office 使用毫无影响。如果你的弹窗有规律，先怀疑它。' }
    @{ Match = 'user_feed_synchronization';        Who = 'Windows RSS 源同步';        Note = '老 Windows 留下的 RSS 订阅同步任务，现在几乎没人用，但它会规律性地弹黑框。可以关。' }
    @{ Match = 'GoogleUpdateTask';                 Who = 'Chrome 浏览器更新检查';      Note = '关掉后 Chrome 不再自动检查更新，需要手动在「关于 Chrome」里更新。' }
    @{ Match = 'MicrosoftEdgeUpdateTask';          Who = 'Edge 浏览器更新检查';        Note = '同上，关掉后需要手动更新 Edge。' }
    @{ Match = 'Adobe Acrobat Update|AdobeGCInvoker'; Who = 'Adobe 更新检查';          Note = 'Adobe 的更新检查器，弹黑框的老熟人。关掉不影响用 PDF 阅读器。' }
    @{ Match = 'NvTmRep|NvTmMon|NvProfileUpdater|NVIDIA.*Telemetry'; Who = 'NVIDIA 遥测 / 配置更新'; Note = 'NVIDIA 的使用数据上报和游戏配置更新。关掉不影响显卡驱动和游戏性能，只会让 GeForce Experience 的自动优化失效。' }
    @{ Match = 'CCleaner';                         Who = 'CCleaner 更新检查';          Note = '可以关。' }
    @{ Match = '360|QQPCMgr|Tencent.*Mgr|电脑管家|驱动人生|DriverTalent|DriverGenius|驱动精灵'; Who = '国产「管家 / 优化 / 驱动」类软件'; Note = '这类软件常驻 + 定时弹窗 + 推广，本身就是拖慢机器的元凶之一。强烈建议关掉，甚至直接卸载。' }
    @{ Match = 'Dell|HP.*Update|Lenovo|ASUS.*Update|MyASUS|Alienware|Razer.*Update'; Who = '品牌机 / 外设厂商的更新工具'; Note = '关掉不影响硬件功能，只是不再主动提示驱动更新。' }
    @{ Match = 'Compatibility Appraiser|ProgramDataUpdater|Microsoft Compatibility|Inventory|DiskDiagnosticDataCollector'; Who = 'Windows 兼容性遥测'; Note = '收集兼容性数据上报微软，会定期占用磁盘和 CPU。关掉对系统没影响。' }
    @{ Match = 'WpsUpdate|WPS.*Task|kingsoft|金山'; Who = 'WPS 更新检查';              Note = '可以关，需要时手动更新即可。' }
)

# ---------------------------------------------------------------------
#  小工具
# ---------------------------------------------------------------------
function Get-ExeName {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return ([System.IO.Path]::GetFileName($Path.Trim('"', ' '))).ToLower() } catch { return '' }
}

function Test-PathMissing {
    <# 判断命令行指向的程序是不是已经不存在了（卸载残留） #>
    param([string]$Exe)
    if ([string]::IsNullOrWhiteSpace($Exe)) { return $false }
    $p = $Exe.Trim('"', ' ')
    if ($p -notmatch '^[A-Za-z]:\\') { return $false }   # 只判断写了完整路径的
    $p = [Environment]::ExpandEnvironmentVariables($p)
    return (-not (Test-Path -LiteralPath $p))
}

function Test-WindowHidden {
    <# 命令行里有没有「把窗口藏起来」的写法 #>
    param([string]$Cmd)
    foreach ($m in $Script:HIDDEN_MARKERS) { if ($Cmd -match $m) { return $true } }
    return $false
}

$Script:PeCache = @{}
function Test-ConsoleSubsystem {
    <#
      读 exe 的 PE 头，判断它是不是「控制台程序」。

      为什么必须做这一步：
        早期版本只认 cmd / powershell / cscript 这几个已知的命令行宿主，
        结果漏掉了一大类元凶 —— 自己编译成控制台程序的 exe。
        大量国产软件的更新检查器（xxxUpdate.exe、xxxCheck.exe）就是这样，
        双击不会有界面，但一运行就闪一个黑框。光看文件名根本认不出来。

      原理：PE 可选头里的 Subsystem 字段，3 = 控制台程序，2 = 窗口程序。
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim('"', ' '))
    if ($p -notmatch '(?i)\.exe$') { return $false }
    if ($p -notmatch '^[A-Za-z]:\\') {
        $c = Get-Command $p -ErrorAction SilentlyContinue
        if (-not $c) { return $false }
        $p = $c.Source
    }
    if ($Script:PeCache.ContainsKey($p)) { return $Script:PeCache[$p] }

    $result = $false
    $fs = $null
    try {
        if (Test-Path -LiteralPath $p) {
            $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Position = 0x3C
            $peOff = $br.ReadInt32()
            if ($peOff -gt 0 -and $peOff -lt ($fs.Length - 0x60)) {
                $fs.Position = $peOff
                if ($br.ReadUInt32() -eq 0x00004550) {          # "PE\0\0"
                    # 可选头从 peOff+0x18 开始，Subsystem 在可选头内偏移 0x44
                    # （PE32 和 PE32+ 这个偏移是一样的）
                    $fs.Position = $peOff + 0x18 + 0x44
                    $result = ($br.ReadUInt16() -eq 3)          # 3 = IMAGE_SUBSYSTEM_WINDOWS_CUI
                }
            }
        }
    } catch { } finally { if ($fs) { $fs.Dispose() } }

    $Script:PeCache[$p] = $result
    return $result
}

function Test-ConsoleCommand {
    <# 这条命令会不会开出一个控制台窗口 #>
    param([string]$Exe, [string]$Cmd)
    $n = Get-ExeName $Exe
    if ($Script:CONSOLE_HOSTS -contains $n) { return $true }
    foreach ($e in $Script:SCRIPT_EXT) { if ($Cmd -match [regex]::Escape($e) + '(\s|"|$)') { return $true } }
    if (Test-ConsoleSubsystem $Exe) { return $true }
    return $false
}

function Test-IsSelf {
    param([string]$Text)
    foreach ($m in $Script:SELF_MARKERS) { if ($Text -like "*$m*") { return $true } }
    return $false
}

function Get-BadPatternHits {
    <# 返回命中的可疑特征（正则匹配，不是子串包含） #>
    param([string]$Cmd)
    $hits = @()
    foreach ($p in $Script:BAD_PATTERNS) {
        if ($Cmd -match $p.Rx) { $hits += $p }
    }
    return $hits
}

function New-Finding {
    param($Kind, $Name, $Command, $Level, $Reasons, $Advice, $Target, $Enabled = $true, $Extra = '', [bool]$Flash = $false)

    # 排序权重：会弹黑框的排最前（那正是用户要找的东西），其次按危险程度
    $levelRank = switch ($Level) { '高危' { 0 } '可疑' { 1 } '无用' { 2 } '已知打扰' { 3 } default { 4 } }
    $flashRank = 10
    if ($Flash) { $flashRank = 0 }

    return [PSCustomObject]@{
        Kind    = $Kind
        Name    = $Name
        Command = $Command
        Level   = $Level        # 高危 / 可疑 / 已知打扰 / 无用
        Reasons = @($Reasons)
        Advice  = $Advice
        Target  = $Target
        Enabled = $Enabled
        Extra   = $Extra
        Flash   = $Flash        # 会不会弹黑框 —— 这是本页的重点
        Score   = $flashRank + $levelRank
    }
}

# ---------------------------------------------------------------------
#  1. 计划任务（弹黑框的头号来源）
# ---------------------------------------------------------------------
function Get-TaskFindings {
    $out = @()
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { return $out }

    foreach ($t in $tasks) {
        $path = "$($t.TaskPath)$($t.TaskName)"

        $actions = @($t.Actions | Where-Object { $_.Execute })
        if ($actions.Count -eq 0) { continue }

        $cmdLines = @()
        foreach ($a in $actions) { $cmdLines += (("{0} {1}" -f $a.Execute, $a.Arguments).Trim()) }
        $cmd = $cmdLines -join '  ||  '

        # 本工具自己建的任务，跳过
        if ((Test-IsSelf $path) -or (Test-IsSelf $cmd)) { continue }

        $reasons = @()
        $level = $null

        # ---------- 会不会弹黑框 ----------
        # 三个条件都满足才会弹：控制台程序 + 跑在你的登录会话里 + 没隐藏窗口
        $logon = "$($t.Principal.LogonType)"
        $inSession = ($logon -like 'Interactive*')
        $isConsole = $false
        foreach ($a in $actions) { if (Test-ConsoleCommand -Exe $a.Execute -Cmd (("{0} {1}" -f $a.Execute, $a.Arguments))) { $isConsole = $true } }
        $hidden = Test-WindowHidden $cmd
        $flash = ($isConsole -and $inSession -and -not $hidden)

        # ---------- 触发频率 ----------
        $repeat = $null
        try {
            foreach ($tr in @($t.Triggers)) {
                if ($tr.Repetition -and $tr.Repetition.Interval) {
                    $iv = "$($tr.Repetition.Interval)"
                    if ($iv -match 'PT(\d+)M') { $repeat = [int]$Matches[1] }
                    elseif ($iv -match 'PT(\d+)H') { $repeat = [int]$Matches[1] * 60 }
                }
            }
        } catch { }

        $isMicrosoft = $t.TaskPath -like '\Microsoft\*'

        # ---------- 特征一：命令行里的可疑写法 ----------
        foreach ($h in (Get-BadPatternHits $cmd)) {
            $reasons += $h.Why
            if ($h.Level -eq '高危' -or -not $level) { $level = $h.Level }
        }

        # ---------- 特征二：程序待在临时目录 ----------
        $cmdLower = $cmd.ToLower()
        foreach ($p in $Script:BAD_PATHS) {
            if ($cmdLower.Contains($p)) {
                $reasons += "程序位于 $($p.Trim('\')) 目录 —— 正经软件不会把自己装在临时文件夹里"
                $level = '高危'
                break
            }
        }

        # ---------- 特征三：已知的正经打扰源 ----------
        if ($level -ne '高危') {
            foreach ($k in $Script:KNOWN_NOISY) {
                if ($path -match $k.Match -or $cmd -match $k.Match) {
                    $reasons += "已确认身份：$($k.Who)"
                    $reasons += $k.Note
                    if (-not $level) { $level = '已知打扰' }
                    break
                }
            }
        }

        # ---------- 特征四：指向的程序已不存在 ----------
        if (-not $level) {
            $missing = $false
            foreach ($a in $actions) { if (Test-PathMissing $a.Execute) { $missing = $true } }
            if ($missing) {
                $reasons += '这个任务要运行的程序已经不存在了 —— 多半是某个软件卸载后没清干净的残留，留着只会白白执行失败'
                $level = '无用'
            }
        }

        # ---------- 特征五：会弹黑框 ----------
        if ($flash) {
            $reasons = @('⚡ 这个任务运行时【会弹出黑框】：它调用了控制台程序、跑在你的登录会话里、而且没有隐藏窗口 —— 三个条件都满足。') + $reasons
            if (-not $level) { $level = '可疑' }
        }

        # ---------- 特征六：跑得特别勤 ----------
        if ($repeat -and $repeat -le 30 -and -not $isMicrosoft) {
            $reasons += "每 $repeat 分钟就跑一次 —— 频率这么高，规律性的弹窗很可能就是它"
            if (-not $level) { $level = '可疑' }
        }

        if (-not $level) { continue }

        # 上次运行时间：直接对应「我刚才看到的那个框」
        $lastRun = $null
        try { $lastRun = (Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop).LastRunTime } catch { }
        $extra = ''
        if ($lastRun -and $lastRun.Year -gt 2000) {
            $ago = (Get-Date) - $lastRun
            $extra = "上次运行：{0}（{1}）" -f $lastRun.ToString('MM-dd HH:mm:ss'), $(
                if ($ago.TotalMinutes -lt 60) { "{0} 分钟前" -f [int]$ago.TotalMinutes }
                elseif ($ago.TotalHours -lt 48) { "{0} 小时前" -f [int]$ago.TotalHours }
                else { "{0} 天前" -f [int]$ago.TotalDays })
        }
        if ($repeat) { $extra += "   ·   每 $repeat 分钟重复一次" }
        if ($hidden -and $isConsole) { $extra += "   ·   已隐藏窗口，不会弹框" }

        $advice = switch ($level) {
            '高危'     { '建议：先别急着只禁用它。用 Windows Defender 做一次「完全扫描」，或者装火绒扫一遍。确认干净之后再决定留不留。' }
            '已知打扰' { '可以放心禁用。禁用不等于卸载，软件本身照常能用，只是不再自动检查更新。' }
            '无用'     { '可以放心禁用。它指向的程序都没了，留着没有任何意义。' }
            default    { '认识这个软件、也需要它自动更新，就留着；不认识或者不需要，可以先禁用观察几天，有问题随时勾回来。' }
        }

        $out += New-Finding -Kind '计划任务' -Name $path -Command $cmd -Level $level `
            -Reasons $reasons -Advice $advice -Enabled ($t.State -ne 'Disabled') -Extra $extra -Flash $flash `
            -Target @{ Type = 'Task'; TaskPath = $t.TaskPath; TaskName = $t.TaskName }
    }
    return $out
}

# ---------------------------------------------------------------------
#  2. WMI 事件订阅（最隐蔽的一种驻留）
# ---------------------------------------------------------------------
function Get-WmiFindings {
    $out = @()
    $builtin = 'BVTFilter|SCM Event Log|TSLogonEvents|RAevent|NTEventLogConsumer|WSCEAA|DellCommand'
    try {
        foreach ($c in @(Get-CimInstance -Namespace 'root\subscription' -ClassName '__EventConsumer' -ErrorAction Stop)) {
            $name = "$($c.Name)"
            if ($name -match $builtin) { continue }
            $payload = ''
            if ($c.CommandLineTemplate) { $payload = "$($c.CommandLineTemplate)" }
            elseif ($c.ScriptText) { $payload = '脚本内容：' + ("$($c.ScriptText)" -replace '\s+', ' ') }
            if ($payload.Length -gt 400) { $payload = $payload.Substring(0, 400) + ' …' }

            $out += New-Finding -Kind 'WMI 事件订阅' -Name $name -Command $payload -Level '高危' `
                -Reasons @(
                'WMI 事件订阅是一种「无文件驻留」：硬盘上不需要放病毒文件，只靠系统自带的 WMI 机制就能在特定条件下自动执行命令。',
                '普通用户的电脑上几乎不会有第三方的 WMI 订阅，杀毒软件也经常漏掉这一块。',
                '它可以被设成每隔几秒触发一次 —— 如果你看到的是成批出现的黑框，这里是重点怀疑对象。'
            ) `
                -Advice '强烈建议：立刻做一次「Microsoft Defender 脱机扫描」（设置 → 隐私和安全性 → Windows 安全中心 → 病毒和威胁防护 → 扫描选项）。这一项可以先删掉切断执行，但清干净还是要靠杀毒软件。' `
                -Target @{ Type = 'WmiConsumer'; Name = $name }
        }
    } catch { }
    return $out
}

# ---------------------------------------------------------------------
#  3. 冷门自启位置
# ---------------------------------------------------------------------
function Get-AutorunFindings {
    $out = @()

    # --- Winlogon ---
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shell = Get-RegValue -Path $wl -Name 'Shell'
    if ($shell -and "$shell".Trim().ToLower() -ne 'explorer.exe') {
        $out += New-Finding -Kind '系统登录项' -Name 'Winlogon\Shell 被改过' -Command "$shell" -Level '高危' `
            -Reasons @('这个值决定你登录后启动什么程序当「桌面」，正常情况下只能是 explorer.exe。',
            '被改成别的东西，是病毒和流氓软件的经典驻留手法。') `
            -Advice '正常值应该是 explorer.exe。建议先杀毒，再手动改回来。这一项工具不会自动改 —— 改错了会登录不进桌面。' -Target @{ Type = 'None' }
    }
    $userinit = Get-RegValue -Path $wl -Name 'Userinit'
    if ($userinit -and "$userinit" -notmatch '(?i)^[a-z]:\\windows\\system32\\userinit\.exe,?\s*$') {
        $out += New-Finding -Kind '系统登录项' -Name 'Winlogon\Userinit 被追加了东西' -Command "$userinit" -Level '高危' `
            -Reasons @('正常值只有 C:\Windows\system32\userinit.exe，后面被追加了别的程序，说明有东西想跟着登录一起启动。') `
            -Advice '建议先杀毒。这一项工具不会自动改 —— 改错了会登录不进桌面。' -Target @{ Type = 'None' }
    }

    # --- AppInit_DLLs ---
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows') {
        $v = Get-RegValue -Path $p -Name 'AppInit_DLLs'
        if ($v -and "$v".Trim()) {
            $out += New-Finding -Kind '全局注入' -Name 'AppInit_DLLs 不为空' -Command "$v" -Level '高危' `
                -Reasons @('这里填的 DLL 会被强行注入到几乎每一个运行的程序里，是非常强的驻留手段。',
                '干净的系统这一项应该是空的。') `
                -Advice '建议杀毒。极少数老输入法和安全软件会用它，但绝大多数情况下这是坏东西。' -Target @{ Type = 'None' }
        }
    }

    # --- 映像劫持（IFEO Debugger）---
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    if (Test-Path -LiteralPath $ifeo) {
        foreach ($k in (Get-ChildItem -LiteralPath $ifeo -ErrorAction SilentlyContinue)) {
            $dbg = Get-RegValue -Path $k.PSPath -Name 'Debugger'
            if (-not $dbg -or -not "$dbg".Trim()) { continue }

            # taskkill / systray 这类是「优化脚本」用来禁用某个系统程序的常见手法，
            # 不是恶意劫持。分开说明，免得吓人。
            if ("$dbg" -match '(?i)taskkill\.exe|systray\.exe|rundll32\.exe\s*$') {
                $out += New-Finding -Kind '映像劫持' -Name ("{0} 被禁用（优化脚本的常见手法）" -f $k.PSChildName) -Command "$dbg" -Level '已知打扰' `
                    -Reasons @("系统每次想启动 $($k.PSChildName) 时，会被导向 $dbg，等于这个程序被彻底禁用了。",
                    "把 Debugger 指向 taskkill.exe 是各种「关闭 Windows 遥测」的优化脚本最常用的手段，通常不是病毒干的。",
                    "$($k.PSChildName) 如果是遥测相关的程序（DeviceCensus、CompatTelRunner 等），那这就是有人故意关掉它，属于正常操作。") `
                    -Advice '如果你或者装过的某个优化工具做过「关闭 Windows 遥测」，那这就是它留下的，可以不管。如果完全没印象，建议杀毒确认一下。' `
                    -Target @{ Type = 'None' }
            } else {
                $out += New-Finding -Kind '映像劫持' -Name ("{0} 被劫持" -f $k.PSChildName) -Command "$dbg" -Level '高危' `
                    -Reasons @("你每次启动 $($k.PSChildName) 时，系统会改为启动「$dbg」。",
                    '这叫映像劫持，典型用途是「你一打开杀毒软件，它就把你导向别的程序」。') `
                    -Advice '强烈建议杀毒。' -Target @{ Type = 'None' }
            }
        }
    }

    # --- Run / RunOnce ---
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($rk in $runKeys) {
        if (-not (Test-Path -LiteralPath $rk)) { continue }
        $item = Get-Item -LiteralPath $rk -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($n in $item.GetValueNames()) {
            if (-not $n) { continue }
            $v = "$($item.GetValue($n))"
            if ((Test-IsSelf $n) -or (Test-IsSelf $v)) { continue }

            $reasons = @(); $level = $null
            $exe = if ($v -match '^"([^"]+)"') { $Matches[1] } else { ($v -split ' ')[0] }
            $hidden = Test-WindowHidden $v
            $isConsole = Test-ConsoleCommand -Exe $exe -Cmd $v
            $flash = ($isConsole -and -not $hidden)     # 自启项本来就跑在登录会话里

            foreach ($h in (Get-BadPatternHits $v)) {
                $reasons += $h.Why
                if ($h.Level -eq '高危' -or -not $level) { $level = $h.Level }
            }
            if ($level -ne '高危') {
                $vl = $v.ToLower()
                foreach ($p in $Script:BAD_PATHS) { if ($vl.Contains($p)) { $reasons += '程序位于临时目录，正经软件不会装在那里'; $level = '高危'; break } }
            }
            if (-not $level -and (Test-PathMissing $exe)) {
                $reasons += '指向的程序已经不存在了（卸载残留），每次开机都会白白尝试启动一次'
                $level = '无用'
            }
            if ($flash) {
                $reasons = @('⚡ 这一项开机时【会弹出黑框】：它启动的是控制台程序，而且没有加隐藏窗口参数。') + $reasons
                if (-not $level) { $level = '可疑' }
            }
            if (-not $level) { continue }

            $extra = '位置：' + $rk.Replace('HKCU:\', 'HKEY_CURRENT_USER\').Replace('HKLM:\', 'HKEY_LOCAL_MACHINE\')
            if ($hidden -and $isConsole) { $extra += '   ·   已隐藏窗口，不会弹框' }

            $out += New-Finding -Kind '开机自启' -Name $n -Command $v -Level $level -Reasons $reasons -Flash $flash `
                -Advice $(if ($level -eq '高危') { '建议先杀毒再处理。' } else { '不需要的话可以直接在这里禁用，原值会被备份，随时能恢复。' }) `
                -Target @{ Type = 'RunKey'; Path = $rk; Name = $n } -Extra $extra
        }
    }

    # --- 启动文件夹 ---
    # 这一块早期版本漏掉了，只扫了 Run 注册表键。
    # 但「往启动文件夹里丢一个 .bat / .cmd / .vbs」是最土也最常见的自启方式，
    # 而且批处理开机时必定闪一个黑框 —— 正是要找的那种东西。
    foreach ($sf in @(
            @{ Path = [Environment]::GetFolderPath('Startup');       Scope = '当前用户' }
            @{ Path = [Environment]::GetFolderPath('CommonStartup'); Scope = '所有用户' }
        )) {
        if ([string]::IsNullOrWhiteSpace($sf.Path) -or -not (Test-Path -LiteralPath $sf.Path)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $sf.Path -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'desktop.ini') { continue }

            # 快捷方式要解出它真正指向的目标，否则只看到一个 .lnk 什么也判断不了
            $target = $file.FullName
            $args = ''
            if ($file.Extension -eq '.lnk') {
                try {
                    $sh = New-Object -ComObject WScript.Shell
                    $lnk = $sh.CreateShortcut($file.FullName)
                    if ($lnk.TargetPath) { $target = $lnk.TargetPath; $args = "$($lnk.Arguments)" }
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
                } catch { }
            }
            $full = ("$target $args").Trim()

            $reasons = @(); $level = $null
            $hidden = Test-WindowHidden $full
            $isConsole = Test-ConsoleCommand -Exe $target -Cmd $full
            $flash = ($isConsole -and -not $hidden)

            foreach ($h in (Get-BadPatternHits $full)) {
                $reasons += $h.Why
                if ($h.Level -eq '高危' -or -not $level) { $level = $h.Level }
            }
            if ($level -ne '高危') {
                $tl = $full.ToLower()
                foreach ($p in $Script:BAD_PATHS) { if ($tl.Contains($p)) { $reasons += '程序位于临时目录，正经软件不会装在那里'; $level = '高危'; break } }
            }
            if (-not $level -and (Test-PathMissing $target)) {
                $reasons += '指向的程序已经不存在了（卸载残留），每次开机都会白白尝试启动一次'
                $level = '无用'
            }
            if ($flash) {
                $reasons = @('⚡ 这一项开机时【会弹出黑框】：放在启动文件夹里的批处理/脚本，或者控制台程序，启动时一定会闪一下窗口。') + $reasons
                if (-not $level) { $level = '可疑' }
            }
            if (-not $level) { continue }

            $extra = "启动文件夹（$($sf.Scope)）：$($sf.Path)"
            if ($hidden -and $isConsole) { $extra += '   ·   已隐藏窗口，不会弹框' }

            $out += New-Finding -Kind '启动文件夹' -Name $file.Name -Command $full -Level $level -Reasons $reasons -Flash $flash `
                -Advice $(if ($level -eq '高危') { '建议先杀毒再处理。' } else { '不需要的话可以禁用（原文件会移到同目录下的「_PCTuner已禁用」子文件夹，随时能移回来）。' }) `
                -Target @{ Type = 'StartupFile'; Path = $file.FullName } -Extra $extra
        }
    }

    return $out
}

# ---------------------------------------------------------------------
#  4. 服务里藏着命令行
# ---------------------------------------------------------------------
function Get-ServiceFindings {
    $out = @()
    try {
        foreach ($s in (Get-CimInstance Win32_Service -ErrorAction Stop)) {
            $p = "$($s.PathName)"
            if (-not $p) { continue }
            if (Test-IsSelf $p) { continue }

            # 微软签名的系统目录服务直接跳过 —— 之前就是因为没跳过，
            # msiexec.exe 里的 "iex" 让 Windows Installer 被误判成高危
            if ($p -match '(?i)^"?[a-z]:\\windows\\(system32|syswow64|servicing)\\') { continue }

            $reasons = @(); $level = $null
            foreach ($h in (Get-BadPatternHits $p)) {
                $reasons += ('服务的启动命令里：' + $h.Why)
                if ($h.Level -eq '高危' -or -not $level) { $level = $h.Level }
            }
            if (-not $level) {
                $pl = $p.ToLower()
                foreach ($bp in $Script:BAD_PATHS) { if ($pl.Contains($bp)) { $reasons += '服务程序位于临时目录'; $level = '高危'; break } }
            }
            if (-not $level) { continue }

            $out += New-Finding -Kind '系统服务' -Name "$($s.DisplayName) ($($s.Name))" -Command $p -Level $level `
                -Reasons ($reasons + '把自己注册成系统服务是很强的驻留方式，开机就自动运行。') `
                -Advice '强烈建议杀毒。确认是坏东西之后再禁用服务。' `
                -Target @{ Type = 'Service'; Name = $s.Name } -Enabled ($s.StartMode -ne 'Disabled')
        }
    } catch { }
    return $out
}

# ---------------------------------------------------------------------
#  5. 杀毒软件状态
# ---------------------------------------------------------------------
function Get-DefenderFindings {
    $out = @()
    $hasThirdParty = $false
    try {
        $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
        $hasThirdParty = @($av | Where-Object { $_.displayName -notmatch '(?i)Windows Defender|Microsoft Defender' }).Count -gt 0
        if ($av.Count -eq 0) {
            $out += New-Finding -Kind '安全状态' -Name '系统里没有检测到任何杀毒软件' -Command '' -Level '可疑' `
                -Reasons @('连 Windows Defender 都没在工作。Defender 被关掉通常两种原因：装了第三方杀毒（正常），或者被恶意软件强行关掉（不正常）。') `
                -Advice '去「Windows 安全中心 → 病毒和威胁防护」看看实时保护是不是开着。如果打不开、或者开关是灰的点不动，基本可以确定中招了。' `
                -Target @{ Type = 'None' }
        }
    } catch { }

    if (-not $hasThirdParty) {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if (-not $mp.RealTimeProtectionEnabled) {
                $out += New-Finding -Kind '安全状态' -Name 'Windows Defender 实时保护是关的，而且没装第三方杀毒' -Command '' -Level '可疑' `
                    -Reasons @('系统现在处于完全没有实时防护的状态。',
                    '恶意软件干的第一件事往往就是关掉杀毒软件 —— 如果你没主动关过，这本身就是个信号。') `
                    -Advice '赶紧去「Windows 安全中心」把实时保护打开，然后做一次完全扫描。' `
                    -Target @{ Type = 'None' }
            }
        } catch { }
    }
    return $out
}

# ---------------------------------------------------------------------
#  汇总
# ---------------------------------------------------------------------
function Get-SuspiciousFindings {
    param([scriptblock]$OnProgress = $null)
    $all = @()
    if ($OnProgress) { & $OnProgress '正在检查计划任务…' }
    $all += Get-TaskFindings
    if ($OnProgress) { & $OnProgress '正在检查 WMI 事件订阅…' }
    $all += Get-WmiFindings
    if ($OnProgress) { & $OnProgress '正在检查开机自启和系统登录项…' }
    $all += Get-AutorunFindings
    if ($OnProgress) { & $OnProgress '正在检查系统服务…' }
    $all += Get-ServiceFindings
    if ($OnProgress) { & $OnProgress '正在检查杀毒软件状态…' }
    $all += Get-DefenderFindings
    return ($all | Sort-Object Score, Kind, Name)
}

# ---------------------------------------------------------------------
#  禁用 / 启用（全部可逆）
# ---------------------------------------------------------------------
function Set-FindingEnabled {
    param($Finding, [bool]$Enabled)
    $t = $Finding.Target
    try {
        switch ($t.Type) {
            'Task' {
                if ($Enabled) { Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null }
                else { Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null }
                Write-Log ("计划任务「{0}」已{1}" -f $Finding.Name, $(if ($Enabled) { '启用' } else { '禁用' })) '成功'
                return $true
            }
            'RunKey' {
                # 禁用 = 把值挪到一个备份键里；启用 = 挪回来。不删除任何数据。
                $bak = $t.Path + '_PCTuner已禁用'
                if ($Enabled) {
                    $v = Get-RegValue -Path $bak -Name $t.Name
                    if ($null -ne $v) {
                        if (-not (Test-Path -LiteralPath $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
                        New-ItemProperty -LiteralPath $t.Path -Name $t.Name -PropertyType String -Value $v -Force | Out-Null
                        Remove-ItemProperty -LiteralPath $bak -Name $t.Name -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    $v = Get-RegValue -Path $t.Path -Name $t.Name
                    if ($null -ne $v) {
                        if (-not (Test-Path -LiteralPath $bak)) { New-Item -Path $bak -Force | Out-Null }
                        New-ItemProperty -LiteralPath $bak -Name $t.Name -PropertyType String -Value $v -Force | Out-Null
                        Remove-ItemProperty -LiteralPath $t.Path -Name $t.Name -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Log ("自启项「{0}」已{1}（原值已备份到 {2}，可随时恢复）" -f $Finding.Name, $(if ($Enabled) { '恢复' } else { '禁用' }), $bak) '成功'
                return $true
            }
            'Service' {
                if ($Enabled) { Restore-Service -Name $t.Name -Default 'Manual' | Out-Null }
                else { Set-ServiceStartup -Name $t.Name -Target 'Disabled' | Out-Null }
                return $true
            }
            'StartupFile' {
                # 禁用 = 挪进同目录下的「_PCTuner已禁用」子文件夹；启用 = 挪回来。
                # 不删除任何文件，随时可逆。
                $file = Get-Item -LiteralPath $t.Path -ErrorAction SilentlyContinue
                $dir = Split-Path -Parent $t.Path
                $stash = Join-Path $dir '_PCTuner已禁用'
                if ($Enabled) {
                    $src = Join-Path $stash (Split-Path $t.Path -Leaf)
                    if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $t.Path -Force -ErrorAction Stop }
                } else {
                    if (-not $file) { return $false }
                    if (-not (Test-Path -LiteralPath $stash)) { New-Item -ItemType Directory -Path $stash -Force | Out-Null }
                    Move-Item -LiteralPath $t.Path -Destination (Join-Path $stash $file.Name) -Force -ErrorAction Stop
                }
                Write-Log ("启动文件夹项「{0}」已{1}" -f (Split-Path $t.Path -Leaf), $(if ($Enabled) { '恢复' } else { '禁用（文件已移到 _PCTuner已禁用 子文件夹）' })) '成功'
                return $true
            }
            'WmiConsumer' {
                if ($Enabled) {
                    Write-Log 'WMI 订阅删除后无法从这里恢复，请用杀毒软件处理' '警告'
                    return $false
                }
                $c = Get-CimInstance -Namespace 'root\subscription' -ClassName '__EventConsumer' -ErrorAction Stop |
                     Where-Object { $_.Name -eq $t.Name }
                foreach ($x in @($c)) { Remove-CimInstance -InputObject $x -ErrorAction Stop }
                Write-Log ("WMI 订阅「{0}」已删除" -f $t.Name) '成功'
                return $true
            }
            default {
                Write-Log '这一项工具不会自动改动（涉及系统核心设置，误改会开不了机），请先杀毒再手动处理' '信息'
                return $false
            }
        }
    } catch {
        Write-Log ("处理「{0}」失败：{1}" -f $Finding.Name, $_.Exception.Message) '错误'
        return $false
    }
}

# ---------------------------------------------------------------------
#  「刚才闪过的到底是什么」—— 读任务计划程序的运行记录
# ---------------------------------------------------------------------
function Test-TaskLogEnabled {
    $r = Invoke-Native 'wevtutil.exe' @('gl', 'Microsoft-Windows-TaskScheduler/Operational')
    return ($r -match '(?im)^\s*enabled:\s*true')
}

function Enable-TaskLog {
    Invoke-Native 'wevtutil.exe' @('sl', 'Microsoft-Windows-TaskScheduler/Operational', '/e:true') | Out-Null
    Write-Log '已开启任务计划程序的运行记录，以后每次任务运行都会被记下来' '成功'
    return (Test-TaskLogEnabled)
}

# =====================================================================
#  进程抓捕 —— 扫「自启位置」抓不到的那一类
# ---------------------------------------------------------------------
#  为什么需要这个：
#    前面那些检查，本质上都是在翻「开机会自动跑什么」。
#    但弹黑框的东西不一定在那些地方 —— 最难查的一种是：
#    某个已经在运行的程序（游戏加速器、录屏、驱动工具、破解补丁…）
#    每隔一段时间自己 spawn 一个 cmd 去干点什么。
#    这个父程序本身可能完全正常、在任何自启位置都看不出问题，
#    但你就是每隔几分钟看到一个黑框。
#
#    对付这种只有一个办法：盯着「新建进程」这件事本身。
#    不管元凶藏在哪，它要弹窗就必须创建进程，跑不掉。
#
#  两条通道：
#    A. 实时监控   —— 工具开着的时候盯，立等可取，能看到父进程
#    B. 持续记录   —— 打开系统自带的进程创建审核，关掉工具也在记，
#                     事后回来查，还带完整命令行
# =====================================================================

$Script:ProcWatchId = 'PCTunerProcWatch'
$Script:ProcWatchLog = New-Object System.Collections.ArrayList
$Script:ProcNameCache = @{}

function Start-ProcWatch {
    <# 通道 A：订阅 WMI 的进程创建事件。需要管理员权限。 #>
    Stop-ProcWatch
    $Script:ProcWatchLog.Clear()
    $Script:ProcNameCache = @{}
    try {
        Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $Script:ProcWatchId -ErrorAction Stop
        Write-Log '已开始实时监控新建进程' '成功'
        return $true
    } catch {
        Write-Log "实时监控启动失败（需要管理员权限）：$($_.Exception.Message)" '警告'
        return $false
    }
}

function Stop-ProcWatch {
    try { Unregister-Event -SourceIdentifier $Script:ProcWatchId -ErrorAction SilentlyContinue } catch { }
    try { Get-Event -SourceIdentifier $Script:ProcWatchId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue } catch { }
}

function Test-ProcWatchRunning {
    return [bool](Get-EventSubscriber -SourceIdentifier $Script:ProcWatchId -ErrorAction SilentlyContinue)
}

function Receive-ProcWatch {
    <# 把攒下来的事件取出来转成好读的记录，返回这一批新增的 #>
    $new = @()
    foreach ($e in @(Get-Event -SourceIdentifier $Script:ProcWatchId -ErrorAction SilentlyContinue)) {
        try {
            $n = $e.SourceEventArgs.NewEvent
            $name = "$($n.ProcessName)"
            $procId = [int]$n.ProcessID
            $parentId = [int]$n.ParentProcessID
            $sess = [int]$n.SessionID
            $Script:ProcNameCache[$procId] = $name

            # 父进程名：优先用刚才记下来的，否则现查（父进程通常还活着）
            $parent = $Script:ProcNameCache[$parentId]
            if (-not $parent) {
                try { $parent = (Get-Process -Id $parentId -ErrorAction Stop).ProcessName + '.exe' }
                catch { $parent = "PID $parentId（已退出）" }
            }
            # 命令行尽力而为 —— 短命进程可能已经没了，取不到很正常
            $cmd = ''
            try { $cmd = "$((Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop).CommandLine)" } catch { }

            $low = $name.ToLower()
            $rec = [PSCustomObject]@{
                Time        = $e.TimeGenerated
                Name        = $name
                ProcId      = $procId
                Parent      = $parent
                ParentId    = $parentId
                Session     = $sess
                CommandLine = $cmd
                # conhost.exe 是「控制台窗口」的宿主进程 —— 它一出现，
                # 就说明刚刚真的有一个黑框被创建出来了，这是最硬的信号
                Console     = ($Script:CONSOLE_HOSTS -contains $low) -or ($low -eq 'conhost.exe')
                Visible     = ($sess -ne 0)
            }
            [void]$Script:ProcWatchLog.Add($rec)
            $new += $rec
        } catch { }
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }
    return $new
}

# ---------- 通道 B：系统自带的进程创建审核（4688）----------
# 子类别必须用 GUID，不能用英文名 ——
# 中文版 Windows 上这个子类别叫「进程创建」，传 "Process Creation" 会直接报参数错误。
$Script:AUDIT_PROCCREATE_GUID = '{0CCE922B-69AE-11D9-BED3-505054503030}'
$Script:AUDIT_CMDLINE_KEY = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'

function Test-ProcAuditEnabled {
    $o = Invoke-Native 'auditpol.exe' @('/get', "/subcategory:$($Script:AUDIT_PROCCREATE_GUID)")
    if ($o -match '(?im)(无审核|No Auditing)') { return $false }
    return ($o -match '(?im)(成功|Success)')
}

function Enable-ProcAudit {
    Invoke-Native 'auditpol.exe' @('/set', "/subcategory:$($Script:AUDIT_PROCCREATE_GUID)", '/success:enable') | Out-Null
    # 让日志里带上完整命令行（否则只有程序路径，看不出它在干什么）
    Set-RegValue -Path $Script:AUDIT_CMDLINE_KEY -Name 'ProcessCreationIncludeCmdLine_Enabled' -Type DWord -Value 1
    $ok = Test-ProcAuditEnabled
    Write-Log $(if ($ok) { '已开启进程创建记录（含命令行）' } else { '开启进程创建记录失败' }) $(if ($ok) { '成功' } else { '错误' })
    return $ok
}

function Disable-ProcAudit {
    Invoke-Native 'auditpol.exe' @('/set', "/subcategory:$($Script:AUDIT_PROCCREATE_GUID)", '/success:disable') | Out-Null
    Restore-RegValue -Path $Script:AUDIT_CMDLINE_KEY -Name 'ProcessCreationIncludeCmdLine_Enabled' -Type DWord -Default '@DELETE@'
    Write-Log '已关闭进程创建记录' '成功'
    return $true
}

function Get-RecentProcessCreations {
    <#
      读安全日志里的 4688（进程创建）。
      按「进程 + 父进程」归类，次数多的排前面 —— 规律性弹窗一定次数很多。
    #>
    param([int]$Minutes = 120, [bool]$ConsoleOnly = $true)
    try {
        $evts = Get-WinEvent -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4688
            StartTime = (Get-Date).AddMinutes(-$Minutes)
        } -MaxEvents 3000 -ErrorAction Stop

        $group = @{}
        foreach ($e in $evts) {
            $d = @{}
            try {
                $x = [xml]$e.ToXml()
                foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = "$($n.'#text')" }
            } catch { continue }

            $np = "$($d['NewProcessName'])"
            if (-not $np) { continue }
            $leaf = ''
            try { $leaf = [System.IO.Path]::GetFileName($np).ToLower() } catch { }
            $isConsole = ($Script:CONSOLE_HOSTS -contains $leaf) -or ($leaf -eq 'conhost.exe') -or (Test-ConsoleSubsystem $np)
            if ($ConsoleOnly -and -not $isConsole) { continue }

            $pp = "$($d['ParentProcessName'])"
            $parentLeaf = ''
            try { if ($pp) { $parentLeaf = [System.IO.Path]::GetFileName($pp) } } catch { }
            $key = "$leaf|$parentLeaf"
            if (-not $group.ContainsKey($key)) {
                $group[$key] = [PSCustomObject]@{
                    Name = $leaf; FullPath = $np; Parent = $(if ($parentLeaf) { $parentLeaf } else { '未知' })
                    ParentPath = $pp; Count = 0; Last = $e.TimeCreated; CommandLine = "$($d['CommandLine'])"; Console = $isConsole
                }
            }
            $group[$key].Count++
            if ($e.TimeCreated -gt $group[$key].Last) { $group[$key].Last = $e.TimeCreated }
            if (-not $group[$key].CommandLine -and $d['CommandLine']) { $group[$key].CommandLine = "$($d['CommandLine'])" }
        }
        return ($group.Values | Sort-Object Count -Descending)
    } catch {
        Write-Log "读取进程创建记录失败：$($_.Exception.Message)" '警告'
        return @()
    }
}

function Get-RecentTaskRuns {
    <#
      把「最近真的运行过的任务」捞出来。
      这是排查弹窗最直接的办法：看到黑框之后马上来刷新，
      时间对得上的那一条就是元凶。
    #>
    param([int]$Hours = 24)
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-TaskScheduler/Operational'
            Id        = 129
            StartTime = (Get-Date).AddHours(-$Hours)
        } -ErrorAction Stop -MaxEvents 500

        $group = @{}
        foreach ($e in $events) {
            # 用 XML 取字段，避免不同语言的系统上消息文本不同导致解析失败
            $name = ''; $exe = ''
            try {
                $x = [xml]$e.ToXml()
                foreach ($d in $x.Event.EventData.Data) {
                    if ($d.Name -eq 'TaskName') { $name = "$($d.'#text')" }
                    if ($d.Name -eq 'Path') { $exe = "$($d.'#text')" }
                }
            } catch { }
            if (-not $name) { continue }
            $key = "$name|$exe"
            if (-not $group.ContainsKey($key)) {
                $group[$key] = [PSCustomObject]@{ TaskName = $name; Exe = $exe; Count = 0; Last = $e.TimeCreated }
            }
            $group[$key].Count++
            if ($e.TimeCreated -gt $group[$key].Last) { $group[$key].Last = $e.TimeCreated }
        }
        return ($group.Values | Sort-Object Last -Descending)
    } catch {
        return @()
    }
}
