<#
=====================================================================
  SysInfo.ps1  ——  硬件信息 + 系统体检
---------------------------------------------------------------------
  「体检」这一页是整个工具里最重要的部分。

  原因很现实：改注册表能带来的提升是有上限的。一台五年前的机器，
  所有软件优化加起来可能提升 10%~20%；但换一块固态硬盘能让开机
  和加载速度快 5 倍，加一条内存能让「同时开一堆东西」从卡到不卡。

  所以这一页不只报参数，它会按「性价比从高到低」告诉你：
  这台机器现在最该做的是哪件事。
=====================================================================
#>

function Get-VirtualizationState {
    <#
      检测和「腾讯 ACE 反作弊」相关的四个虚拟化开关。

      为什么要专门做这个检测：
        无畏契约国服 / 三角洲行动的 ACE 反作弊要求是
            BIOS 里：VT-x / SVM 和 VT-d / IOMMU  → 要【开】
            Windows 里：内存完整性(HVCI)、Hyper-V → 要【关】
        这两个方向是相反的，是玩家最容易搞混的地方，
        也是「CPU虚拟化未开启或被占用」弹窗的唯一成因。
    #>
    $s = @{
        Firmware = $null; Iommu = $null; Hvci = $null; HyperV = $null
        FirmwareText = '检测不到'; IommuText = '检测不到'; HvciText = '检测不到'; HyperVText = '检测不到'
    }

    # --- Hyper-V 是不是正在跑 ---
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $s.HyperV = [bool]$cs.HypervisorPresent
        $s.HyperVText = if ($s.HyperV) { '正在运行  ← ACE 反作弊要求关闭' } else { '未运行 ✓（符合 ACE 要求）' }
    } catch { }

    # --- BIOS 里的虚拟化开关 ---
    # 注意：Hyper-V 跑起来之后，这个字段会变得不可靠（系统看不到裸机状态），
    #       所以 Hyper-V 在跑时直接说明情况，不给误导性的结论。
    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        if ($s.HyperV) {
            $s.Firmware = $true
            $s.FirmwareText = '已开启 ✓（Hyper-V 正在占用它，所以 ACE 拿不到）'
        } elseif ($null -ne $cpu.VirtualizationFirmwareEnabled) {
            $s.Firmware = [bool]$cpu.VirtualizationFirmwareEnabled
            $s.FirmwareText = if ($s.Firmware) { '已开启 ✓（符合 ACE 要求）' } else { '未开启  ← 需要进 BIOS 打开（Intel: VT-x / AMD: SVM Mode）' }
        }
    } catch { }

    # --- VT-d / IOMMU（DMA 保护）---
    # AvailableSecurityProperties 里的 3 代表「DMA 保护可用」，也就是 IOMMU/VT-d 打开了
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $avail = @($dg.AvailableSecurityProperties)
        $s.Iommu = ($avail -contains 3)
        $s.IommuText = if ($s.Iommu) { '已开启 ✓（符合 ACE 要求）' } else { '未开启 / 检测不到  ← 三角洲可能要求它，进 BIOS 打开（Intel: VT-d / AMD: IOMMU）' }

        $running = @($dg.SecurityServicesRunning)
        $s.Hvci = ($running -contains 2)
        $s.HvciText = if ($s.Hvci) { '已开启  ← ACE 反作弊要求关闭，且 CS2 实测会损失约 25 帧' } else { '未开启 ✓（符合 ACE 要求，对 CS2 帧数也有利）' }
    } catch { }

    return $s
}

function Format-Span {
    param([TimeSpan]$T)
    if ($T.TotalMinutes -lt 60) { return ("{0} 分钟" -f [int]$T.TotalMinutes) }
    if ($T.TotalHours -lt 24) { return ("{0} 小时 {1} 分钟" -f [int]$T.TotalHours, $T.Minutes) }
    return ("{0} 天 {1} 小时" -f $T.Days, $T.Hours)
}

