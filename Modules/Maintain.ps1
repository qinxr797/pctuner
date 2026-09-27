<#
=====================================================================
  Maintain.ps1  ——  日常维护工具
---------------------------------------------------------------------
  「性能优化」是一次性的，「垃圾清理」是定期的，
  这一页放的是平时偶尔用一次、但真的能解决问题的小工具。

  【关于「内存优化 / 内存整理」】
    这个工具**故意不做**内存整理功能。
    市面上那些「一键释放内存」的原理是强制把程序的内存页
    赶到硬盘上（EmptyWorkingSet），任务管理器里的数字确实
    降下来了，但代价是这些程序下次用到那些数据时要从硬盘
    重新读回来 —— 结果是更卡，不是更快。
    这是纯粹的视觉安慰剂，所以不做。
    内存真不够就去「系统体检」页看加内存的建议。
=====================================================================
#>

# =====================================================================
#  1. 刷新 DNS 缓存
# =====================================================================
function Clear-DnsCacheNow {
    <#
      什么时候用：
        · 某个网站突然打不开，别的都正常
        · 刚改过 DNS / 刚连上加速器，解析还是旧的
        · 游戏登录服务器连不上，但网页能上
    #>
    $out = Invoke-Native 'ipconfig.exe' @('/flushdns')
    Write-Log "已刷新 DNS 缓存：$out" '成功'
    return $out
}

# =====================================================================
#  1.5 显示器刷新率
# ---------------------------------------------------------------------
#  为什么值得单独做一个功能：
#    买了高刷屏但系统里还跑在 60Hz，是非常常见的情况 ——
#    线插在主板核显口上、换了线、重装了驱动、接了新显示器…… 都会退回 60Hz。
#    对 FPS 玩家来说，144Hz 和 60Hz 的差距比任何注册表优化都大得多。
#    体检页一直在提醒这件事，但光提醒不能改，所以这里补上一键切换。
#
#  安全网：切换后弹一个 15 秒倒计时确认框。要是切完黑屏 / 花屏，
#  什么都不用做，倒计时结束会自动切回原来的设置 —— 和 Windows 自己
#  改分辨率时的行为一样。
# =====================================================================
if (-not ('PCTuner.Display' -as [type])) {
    Add-Type -Namespace PCTuner -Name Display -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int   dmFields;
    public int   dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int   dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int   dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    public int   dmPanningWidth, dmPanningHeight;
}
[DllImport("user32.dll", CharSet = CharSet.Ansi)]
public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
[DllImport("user32.dll", CharSet = CharSet.Ansi)]
public static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);
'@ -ErrorAction SilentlyContinue
}