function Get-BootInfo {
    <#
      ★「已开机时长」这个数字有个大坑，必须拆开讲 ★

      Windows 的 LastBootUpTime 记的是【上一次真正启动】的时间。
      而「快速启动」开着的时候，点关机并不是真关机 ——
      它把内核状态休眠到硬盘，下次开机直接恢复，LastBootUpTime 原封不动。

      结果就是：人刚按下电源键开机，工具却显示「已开机 9 天」，
      看起来像见了鬼，其实是在说「内核已经 9 天没真正重启过了」。

      所以这里把两件事分开算：
        本次开机       —— 你刚按电源键那一次，以及它是哪种启动方式
        距上次真正重启 —— 内核实际连续运行了多久（这才是该关心的）

      判断启动方式用 Kernel-Boot 事件 27 的 BootType 字段：
        0 = 完整启动（真正的冷启动或重启）
        1 = 快速启动恢复（点了开机，但不算重启）
        2 = 从休眠恢复
    #>
    $info = @{ LastTrueBoot = $null; TrueUp = $null; LastPowerOn = $null; BootType = $null; FastStartup = $null }
    try { $info.LastTrueBoot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
    if ($info.LastTrueBoot) { $info.TrueUp = (Get-Date) - $info.LastTrueBoot }

    # 这个值不存在时，Windows 的默认行为是【开启】快速启动
    $hb = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled'
    $info.FastStartup = ($null -eq $hb -or $hb -eq 1)

    try {
        $e = Get-WinEvent -FilterHashtable @{
            LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27
        } -MaxEvents 1 -ErrorAction Stop
        $info.LastPowerOn = $e.TimeCreated
        $x = [xml]$e.ToXml()
        foreach ($d in $x.Event.EventData.Data) { if ($d.Name -eq 'BootType') { $info.BootType = [int]$d.'#text' } }
    } catch { }
    return $info
}

function Get-SystemReport {
    <# 返回一组 [名称, 值] 用于在界面上罗列 #>
    $rows = New-Object System.Collections.ArrayList
    function Add-Row { param($k, $v) [void]$rows.Add([PSCustomObject]@{ Key = $k; Value = "$v" }) }

    try {
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cs  = Get-CimInstance Win32_ComputerSystem  -ErrorAction SilentlyContinue
        $cpu = @(Get-CimInstance Win32_Processor     -ErrorAction SilentlyContinue)[0]
        $bb  = Get-CimInstance Win32_BaseBoard       -ErrorAction SilentlyContinue
        $bios= Get-CimInstance Win32_BIOS            -ErrorAction SilentlyContinue

        # ---------- 系统 ----------
        $build = "$($os.Version)"
        $ubr   = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR'
        $disp  = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion'
        if (-not $disp) { $disp = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ReleaseId' }
        Add-Row '操作系统' ("{0}  版本 {1}  (内部版本 {2}.{3})" -f $os.Caption, $disp, $build, $ubr)
        Add-Row '机型'     ("{0} {1}{2}" -f $cs.Manufacturer, $cs.Model, $(if (Test-IsLaptop) { '   [笔记本]' } else { '   [台式机]' }))
        if ($bb) { Add-Row '主板' ("{0} {1}" -f $bb.Manufacturer, $bb.Product) }
        if ($bios) {
            $bd = $bios.ReleaseDate
            Add-Row 'BIOS 版本' ("{0}   发布于 {1}" -f $bios.SMBIOSBIOSVersion, $(if ($bd) { $bd.ToString('yyyy-MM-dd') } else { '未知' }))
        }

        # ---------- CPU ----------
        if ($cpu) {
            Add-Row '处理器' ("{0}" -f $cpu.Name.Trim())
            Add-Row 'CPU 规格' ("{0} 核 {1} 线程   标称频率 {2} MHz" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.MaxClockSpeed)
        }

        # ---------- 内存 ----------
        $totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $freeGB  = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
        $usedPct = if ($totalGB -gt 0) { [math]::Round((1 - ($freeGB / $totalGB)) * 100) } else { 0 }
        Add-Row '内存容量' ("{0} GB   （当前已用 {1}%，剩余 {2} GB）" -f $totalGB, $usedPct, $freeGB)

        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($sticks.Count -gt 0) {
            $slots = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1).MemoryDevices
            $spd = ($sticks | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Select-Object -First 1)
            Add-Row '内存条' ("{0} 条  /  共 {1} 个插槽   频率 {2} MHz   {3}" -f $sticks.Count, $slots, $spd,
                $(if ($sticks.Count -ge 2) { '[双通道 ✓]' } else { '[单通道 —— 见下方体检建议]' }))
        }

        # ---------- 显卡 ----------
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
            if (-not $g.Name) { continue }
            $vram = ''
            if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) { $vram = "   显存 {0} GB" -f ([math]::Round($g.AdapterRAM / 1GB, 1)) }
            $dd = ''
            if ($g.DriverDate) { $dd = "   驱动 {0}（{1}）" -f $g.DriverVersion, $g.DriverDate.ToString('yyyy-MM-dd') }
            Add-Row '显卡' ("{0}{1}{2}" -f $g.Name, $vram, $dd)
        }

        # ---------- 硬盘 ----------
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $mt = switch ("$($d.MediaType)") { 'SSD' { '固态硬盘 SSD' } 'HDD' { '机械硬盘 HDD' } default { if ($d.SpindleSpeed -eq 0) { '固态硬盘 SSD' } else { "$($d.MediaType)" } } }
            $health = if ($d.HealthStatus -eq 'Healthy') { '健康' } else { "$($d.HealthStatus)  ← 注意！" }
            Add-Row '物理硬盘' ("{0}   {1}   {2}   状态：{3}" -f $d.FriendlyName, (Format-Size $d.Size), $mt, $health)
        }
        foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            $pct = if ($v.Size -gt 0) { [math]::Round($v.FreeSpace / $v.Size * 100) } else { 0 }
            Add-Row "分区 $($v.DeviceID)" ("总 {0}   可用 {1}   （剩余 {2}%）" -f (Format-Size $v.Size), (Format-Size $v.FreeSpace), $pct)
        }

        # ---------- 运行状态 ----------
        # 「本次开机」和「距上次真正重启」是两件事，快速启动开着时差别巨大，
        # 混成一个「已开机时长」会让人以为工具坏了（刚开机却显示开了 9 天）
        $bi = Get-BootInfo
        if ($bi.LastPowerOn) {
            $btText = switch ($bi.BootType) {
                0 { '完整启动' } 1 { '快速启动恢复，不算重启' } 2 { '从休眠恢复' } default { '方式未知' }
            }
            Add-Row '本次开机' ("{0}   已运行 {1}   （{2}）" -f $bi.LastPowerOn.ToString('MM-dd HH:mm'), (Format-Span ((Get-Date) - $bi.LastPowerOn)), $btText)
        }
        if ($bi.TrueUp) {
            $note = ''
            if ($bi.TrueUp.Days -ge 3 -and $bi.FastStartup) { $note = '   ← 快速启动开着，所以点关机不算重启' }
            Add-Row '距上次真正重启' ((Format-Span $bi.TrueUp) + $note)
        }
        Add-Row '快速启动' $(if ($bi.FastStartup) { '已开启  ← 点「关机」不是真关机，很多玄学问题的根源' } else { '已关闭 ✓（点关机就是真关机）' })
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if ($pf.Count -gt 0) {
            Add-Row '虚拟内存' ("{0}   当前 {1} MB" -f $pf[0].Name, $pf[0].AllocatedBaseSize)
        } else {
            Add-Row '虚拟内存' '未启用  ← 见下方体检建议'
        }

        # ---------- 显示器（FPS 玩家很在意的一项） ----------
        $refresh = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                     Where-Object { $_.CurrentRefreshRate -and $_.CurrentHorizontalResolution } |
                     Select-Object -First 1)
        if ($refresh.Count -gt 0) {
            $r = $refresh[0]
            Add-Row '当前显示模式' ("{0} x {1}  @ {2} Hz" -f $r.CurrentHorizontalResolution, $r.CurrentVerticalResolution, $r.CurrentRefreshRate)
        }

        # ---------- 虚拟化 / 反作弊相关（腾讯 ACE 要看这几项） ----------
        $v = Get-VirtualizationState
        Add-Row 'BIOS 虚拟化 (VT-x/SVM)' $v.FirmwareText
        Add-Row 'DMA 保护 (VT-d/IOMMU)'  $v.IommuText
        Add-Row '内核隔离 (VBS/HVCI)'     $v.HvciText
        Add-Row 'Hyper-V 虚拟化层'        $v.HyperVText

    } catch {
        Add-Row '读取硬件信息出错' $_.Exception.Message
    }

    return $rows
}


function Get-HealthAdvice {
    <#
      系统体检：按「投入产出比」从高到低给建议。
      每条返回 @{ Level = '严重'/'建议'/'良好'; Title; Text }
    #>
    $advice = New-Object System.Collections.ArrayList
    function Add-Advice { param($lv, $t, $x) [void]$advice.Add([PSCustomObject]@{ Level = $lv; Title = $t; Text = $x }) }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cs = Get-CimInstance Win32_ComputerSystem  -ErrorAction SilentlyContinue

        # ===== 1. 系统盘是不是机械硬盘（影响最大的一件事）=====
        if (-not (Test-SystemDriveIsSSD)) {
            Add-Advice '严重' '系统盘是机械硬盘 —— 换固态是性价比最高的升级，没有之一' @'
这是这台机器上最值得花的一笔钱。

一块 500GB 的 SATA 固态现在只要两百块出头，装上之后：
· 开机从 1 分钟变成 15 秒
· 游戏读图时间缩短一半以上（尤其是开放世界）
· 点什么都不用等，「卡一下」的感觉基本消失

这个提升是**软件优化完全做不到的量级**。本工具里所有优化项
加起来的效果，都不如换一块固态。

怎么做：把系统装到固态上（或者用迁移工具整盘迁移），
机械盘留着当仓库盘放游戏和资料。
'@
        }

        # ===== 2. 内存容量 =====
        $totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        if ($totalGB -le 8.5) {
            Add-Advice '严重' ("内存只有 {0} GB —— 这是现在游戏卡顿的主要瓶颈" -f $totalGB) @'
2024 年之后的游戏，官方最低配置基本都写着 16GB 内存。
8GB 的后果不是「帧数低」，而是「帧数忽高忽低」：
内存不够时系统被迫把数据往硬盘上倒，每倒一次就卡一下。

加一条内存通常只要一两百块，是仅次于换固态的高性价比升级。

注意事项：
· 一定要买和现有内存**相同频率、最好相同品牌型号**的，
  混插可能会导致降频甚至开不了机
· 台式机看主板还有没有空插槽；笔记本看是不是板载内存
  （板载的加不了）
· 在「硬件信息」里能看到你现在是几条内存、多少插槽、什么频率
'@
        } elseif ($totalGB -le 16.5) {
            Add-Advice '良好' ("内存 {0} GB —— 够用" -f $totalGB) '目前主流游戏够用。如果你习惯一边游戏一边开浏览器几十个标签页 + 直播软件，可以考虑加到 32GB。'
        } else {
            Add-Advice '良好' ("内存 {0} GB —— 充足" -f $totalGB) '内存不是瓶颈，不用管。'
        }

        # ===== 3. 单通道内存 =====
        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($sticks.Count -eq 1) {
            Add-Advice '建议' '内存是单通道 —— 组双通道能白捡性能' @'
你现在只插了一条内存，走的是单通道。

再加一条**同规格**的内存组成双通道，内存带宽直接翻倍。
对纯独显游戏来说提升大约 5%~10%；
如果你用的是**核显（集成显卡）**，提升可以到 20%~40%，
因为核显直接吃内存带宽，这是质变。

同样注意：频率、容量尽量和现有的一致。
'@
        }

        # ===== 4. 系统盘剩余空间 =====
        $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
        if ($sys -and $sys.Size -gt 0) {
            $pct = [math]::Round($sys.FreeSpace / $sys.Size * 100)
            $freeGB = [math]::Round($sys.FreeSpace / 1GB, 1)
            if ($pct -lt 10 -or $freeGB -lt 15) {
                Add-Advice '严重' ("系统盘只剩 {0} GB（{1}%）—— 会直接导致卡顿" -f $freeGB, $pct) @'
C 盘空间不足会实实在在地让系统变慢：
· 虚拟内存没地方扩展 → 内存一紧张就卡死
· 固态硬盘剩余空间低于 10%~15% 时，写入速度会断崖式下跌
  （固态需要空闲块来做磨损均衡）
· Windows 更新装不上，临时文件没地方放

马上能做的（按见效快慢排）：
1. 去「垃圾清理」页全选推荐项清一遍
2. 如果有 C:\Windows.old，删掉它（通常 15~30 GB）
3. 跑一次「深度清理 WinSxS 组件仓库」（通常 1~5 GB）
4. 在「性能优化」页关掉休眠（释放约等于内存大小的空间）
5. 把 Steam 游戏库移到别的盘（Steam 设置里可以直接迁移）
'@
            } elseif ($pct -lt 20) {
                Add-Advice '建议' ("系统盘剩余 {0} GB（{1}%）—— 有点紧张" -f $freeGB, $pct) '建议去「垃圾清理」页清一次。固态硬盘最好保持 20% 以上的空闲空间，写入性能才不会下降。'
            } else {
                Add-Advice '良好' ("系统盘剩余 {0} GB（{1}%）—— 空间充裕" -f $freeGB, $pct) '空间没问题。定期跑一下垃圾清理保持即可。'
            }
        }

        # ===== 5. 显卡驱动新旧 =====
        # 双显卡的笔记本/台式机上，真正跑游戏的是独显。核显驱动通常跟着
        # 厂商包走、更新很慢，为它报警是噪音。所以：只要检测到独显，
        # 就只看独显的驱动日期。
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|Parsec|Meta|IDD|Mirage' })
        $discrete = @($gpus | Where-Object { $_.Name -match 'GeForce|Radeon RX|Radeon Pro|Quadro|Arc A|Arc B|Titan' })
        if ($discrete.Count -gt 0) { $gpus = $discrete }

        foreach ($g in $gpus) {
            if (-not $g.DriverDate) { continue }
            $age = ((Get-Date) - $g.DriverDate).Days
            if ($age -gt 540) {
                Add-Advice '严重' ("显卡驱动太旧了：{0}（{1}，已经 {2} 天）" -f $g.Name, $g.DriverDate.ToString('yyyy-MM-dd'), $age) @'
显卡驱动是**对游戏帧数影响最直接的软件因素**，没有之一。

新游戏发售时，NVIDIA / AMD 往往会专门发一版针对它优化的驱动，
帧数差距可以有 10%~30%。用两年前的驱动跑新游戏，
等于白白扔掉一部分性能，还容易出现闪退和图形错误。

怎么更新（选一个）：
· NVIDIA 显卡：官网下载「GeForce Experience」，或者直接去
  nvidia.cn 驱动下载页手动下
· AMD 显卡：amd.com 下载「AMD Software: Adrenalin Edition」
· 笔记本：优先去笔记本厂商官网（联想/戴尔/华硕）下载，
  它们的定制驱动对笔记本的双显卡切换兼容性更好

更新完记得来「垃圾清理」页清一次「显卡着色器缓存」。
'@
            } elseif ($age -gt 240) {
                Add-Advice '建议' ("显卡驱动有点旧：{0}（{1}）" -f $g.Name, $g.DriverDate.ToString('yyyy-MM-dd')) '建议更新一下显卡驱动，通常能白捡几帧。更新完记得清一次着色器缓存。'
            }
        }

        # ===== 6. 电源计划 =====
        $cur = Invoke-Native 'powercfg.exe' @('/getactivescheme')
        if ($cur -notmatch '高性能|卓越|High performance|Ultimate') {
            Add-Advice '建议' '当前电源计划是「平衡」—— 打游戏建议切到高性能' '去「性能优化」页勾第一项「电源计划改为高性能/卓越性能」。这一项对老机器和笔记本效果尤其明显，能明显减少「突然卡一下」。'
        }

        # ===== 7. Game DVR =====
        $dvr = Get-RegValue -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'
        if ($null -eq $dvr -or $dvr -ne 0) {
            Add-Advice '建议' 'Xbox 后台录制（Game DVR）还开着 —— 正在白白吃掉你的帧数' '这个功能会在你玩游戏时一直在后台录屏，实测能吃掉 3%~10% 的帧数，而且绝大多数人从来不用它。去「性能优化」页勾「关闭 Xbox 后台录制」。'
        }

        # ===== 8. 腾讯 ACE 反作弊兼容性（无畏契约国服 / 三角洲行动） =====
        $vz = Get-VirtualizationState
        $aceProblems = @()
        if ($vz.Hvci   -eq $true)  { $aceProblems += '· 内存完整性(HVCI) 开着 —— 去「性能优化 → 安全性权衡」勾「关闭内核隔离」' }
        if ($vz.HyperV -eq $true)  { $aceProblems += '· Hyper-V 正在运行 —— 去「性能优化 → 安全性权衡」勾「关闭 Hyper-V 虚拟化层」' }
        if ($vz.Firmware -eq $false) { $aceProblems += '· BIOS 里的 CPU 虚拟化没开 —— 开机按 Del/F2 进 BIOS，Intel 打开 VT-x，AMD 打开 SVM Mode' }
        if ($vz.Iommu    -eq $false) { $aceProblems += '· BIOS 里的 DMA 保护没开 —— 同上进 BIOS，Intel 打开 VT-d，AMD 打开 IOMMU' }

        if ($aceProblems.Count -gt 0) {
            Add-Advice '严重' '腾讯 ACE 反作弊环境不达标 —— 无畏契约国服 / 三角洲行动可能进不去游戏' (@"
无畏契约【国服】和三角洲行动都用腾讯 ACE 反作弊。ACE 要独占 CPU
虚拟化来对抗 DMA 硬件外挂，所以它的要求是两个相反的方向：

    BIOS 里  →  虚拟化要【开】（Intel: VT-x + VT-d / AMD: SVM + IOMMU）
    Windows 里 → 内存完整性、Hyper-V 要【关】

不满足就弹「CPU虚拟化未开启或被其他软件占用」，游戏根本起不来。
这是官方文档写明的要求，不是玄学。

检测到这台机器还差这些：

$($aceProblems -join "`r`n")

顺带一提：把内存完整性关掉，CS2 也会受益 —— 第三方实测平均帧数
约 +25 帧，是单项收益最大的 Windows 设置。三个游戏都是正收益。

⚠ 唯一例外：【国际服】Valorant 用 Riot 的 Vanguard，要求正好相反
（必须开着内存完整性）。真要玩国际服，把那一项单独还原即可。
"@)
        } else {
            Add-Advice '良好' '腾讯 ACE 反作弊环境正常 —— 无畏契约国服 / 三角洲行动没有虚拟化方面的启动障碍' 'BIOS 虚拟化已开、内存完整性和 Hyper-V 已关，符合 ACE 要求。CS2 也同时受益于内存完整性关闭（实测约 +25 帧）。'
        }

        # ===== 8b. 显示器刷新率（FPS 玩家最该升级的硬件） =====
        $disp = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                  Where-Object { $_.CurrentRefreshRate -gt 0 } | Select-Object -First 1)
        if ($disp.Count -gt 0) {
            $hz = [int]$disp[0].CurrentRefreshRate
            if ($hz -le 65) {
                Add-Advice '严重' ("显示器现在只有 {0}Hz —— 对 FPS 玩家这是最大的短板" -f $hz) @'
这一条比这个工具里所有软件优化加起来都重要。

60Hz 意味着不管你游戏里跑到 300 帧还是 600 帧，
**你的眼睛每秒只能看到 60 张画面**，中间那些帧全被丢掉了。
对 CS2、无畏契约这种靠拉枪和预瞄的游戏，这是实打实的信息劣势：
· 60Hz → 144Hz：甩枪时画面连贯性的差距是压倒性的，
  第一次用过就回不去
· 144Hz → 240Hz：还有提升，但边际效应明显小了

现在 24 寸 180Hz 的电竞屏只要六七百块，是 FPS 玩家性价比最高的
一笔投入，远超换显卡。

另外确认一下：有些人买了高刷屏但**忘了在系统里切换刷新率**，
默认还跑在 60Hz。检查方法：
设置 → 系统 → 显示 → 高级显示设置 → 选择刷新率 → 调到最高。
（也要确认线材：HDMI 2.0 以下带不动 1080p 144Hz 以上，用 DP 线更稳）
'@
            } elseif ($hz -lt 100) {
                Add-Advice '建议' ("显示器当前刷新率 {0}Hz —— 确认一下是不是没调到最高" -f $hz) '如果你的显示器本身支持更高刷新率，去「设置 → 系统 → 显示 → 高级显示设置 → 选择刷新率」调到最高。有不少人买了高刷屏却一直跑在默认的低刷新率上。'
            } else {
                Add-Advice '良好' ("显示器刷新率 {0}Hz —— 没问题" -f $hz) '高刷新率已经正确启用了。'
            }
        }

        # ===== 8c. FPS 玩家的通用提醒 =====
        Add-Advice '建议' 'FPS 玩家还有三件事，工具改不了但收益比注册表大' @'
1. 鼠标回报率调到 1000Hz
   在鼠标自带驱动里设（罗技 G HUB / 雷蛇 Synapse / 无线鼠标的接收器）。
   很多鼠标默认只有 125Hz，光这一项就是 8ms 和 1ms 的差距。
   注意：8000Hz 不一定更好，它会明显增加 CPU 占用，
   老 CPU 上反而掉帧，1000Hz 是稳妥的甜点。

2. 游戏里开「原始输入 Raw Input」
   CS2、无畏契约、三角洲都有这个选项。
   它让游戏直接读鼠标数据，绕过 Windows 的指针加工。
   和本工具的「关闭鼠标加速」是配套的，两个都要做才干净。

3. 显卡驱动里开低延迟模式
   · N 卡：NVIDIA 控制面板 → 管理 3D 设置 → 低延迟模式 → 「超高」
     支持 Reflex 的游戏（无畏契约、CS2）直接在游戏里开 Reflex 更好
   · A 卡：Adrenalin → 游戏 → Anti-Lag
   这一项对「开枪到画面响应」的延迟影响，比大部分注册表优化都大。
'@

        # ===== 9. 开机启动项数量 =====
        try {
            $su = @(Get-StartupItems | Where-Object { $_.Enabled })
            if ($su.Count -ge 8) {
                Add-Advice '建议' ("开机自启的程序有 {0} 个 —— 建议精简" -f $su.Count) @'
每一个开机启动项都会抢开机时的 CPU 和硬盘，启动项多的机器
「开机到能用」的时间可以差好几倍。

去「启动项管理」页看一眼。常见的可以关掉的：
· 各种「XX 管家」「XX 安全卫士」「XX 加速器」
· 网易云音乐、QQ音乐、爱奇艺、迅雷
· Steam / Epic / 战网（要玩的时候再开就行）
· Adobe / 网易 / 腾讯的各种 Updater 更新检查器
· 打印机、扫描仪的厂商管理程序

不建议关的：
· 输入法、显卡控制面板、声卡驱动、触控板驱动
· 杀毒软件的实时防护
· 你天天要用的通讯软件（微信、QQ、钉钉）
'@
            }
        } catch { }

        # ===== 10. 虚拟内存被关掉 =====
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if ($pf.Count -eq 0) {
            Add-Advice '严重' '虚拟内存（页面文件）被关闭了 —— 强烈建议开回来' @'
网上有种说法是「内存大就可以关虚拟内存提速」，这是**错的**。

关掉虚拟内存之后：
· 部分游戏和软件会直接报「内存不足」打不开，哪怕你内存还剩很多
  （很多程序会预先申请一大块虚拟地址空间，不管实际用不用）
· 系统崩溃时无法生成转储文件，蓝屏都查不出原因
· 内存一旦真的用满，直接就是程序崩溃，没有缓冲

正确做法：设置 → 系统 → 关于 → 高级系统设置 → 性能「设置」→
高级 → 虚拟内存「更改」→ 勾上「自动管理所有驱动器的分页文件
大小」。交给系统管就对了。
'@
        }

        # ===== 11. 太久没真正重启 =====
        $bi = Get-BootInfo
        if ($bi.TrueUp -and $bi.TrueUp.Days -ge 7) {
            if ($bi.FastStartup) {
                Add-Advice '建议' ("距上次真正重启已经 {0} 天了（哪怕你天天关机也一样）" -f $bi.TrueUp.Days) @"
【先解释一个看起来见了鬼的现象】
你可能刚按电源键开机，工具却说「已经 $($bi.TrueUp.Days) 天」。这不是算错了。

因为你的「快速启动」是开着的，而它的真相是：
**你点「关机」的时候，Windows 并没有真的关机** ——
它把系统内核的状态休眠到硬盘上，下次开机直接读回来，所以显得快。

也就是说：你的电脑可能**好几个月没有真正重启过了**，
哪怕你每天都规规矩矩地关机。

【这会带来什么】
· 显卡驱动更新了却不生效，必须手动点「重启」才行
· 关机再开机问题还在，点「重启」问题就没了
· 外接设备（网卡、声卡、USB）关机再开就不认了
· 内存碎片和句柄泄漏一直累积，越用越卡
· 双系统用户：Windows 关机后 Linux 读不了硬盘（分区被锁）

【怎么办】
· 应急：点开始菜单 →「重启」（不是「关机」），这才是真重启
· 根治：去「性能优化 → 开机与响应」勾「关闭快速启动」，
  之后点关机就是真关机了。代价是开机慢 3~10 秒（固态上几乎无感）。
"@
            } else {
                Add-Advice '建议' ("已经连续开机 {0} 天没重启过了" -f $bi.TrueUp.Days) @'
长时间不重启会积累内存碎片和句柄泄漏，表现为「用着用着就变卡，
重启一下就好了」。建议每周至少重启一次。

你的快速启动已经关了，所以点「关机」就是真关机，不用额外操作。
'@
            }
        }

        # ===== 12. 老机器的物理保养提醒 =====
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        if ($bios -and $bios.ReleaseDate) {
            $ageY = [math]::Round(((Get-Date) - $bios.ReleaseDate).Days / 365.0, 1)
            if ($ageY -ge 3) {
                Add-Advice '建议' ("这台机器大约有 {0} 年了 —— 该清灰换硅脂了" -f $ageY) @'
这一条不是软件能解决的，但对老机器来说**往往是最大的性能问题**。

散热器积灰 + 硅脂干掉之后，CPU/显卡温度上去，触发温度墙就会
自动降频保护。表现是：
· 刚开始玩很流畅，打十几分钟就开始卡、帧数腰斩
· 风扇声音很大但机器还是烫
· 笔记本键盘烫手

这种「打一会儿就卡」的情况，改多少注册表都没用，
清灰换硅脂之后可能直接恢复到出厂性能。

怎么做：
· 台式机：拆开侧板，用吹风机冷风/气吹清散热器和风扇的灰，
  给 CPU 换一次硅脂。自己动手成本约 20 元。
· 笔记本：不熟悉的话别自己拆，送去维修店做「清灰换硅脂」，
  市场价 80~150 元，是老笔记本最值的一笔钱。

建议顺便装个温度监控软件（HWiNFO、AIDA64 都行）看看
打游戏时 CPU/显卡多少度。超过 90 度就说明散热确实该弄了。
'@
            }
        }

        # ===== 13. 系统版本过旧 =====
        if ($os -and $os.BuildNumber -and ([int]$os.BuildNumber) -lt 19041) {
            Add-Advice '建议' ("Windows 版本比较旧（内部版本 {0}）" -f $os.BuildNumber) 'Win10 2004（19041）之后微软对游戏调度、DirectX 12 做了不少优化，也修了很多性能相关的 bug。建议在「设置-更新和安全」里更新一下系统版本。'
        }

    } catch {
        Add-Advice '建议' '体检过程中出现错误' $_.Exception.Message
    }

    # 严重的排前面
    $order = @{ '严重' = 0; '建议' = 1; '良好' = 2 }
    return ($advice | Sort-Object { $order["$($_.Level)"] })
}