# ★ 注意 ★ 调用时设备名必须传 [NullString]::Value，不能传 $null。
#   PowerShell 把 $null 传给 P/Invoke 的 string 参数时会marshal成空字符串 ""，
#   而 EnumDisplaySettings("") 会直接失败返回 False —— 现象是「什么都读不到」
#   但又不报错，非常难查。这个坑踩过一次。
function Get-CurrentDisplayMode {
    $dm = New-Object PCTuner.Display+DEVMODE
    $dm.dmSize = [int16][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    if ([PCTuner.Display]::EnumDisplaySettings([NullString]::Value, -1, [ref]$dm)) {   # -1 = ENUM_CURRENT_SETTINGS
        return [PSCustomObject]@{ Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight; Hz = $dm.dmDisplayFrequency }
    }
    return $null
}

function Get-DisplayRefreshOptions {
    <# 当前分辨率下，显示器/显卡支持的所有刷新率 #>
    $cur = Get-CurrentDisplayMode
    if (-not $cur) { return @() }
    $list = @()
    $i = 0
    while ($true) {
        $dm = New-Object PCTuner.Display+DEVMODE
        $dm.dmSize = [int16][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [PCTuner.Display]::EnumDisplaySettings([NullString]::Value, $i, [ref]$dm)) { break }
        if ($dm.dmPelsWidth -eq $cur.Width -and $dm.dmPelsHeight -eq $cur.Height -and $dm.dmBitsPerPel -ge 32) {
            if ($list -notcontains $dm.dmDisplayFrequency) { $list += $dm.dmDisplayFrequency }
        }
        $i++
        if ($i -gt 2000) { break }   # 防止驱动异常时死循环
    }
    return ($list | Sort-Object -Descending)
}

function Set-DisplayRefreshRate {
    <# 只改刷新率，不动分辨率。返回 $true 表示切换成功。 #>
    param([int]$Hz)
    $dm = New-Object PCTuner.Display+DEVMODE
    $dm.dmSize = [int16][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
    if (-not [PCTuner.Display]::EnumDisplaySettings([NullString]::Value, -1, [ref]$dm)) { return $false }
    $dm.dmDisplayFrequency = $Hz
    # 0x00080000 宽 | 0x00100000 高 | 0x00040000 色深 | 0x00400000 刷新率
    $dm.dmFields = 0x00080000 -bor 0x00100000 -bor 0x00040000 -bor 0x00400000

    # 先用 CDS_TEST(0x02) 试一下，驱动说不行就别真改，免得黑屏
    if ([PCTuner.Display]::ChangeDisplaySettings([ref]$dm, 0x02) -ne 0) {
        Write-Log "显卡驱动拒绝了 $Hz Hz 这个模式" '警告'
        return $false
    }
    $r = [PCTuner.Display]::ChangeDisplaySettings([ref]$dm, 0x01)   # CDS_UPDATEREGISTRY，重启后保持
    if ($r -eq 0) { Write-Log "显示器刷新率已切换到 $Hz Hz" '成功'; return $true }
    Write-Log "切换刷新率失败（返回码 $r）" '错误'
    return $false
}

# =====================================================================
#  2. 磁盘优化（固态 TRIM / 机械 碎片整理）
# =====================================================================
function Get-VolumesToOptimize {
    $list = @()
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' -and $_.DriveType -eq 'Fixed' })) {
        $isSSD = $true
        try {
            $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop
            $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" }
            if ($disk) {
                if ($disk.MediaType -eq 'HDD') { $isSSD = $false }
                elseif ($disk.MediaType -ne 'SSD' -and $disk.SpindleSpeed -gt 0) { $isSSD = $false }
            }
        } catch { }
        $list += [PSCustomObject]@{
            Letter = $v.DriveLetter
            IsSSD  = $isSSD
            Label  = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { '本地磁盘' }
            Size   = $v.Size
            Free   = $v.SizeRemaining
        }
    }
    return $list
}

function Invoke-DiskOptimize {
    <#
      固态盘 -> ReTrim（告诉固态哪些块已经没用了，恢复写入速度）
      机械盘 -> Defrag（碎片整理）
      工具会自动判断介质类型，不会对固态做碎片整理（那会白白消耗寿命）。
    #>
    param([string]$DriveLetter, [bool]$IsSSD)
    try {
        if ($IsSSD) {
            Write-Log "正在对 $DriveLetter 盘执行 TRIM（固态盘）…" '信息'
            Optimize-Volume -DriveLetter $DriveLetter -ReTrim -ErrorAction Stop
            Write-Log "$DriveLetter 盘 TRIM 完成" '成功'
        } else {
            Write-Log "正在对 $DriveLetter 盘做碎片整理（机械盘，可能要几十分钟）…" '信息'
            Optimize-Volume -DriveLetter $DriveLetter -Defrag -ErrorAction Stop
            Write-Log "$DriveLetter 盘碎片整理完成" '成功'
        }
        return $true
    } catch {
        Write-Log "优化 $DriveLetter 盘失败：$($_.Exception.Message)" '错误'
        return $false
    }
}

# =====================================================================
#  3. 硬盘健康 / 寿命检查
# =====================================================================
function Get-DiskHealthReport {
    <#
      读取 SMART 里最有价值的几个数据。
      老机器最怕的就是硬盘悄悄坏掉，这一项能提前发现。

      ★ v6.2：寿命统一说「剩余寿命 X%」★
        v6.1 以前这里拿 Get-StorageReliabilityCounter 的 Wear（意思是「寿命**已用**百分之几」），
        界面上却写成「0 % 寿命」—— 朋友一看就读成「寿命只剩 0%」。两个错叠在一起：
          · 文案错：已用写成了寿命
          · 数也不可信：老板的三星 PM981 显示 0，盘自己的 NVMe 日志写的是已用 6%（2026-09-28 实测）
        现在：
          · NVMe 盘 —— 直接读盘自己的健康日志（Get-NvmeHealth），剩余寿命 = 100 − 已用
          · 其余固态 —— 只有系统计数器给出**非零**值才采信（0 在很多盘上是占位）；否则「—」，注明「这块盘不报告寿命」
          · 机械盘 —— 没有「寿命百分比」这回事，看通电时长
        对不上就不采信：盘说「已用 0%」但累计写入已经是容量的 50 倍以上，这个 0 就是假的。

      返回 @{ Name; Media; Size; Health; Life; LifeWhy; Temp; Hours; WrittenTB; Verdict; Level }
        Life = 剩余寿命百分比（0~100），读不到 / 不可信时是 $null
    #>
    $rows = @()
    foreach ($d in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $cWear = $null; $temp = $null; $hours = $null; $readErr = $null
        try {
            $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            $cWear = $rc.Wear
            $temp = $rc.Temperature
            $hours = $rc.PowerOnHours
            $readErr = $rc.ReadErrorsTotal
        } catch { }

        $mt = switch ("$($d.MediaType)") {
            'SSD' { '固态' } 'HDD' { '机械' }
            default { if ($d.SpindleSpeed -eq 0) { '固态' } else { '未知' } }
        }

        $nv = $null
        if ($mt -ne '机械') { $nv = Get-NvmeHealth -DiskNumber ([int]$d.DeviceId) }
        $life = $null; $lifeWhy = ''; $written = $null
        if ($nv) {
            if ($mt -eq '未知') { $mt = '固态' }        # 读得到 NVMe 日志的一定是固态
            $written = $nv.WrittenTB
            if ($null -eq $hours -or $hours -le 0) { $hours = $nv.Hours }
            if ($null -eq $temp -or $temp -le 0) { $temp = $nv.TempC }
            $capTB = [double]$d.Size / 1e12
            if ($nv.Used -eq 0 -and $capTB -gt 0 -and $nv.WrittenTB -gt 50 * $capTB) {
                $lifeWhy = "盘报「已用 0%」，但累计写入已有 $($nv.WrittenTB) TB，两者对不上，不采信"
            } else {
                $life = [math]::Max(0, 100 - $nv.Used)
            }
            if ($null -ne $cWear -and [int]$cWear -ne $nv.Used) {
                Write-Log ("{0}：系统计数器报寿命已用 {1}%，盘自己的 NVMe 日志是 {2}%，以盘为准" -f $d.FriendlyName, $cWear, $nv.Used) '信息'
            }
        } elseif ($mt -eq '固态') {
            if ($null -ne $cWear -and [int]$cWear -gt 0) { $life = [math]::Max(0, 100 - [int]$cWear) }
            else { $lifeWhy = '这块盘不报告寿命' }
        }

        # 给一句人话结论
        $verdict = '正常'
        $level = '良好'
        if ($d.HealthStatus -ne 'Healthy') { $verdict = "系统报告状态异常（$($d.HealthStatus)）—— 尽快备份重要资料"; $level = '严重' }
        elseif ($nv -and $nv.Critical -ne 0) { $verdict = '盘自己报了严重警告（备用块不足 / 过热 / 转为只读 / 可靠性下降之一）—— 尽快备份重要资料'; $level = '严重' }
        elseif ($nv -and $nv.SpareThreshold -gt 0 -and $nv.Spare -lt $nv.SpareThreshold) { $verdict = "备用块只剩 $($nv.Spare)%，低于盘自己定的下限 $($nv.SpareThreshold)% —— 尽快备份、考虑更换"; $level = '严重' }
        elseif ($null -ne $life -and $life -le 10) { $verdict = "剩余寿命 $life%，快用完了，建议开始考虑更换"; $level = '严重' }
        elseif ($null -ne $life -and $life -le 30) { $verdict = "剩余寿命 $life%，还能用但要留意了"; $level = '建议' }
        elseif (($nv -and $nv.MediaErrors -gt 0) -or ($null -ne $readErr -and $readErr -gt 0)) {
            $n = if ($nv -and $nv.MediaErrors -gt 0) { $nv.MediaErrors } else { $readErr }
            $verdict = "累计出过 $n 次读写错误 —— 有坏块迹象，建议备份重要资料"; $level = '建议'
        }
        elseif ($null -ne $hours -and $hours -gt 35000) { $verdict = "已通电 $hours 小时（约 $([math]::Round($hours/8760,1)) 年），属于高龄硬盘，注意备份"; $level = '建议' }
        elseif ($null -ne $life) { $verdict = "健康，剩余寿命 $life%" }

        $rows += [PSCustomObject]@{
            Name      = ("$($d.FriendlyName)" -replace '-0{3,}$', '')     # 「MZVLB1T0HBLR-00000」这种出厂后缀没信息量，还把名字挤成两行
            Media     = $mt
            Size      = (Format-Size $d.Size)
            Health    = $d.HealthStatus
            Life      = $life
            LifeWhy   = $lifeWhy
            Temp      = $temp
            Hours     = $hours
            WrittenTB = $written
            Verdict   = $verdict
            Level     = $level
        }
    }
    return $rows
}

# =====================================================================
#  4. 大文件查找 —— 「我 C 盘到底被什么占满了」
# =====================================================================
function Find-LargeFiles {
    <#
      扫描指定盘，找出最大的那些文件。
      只列出来给你看，**不会自动删任何东西** —— 删什么由你决定。
    #>
    param(
        [string]$Root = $env:SystemDrive,
        [int]$MinMB = 300,
        [int]$Top = 40,
        [scriptblock]$OnProgress = $null
    )
    $minBytes = $MinMB * 1MB
    $results = New-Object System.Collections.ArrayList
    $scanned = 0

    # 跳过这些目录：WinSxS 里大量是硬链接（算出来的大小是假的），
    # 回收站有单独的清理项，系统卷信息没有查看意义
    $skip = @('\WinSxS', '\$Recycle.Bin', '\System Volume Information', '\WindowsApps')

    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if ($skip | Where-Object { $dir -like "*$_*" }) { continue }

        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $len = (New-Object System.IO.FileInfo $f).Length
                    if ($len -ge $minBytes) { [void]$results.Add([PSCustomObject]@{ Path = $f; Size = $len }) }
                } catch { }
            }
            foreach ($s in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($s) }
        } catch { }

        $scanned++
        if ($OnProgress -and ($scanned % 400 -eq 0)) { & $OnProgress $dir $results.Count }
    }
    return ($results | Sort-Object Size -Descending | Select-Object -First $Top)
}