# =====================================================================
#  帧数瓶颈诊断
# ---------------------------------------------------------------------
#  这个功能是专门为了回答一句话做的：
#     「我按了一堆优化，帧数怎么一点没变？」
#
#  绝大多数情况下答案是下面三种之一：
#    1. 那些真正影响帧数的项，你这台机器上**本来就已经是最优的**
#       —— 那当然点了也不会变
#    2. 真正的瓶颈在**硬件或 BIOS 层面**（单通道内存、XMP 没开、
#       独显没启用、温度墙降频），软件优化碰不到
#    3. 你开的那些项，本来就只影响手感和后台占用，不影响平均帧数
#
#  所以这里不给「建议」，只摆事实：逐条报告每个跟帧数真正相关的
#  环节现在处于什么状态，是不是已经到顶了。
# =====================================================================
function Get-FpsDiagnosis {
    <#
      返回 @{ Level; Title; Text }
      Level：'瓶颈' = 找到了限制帧数的因素
             '待优化' = 还有提升空间
             '已到顶' = 这一环已经最优，点了也不会变
             '信息'   = 参考信息
    #>
    $out = New-Object System.Collections.ArrayList
    function Add-Diag { param($lv, $t, $x) [void]$out.Add([PSCustomObject]@{ Level = $lv; Title = $t; Text = $x }) }

    # ---------------------------------------------------------------
    #  一、内存：双通道 / XMP —— 最常见、最被忽略的帧数瓶颈
    # ---------------------------------------------------------------
    try {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($sticks.Count -eq 1) {
            Add-Diag '瓶颈' '内存是单通道 —— 游戏里直接损失 10%~25% 帧数' @'
你只插了一条内存。

【为什么这件事对帧数影响这么大】
CPU 和内存之间的带宽是双通道的一半。游戏是内存带宽大户，
尤其是 CPU 端的处理（物理、AI、绘制指令准备）。
带宽不够，CPU 就得等内存，帧数直接被拖住。

**如果你的机器用的是核显，影响还要翻倍** —— 核显没有独立显存，
完全靠内存带宽吃饭，单通道能让核显性能腰斩。

【实测量级】
· 独显机器：游戏平均帧数差 10%~25%，1% Low 差更多
· 核显机器：差 30%~80%（基本等于换了张显卡）

【怎么解决】
再加一条**同规格**的内存，插在正确的插槽里。
主板上通常是 A1/A2/B1/B2 四个槽，两条内存要插
**隔一个的那两个**（一般是 A2 + B2），插错了还是单通道。
主板说明书上会写，或者看主板上的丝印。

★ 这是软件优化完全碰不到的东西。你把本工具里所有开关
   全打开，也补不回单通道损失的这部分帧数。★
'@
        } elseif ($sticks.Count -ge 2) {
            Add-Diag '已到顶' ('内存是双通道（{0} 条）—— 这一项已经最优' -f $sticks.Count) `
                '带宽这一环没问题，不用管了。'
        }

        # XMP / DOCP：标称频率 vs 实际运行频率
        foreach ($s in ($sticks | Select-Object -First 1)) {
            $rated  = [int]$s.Speed              # 内存条本身支持的频率
            $actual = [int]$s.ConfiguredClockSpeed  # 实际在跑的频率
            if ($rated -gt 0 -and $actual -gt 0 -and $actual -lt ($rated - 50)) {
                Add-Diag '瓶颈' ('内存没跑满速 —— 标称 {0} MHz，实际只有 {1} MHz（XMP/DOCP 没开）' -f $rated, $actual) @"
你的内存条支持 $rated MHz，但现在只跑在 $actual MHz。

【为什么】
内存出厂默认按最保守的频率跑（通常 2133 或 2400），
要跑到标称频率必须在 BIOS 里手动打开一个开关：
· Intel 主板叫 **XMP**
· AMD 主板叫 **DOCP** 或 **EXPO**

**买了高频内存但没开 XMP，等于白买。** 这是装机最常见的疏漏，
很多品牌整机出厂就是没开的状态。

【影响多大】
从 $actual MHz 提到 $rated MHz，游戏帧数一般能涨 5%~15%，
1% Low（卡顿）改善更明显。AMD 平台对内存频率尤其敏感。

【怎么开】
开机按 Del 或 F2 进 BIOS →
找到 XMP / DOCP / EXPO 选项（一般在首页或超频页）→
选 Profile 1 → F10 保存重启。

如果开了之后开不了机：断电、扣主板电池放电，或者用
主板上的 CLR_CMOS 针脚清空 BIOS，就能恢复。
清完再进去选低一档的 Profile。

★ 同样是软件改不了的，必须进 BIOS。★
"@
            } elseif ($rated -gt 0 -and $actual -ge ($rated - 50)) {
                Add-Diag '已到顶' ('内存跑在标称频率 {0} MHz —— XMP/DOCP 已经开了' -f $actual) `
                    '这一项没有提升空间了。'
            }
        }
    } catch { }

    # ---------------------------------------------------------------
    #  二、CPU 当前频率 vs 标称 —— 判断是不是在降频
    # ---------------------------------------------------------------
    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)[0]
        if ($cpu -and $cpu.MaxClockSpeed -gt 0) {
            $pct = [math]::Round($cpu.CurrentClockSpeed / $cpu.MaxClockSpeed * 100)
            if ($pct -lt 60) {
                Add-Diag '瓶颈' ('CPU 正跑在标称频率的 {0}%（{1} / {2} MHz）—— 有降频' -f $pct, $cpu.CurrentClockSpeed, $cpu.MaxClockSpeed) @"
当前读数：$($cpu.CurrentClockSpeed) MHz，标称 $($cpu.MaxClockSpeed) MHz。

【注意：这个读数要会看】
空闲时 CPU 本来就会降频省电，所以**现在读到低频不一定是问题**。
判断方法：让机器跑起来（开个游戏或者跑个压力测试），
再回来点一次「重新诊断」。如果满载时还是上不去，那才是真问题。

【满载还上不去，常见原因】
1. **散热到墙了** —— 灰堵了、硅脂干了。笔记本用两三年基本都这样。
   清灰 + 换硅脂，成本几十块，效果常常比所有软件优化加起来都大。
2. **电源计划没给够** —— 本工具「性能优化」页有「电源计划改为高性能」
   和「电源细节调优」两项，先把这两个开了。
3. **笔记本在用电池** —— 拔了电池供电的性能限制非常狠，见下一条。
4. **厂商的性能模式没开** —— 联想/ROG/惠普 那些自带软件里
   一般有「野兽模式 / 性能模式」，那个优先级比 Windows 电源计划高。
"@
            } else {
                Add-Diag '信息' ('CPU 当前频率 {0} MHz / 标称 {1} MHz（{2}%）' -f $cpu.CurrentClockSpeed, $cpu.MaxClockSpeed, $pct) `
                    '空闲时降频是正常的。要判断有没有温度墙，得在游戏跑起来的时候看。'
            }
        }
    } catch { }

    # ---------------------------------------------------------------
    #  三、笔记本：在用电池 = 性能被砍掉一大半
    # ---------------------------------------------------------------
    try {
        if (Test-IsLaptop) {
            $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)[0]
            # BatteryStatus: 2 = 接了电源
            if ($bat -and $bat.BatteryStatus -ne 2) {
                Add-Diag '瓶颈' '笔记本现在用的是电池 —— 性能被大幅限制' @'
用电池的时候，笔记本会主动限制 CPU 和显卡的功耗墙，
帧数掉一半是很常见的，有些机器独显干脆直接不给满速。

**玩游戏一定要插电源。** 这一条比本工具里任何一个开关都管用。

另外注意：有些笔记本的原装电源功率不够，插着也会限性能 ——
用 65W 的 Type-C 充电器带 150W 的游戏本就是这种情况，
必须用原装的那块大砖头。
'@
            } elseif ($bat) {
                Add-Diag '已到顶' '笔记本已接通电源 —— 没有电池限速' '这一项没问题。'
            }
        }
    } catch { }

    # ---------------------------------------------------------------
    #  四、双显卡：独显到底有没有在干活
    # ---------------------------------------------------------------
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|IDD|Mirage|Parsec' })
        $dGpu = @($gpus | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc' })
        $iGpu = @($gpus | Where-Object { $_.Name -match 'Intel.*(UHD|HD Graphics|Iris)|AMD.*Radeon\(TM\) Graphics|Vega.*Graphics' })

        if ($dGpu.Count -ge 1 -and $iGpu.Count -ge 1) {
            Add-Diag '待优化' ('这台机器有两块显卡：{0}（核显） + {1}（独显）' -f $iGpu[0].Name, $dGpu[0].Name) @"
双显卡机器最经典的「帧数上不去」原因，就是
**游戏其实跑在核显上，独显在旁边闲着**。

【怎么确认】
开着游戏，按 Ctrl+Shift+Esc 打开任务管理器 → 性能页 →
看 GPU 0 / GPU 1 哪个在动。如果动的是核显那个，就是跑错了。
（或者在游戏里开帧数显示，看它报的显卡型号是哪块。）

【怎么强制用独显】
方法一（推荐，Windows 自带）：
  设置 → 系统 → 显示 → 显卡 → 找到游戏的 exe →
  选项 → 选「高性能」→ 保存

方法二（N 卡驱动）：
  NVIDIA 控制面板 → 管理 3D 设置 → 程序设置 →
  选游戏 → 首选图形处理器 → 高性能 NVIDIA 处理器

方法三（台式机专属，最容易踩的坑）：
  **显示器的线插在主板上而不是显卡上。**
  台式机的视频线一定要插在**显卡**的接口上
  （机箱后面靠下、和显卡在一起的那几个口），
  插主板上的口走的就是核显。

【台式机还有一种情况】
BIOS 里核显没关。进 BIOS 把集成显卡设成 Disabled 或
把主显示设备设成 PCIE，能彻底避免这个问题。
"@
        } elseif ($dGpu.Count -ge 1) {
            Add-Diag '已到顶' ('独立显卡：{0}' -f $dGpu[0].Name) '只有一块独显，不存在跑错显卡的问题。'
        } elseif ($iGpu.Count -ge 1 -and $dGpu.Count -eq 0) {
            Add-Diag '瓶颈' ('这台机器只有核显：{0}' -f $iGpu[0].Name) @'
没有独立显卡，游戏画面完全靠 CPU 里集成的那块核显来渲染。

【这就是帧数上不去的根本原因】
核显的性能和入门独显都差一大截。任何软件优化都不可能
把核显变成独显 —— **本工具能帮你榨出的那点性能，
和换一块独显的差距不是一个量级。**

【核显机器唯一真正有效的两件事】
1. **确保内存是双通道**（见上面那一条）。核显没有独立显存，
   全靠内存带宽，单通道变双通道能让核显性能接近翻倍。
   这是核显机器性价比最高的升级，一条内存的钱。
2. **游戏内分辨率和画质往下调**。核显吃不下高分辨率。

【显卡驱动里还能分点显存】
BIOS 里通常可以调「显存共享大小 / UMA Frame Buffer」，
内存够的话给核显多分一点（比如 2GB）有时有用。
'@
        }

        # 显卡驱动新旧
        foreach ($g in ($dGpu | Select-Object -First 1)) {
            if ($g.DriverDate) {
                $age = (New-TimeSpan -Start $g.DriverDate -End (Get-Date)).Days
                if ($age -gt 540) {
                    Add-Diag '待优化' ('显卡驱动是 {0} 的，已经 {1} 天没更新了' -f $g.DriverDate.ToString('yyyy-MM-dd'), $age) @'
显卡驱动对游戏帧数的影响比大多数人想的大得多。
新游戏发售时，N 卡 / A 卡都会出针对性的驱动，
同一张卡新驱动比老驱动多 10%~30% 帧数的情况并不罕见。

【怎么更新】
· N 卡：nvidia.cn 官网下载，或用 GeForce Experience
· A 卡：amd.com 官网下载 Adrenalin

**不要用第三方驱动工具（驱动精灵那一类）装显卡驱动**，
它们经常给你装成老版本或者魔改版。去官网下。

装的时候建议勾「执行清洁安装」，能避免老驱动残留导致的问题。
'@
                } else {
                    Add-Diag '已到顶' ('显卡驱动 {0}（{1} 天内）—— 不算旧' -f $g.DriverVersion, $age) '这一项没问题。'
                }
            }
        }
    } catch { }

    # ---------------------------------------------------------------
    #  五、真正影响帧数的优化项，现在各自是什么状态
    # ---------------------------------------------------------------
    try {
        # 只列「确实能动平均帧数」的那几项，不列手感类的
        $fpsItems = @(
            @{ Id = 'SpectreMitigations'; Why = '老 CPU 上影响最大的一项，5%~30%' }
            @{ Id = 'VBS';                Why = 'CS2 实测能差 10%~25%' }
            @{ Id = 'GameDVR';            Why = '后台录制会持续吃 5%~10% 帧数' }
            @{ Id = 'PowerPlan';          Why = '省电模式下 CPU 不给满频' }
            @{ Id = 'GpuMsiMode';         Why = '改善帧生成一致性（不提升平均帧）' }
            @{ Id = 'HAGS';               Why = '有的机器涨、有的掉，要实测' }
        )
        $all = Get-AllTweaks
        $done = New-Object System.Collections.ArrayList
        $todo = New-Object System.Collections.ArrayList
        foreach ($it in $fpsItems) {
            $tw = $all | Where-Object { $_.Id -eq $it.Id } | Select-Object -First 1
            if (-not $tw) { continue }
            $applied = $false
            try { $applied = [bool](Test-TweakApplied $tw) } catch { }
            if ($applied) { [void]$done.Add(('· {0}   —— 已是最优（{1}）' -f $tw.Name, $it.Why)) }
            else          { [void]$todo.Add(('· {0}   —— 还没开（{1}）' -f $tw.Name, $it.Why)) }
        }

        if ($todo.Count -gt 0) {
            Add-Diag '待优化' ('还有 {0} 项「真能影响帧数」的没开' -f $todo.Count) (@"
下面这几项是本工具里**真正能改变平均帧数**的，目前还没开：

$($todo -join "`r`n")

去「性能优化」页把它们打开。注意每一项的说明里都写了代价，
「激进优化」那一组尤其要看完再决定。
"@)
        }
        if ($done.Count -gt 0) {
            Add-Diag '已到顶' ('有 {0} 项「真能影响帧数」的已经是最优状态' -f $done.Count) (@"
$($done -join "`r`n")

★ 这一条很可能就是「点了一堆优化但帧数没变」的答案。★

这些项在你这台机器上**本来就已经是最优的**（有的是系统默认，
有的是显卡驱动或厂商软件已经设好了）—— 你点不点它，
状态都一样，所以帧数当然不会变。

想再往上走，得看上面那几条硬件/BIOS 层面的结论。
"@)
        }
    } catch { }

    # ---------------------------------------------------------------
    #  六、其余「不影响平均帧数」的优化项 —— 说清楚免得误会
    # ---------------------------------------------------------------
    Add-Diag '信息' '为什么大部分优化项「感觉没用」？' @'
这个要说实话：**本工具里大多数开关，本来就不是用来涨平均帧数的。**

它们分三种，效果完全不同：

【第一种：影响平均帧数】—— 就是上面单独列出来的那几项。
   这些开了才会在帧数显示上看到数字变化。全工具里也就五六条。

【第二种：影响「手感」，不影响平均帧数】
   比如取消菜单延迟、鼠标加速、网络 Nagle 算法、MMCSS 优先级。
   这些改的是**延迟**和**帧生成时间的一致性**。
   表现是「跟手了」「不一顿一顿了」，但帧数计那个数字不动。
   你要是只盯着帧数看，会觉得它们全都没用 —— 其实不是没用，
   是它们本来就不改那个数字。

【第三种：省资源、省空间、少打扰】
   关后台服务、清垃圾、关广告推送、浏览器瘦身。
   这些让机器整体不那么卡、内存不那么满，
   跟游戏内帧数基本无关。

★ 所以正确的预期是：★
  如果你的目标是「帧数数字变大」，重点看上面那几条硬件结论
  （单通道内存、XMP、独显没启用、温度墙），
  以及「真能影响帧数」那一组开关。
  其余的开着有好处，但别指望它们让帧数涨。
'@

    # 瓶颈排前面，已到顶的排后面
    $order = @{ '瓶颈' = 0; '待优化' = 1; '信息' = 2; '已到顶' = 3 }
    return ($out | Sort-Object { $order["$($_.Level)"] })
}