# =====================================================================
#  5. 聊天软件占用report（微信 / QQ）
# =====================================================================
function Get-ChatAppPaths {
    <# 找出微信 / QQ 的数据目录（用户可能改过默认位置，所以先读注册表） #>
    $paths = @()

    # --- 微信 ---
    $wxRoot = $null
    $cfg = Get-RegValue -Path 'HKCU:\Software\Tencent\WeChat' -Name 'FileSavePath'
    if ($cfg -and $cfg -ne 'MyDocument:' -and (Test-Path -LiteralPath $cfg)) { $wxRoot = $cfg }
    if (-not $wxRoot) { $wxRoot = [Environment]::GetFolderPath('MyDocuments') }
    foreach ($n in 'WeChat Files', 'xwechat_files') {
        $p = Join-Path $wxRoot $n
        if (Test-Path -LiteralPath $p) { $paths += [PSCustomObject]@{ App = '微信'; Path = $p } }
    }

    # --- QQ / TIM ---
    $qqRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tencent Files'
    if (Test-Path -LiteralPath $qqRoot) { $paths += [PSCustomObject]@{ App = 'QQ'; Path = $qqRoot } }

    return $paths
}

function Get-ChatAppUsage {
    <#
      只统计占用大小，不删任何东西。
      聊天记录、图片、收到的文件对很多人是重要资料，
      这个工具的原则是绝不替你决定哪些聊天内容该删。
    #>
    $rows = @()
    foreach ($p in (Get-ChatAppPaths)) {
        $size = 0
        try {
            $s = (Get-ChildItem -LiteralPath $p.Path -Force -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
            if ($s) { $size = $s }
        } catch { }
        $rows += [PSCustomObject]@{ App = $p.App; Path = $p.Path; Size = $size }
    }
    return $rows
}

# =====================================================================
#  6. 每周自动清理（计划任务）
# =====================================================================
$Script:AUTOCLEAN_TASK = 'PCTuner-每周自动清理'

function Test-AutoCleanEnabled {
    try { return $null -ne (Get-ScheduledTask -TaskName $Script:AUTOCLEAN_TASK -ErrorAction Stop) } catch { return $false }
}

function Enable-AutoClean {
    <#
      注册一个计划任务，每周日中午 12 点静默跑一遍「推荐」清理项。
      它调用的就是本工具自己（PCTuner.ps1 -AutoClean），
      不会弹窗、不会动任何性能设置，只清缓存和临时文件。
    #>
    param([string]$ScriptPath)
    try {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AutoClean' -f $ScriptPath
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00'
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $Script:AUTOCLEAN_TASK -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description '每周自动清理系统垃圾与缓存（PC调优助手）' -Force -ErrorAction Stop | Out-Null
        Write-Log '已开启每周自动清理（每周日 12:00，静默运行）' '成功'
        return $true
    } catch {
        Write-Log "开启自动清理失败：$($_.Exception.Message)" '错误'
        return $false
    }
}

function Disable-AutoClean {
    try {
        Unregister-ScheduledTask -TaskName $Script:AUTOCLEAN_TASK -Confirm:$false -ErrorAction Stop
        Write-Log '已关闭每周自动清理' '成功'
        return $true
    } catch {
        Write-Log "关闭自动清理失败：$($_.Exception.Message)" '错误'
        return $false
    }
}

# =====================================================================
#  7. 无界面的自动清理（给计划任务调用）
# =====================================================================
function Invoke-SilentClean {
    <# 跑一遍所有「推荐」的清理项，全程不弹窗，结果写进日志 #>
    $total = 0
    Write-Log '=== 每周自动清理开始 ===' '信息'
    foreach ($it in (Get-CleanupItems)) {
        if (-not $it.Recommended) { continue }
        if ($it.NeedExplorerRestart) { continue }   # 自动运行时不重启资源管理器，免得打断你
        $total += (Invoke-CleanupItem $it)
    }
    Write-Log ("=== 每周自动清理完成，共释放 {0} ===" -f (Format-Size $total)) '成功'
    return $total
}
