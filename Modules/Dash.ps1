<#
=====================================================================
  Dash.ps1  ——  「概览」仪表盘的数据层
---------------------------------------------------------------------
  数据来自 LibreHardwareMonitorLib（MPL-2.0，放在 Lib\ 下）。

  ★ 为什么用这个库，而不是自己拿 WMI / nvidia-smi 拼 ★
    一开始我是打算自己拼的，结果是：
      · CPU 温度：WMI 的 MSAcpi_ThermalZoneTemperature 在绝大多数
        机器上返回空（这台就读不到），等于没有
      · GPU：只能靠 nvidia-smi，**A 卡和核显完全没辙**
      · 每核频率、功耗、风扇转速：拿不到
    换成这个库之后，上面全部能读，而且一次全量刷新只要 70ms 左右。

  ★ 它需要管理员权限 ★
    正好——本工具本来就是提权运行的。非管理员时会自动退回
    「只有占用率、没有温度」的降级模式，而不是报错或者编数据。

  ★ 绝不编数据 ★
    读不到就显示「—」。温度这种东西编一个看着像样的数字出来，
    用户会照着它判断要不要清灰、要不要换硅脂 —— 那是害人。
=====================================================================
#>

$Script:DashHistoryLen = 60          # 波形图保留多少个采样点
$Script:DashHistory = @{ CPU = $null; GPU = $null; RAM = $null }
$Script:LhmComputer = $null
$Script:LhmReady = $false
$Script:LhmError = $null
$Script:DashCpuCounter = $null       # 降级模式用
$Script:DashTick = 0
$Script:DashCacheDisk = $null

function Initialize-Dash {
    <#
      开一次硬件监控。Open() 要枚举全部硬件，比较慢（几百毫秒到两秒），
      所以只在启动时做一次，之后每次刷新只调 Update()。
    #>
    foreach ($k in 'CPU', 'GPU', 'RAM') {
        $Script:DashHistory[$k] = New-Object System.Collections.ArrayList
    }

    try {
        $root = Split-Path -Parent $PSScriptRoot
        # HidSharp 必须先于主库加载，否则主库会报「无法加载一个或多个请求的类型」
        Add-Type -Path (Join-Path $root 'Lib\HidSharp.dll') -ErrorAction Stop
        Add-Type -Path (Join-Path $root 'Lib\LibreHardwareMonitorLib.dll') -ErrorAction Stop

        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true
        $c.IsGpuEnabled = $true
        $c.IsMemoryEnabled = $true
        $c.IsMotherboardEnabled = $true      # 风扇转速在主板上
        $c.IsStorageEnabled = $false         # 硬盘温度用不上，还会拖慢 Open
        $c.Open()
        $Script:LhmComputer = $c
        $Script:LhmReady = $true
        Write-Log '硬件监控已就绪（可读温度 / 风扇 / 各核心频率）' '信息'
    } catch {
        $Script:LhmReady = $false
        $Script:LhmError = "$($_.Exception.Message)"
        Write-Log "硬件监控不可用，退回基础模式（只有占用率、没有温度）：$Script:LhmError" '警告'
    }

    # CPU 占用率的主力来源（不再是降级用的）——
    # 和任务管理器同一个计数器，数字对得上，而且不需要管理员权限。
    # 注意 PerformanceCounter 第一次 NextValue() 恒为 0，先读一次丢掉。
    try {
        $Script:DashCpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
        $null = $Script:DashCpuCounter.NextValue()
    } catch { $Script:DashCpuCounter = $null }
}

function Close-Dash {
    try { if ($Script:LhmComputer) { $Script:LhmComputer.Close() } } catch { }
}

function Update-DashSensors {
    <# 让库重新采一遍。每秒调一次，实测约 70ms #>
    if (-not $Script:LhmReady) { return }
    try {
        foreach ($h in $Script:LhmComputer.Hardware) {
            $h.Update()
            foreach ($sh in $h.SubHardware) { $sh.Update() }
        }
    } catch { }
}

function Get-LhmSensors {
    <# 取某类硬件的全部传感器（含子硬件） #>
    param([string]$HwType)
    if (-not $Script:LhmReady) { return @() }
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($h in $Script:LhmComputer.Hardware) {
            if ("$($h.HardwareType)" -notlike "$HwType*") { continue }
            foreach ($s in $h.Sensors) { [void]$out.Add($s) }
            foreach ($sh in $h.SubHardware) { foreach ($s in $sh.Sensors) { [void]$out.Add($s) } }
        }
    } catch { }
    return $out
}

function Get-SensorValue {
    <#
      从一堆传感器里挑一个。
      NameLike 给多个时按顺序找，先命中的优先 ——
      因为不同平台的传感器命名不一样（AMD 叫 Tctl/Tdie，Intel 叫 CPU Package）。
    #>
    param($Sensors, [string]$Type, [string[]]$NameLike, [double]$Min = [double]::NegativeInfinity)
    foreach ($pat in $NameLike) {
        foreach ($s in $Sensors) {
            if ("$($s.SensorType)" -ne $Type) { continue }
            if ($null -eq $s.Value) { continue }
            if ("$($s.Name)" -notlike $pat) { continue }
            $v = [double]$s.Value
            # ★ 传感器读不到时不是 $null，是 0 或 NaN ★
            #   没管理员权限（内核驱动装不上）、或者这块硬件本来就没这个探头，
            #   LibreHardwareMonitor 返回的是 0 / NaN 而不是空。
            #   直接信它，界面上就会出现「处理器 0 °C」「NaN GHz」这种假数据 ——
            #   本工具的底线是「读不到就显示 —，绝不编数字」，所以在这里拦掉。
            if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { continue }
            if ($v -lt $Min) { continue }
            return $v
        }
    }
    return $null
}

function Get-DashCpu {
    <# @{ Load; Temp; Clock; Power; Name } —— 取不到的项是 $null #>
    $r = @{ Load = $null; Temp = $null; Clock = $null; Power = $null; Name = $null }

    if ($Script:LhmReady) {
        $s = Get-LhmSensors -HwType 'Cpu'
        try {
            $hw = $Script:LhmComputer.Hardware | Where-Object { "$($_.HardwareType)" -like 'Cpu*' } | Select-Object -First 1
            if ($hw) { $r.Name = "$($hw.Name)" }
        } catch { }
        # ★ 占用率不走 LibreHardwareMonitor ★
        #   实测（AMD 5900HX，无内核驱动时）：它把全部 16 个核心和
        #   「CPU Total」一律报成 100 —— 真实占用只有 17%。
        #   原因是它靠 MSR 时间戳算差值，驱动装不上时差值是垃圾，直接饱和。
        #   界面上显示「处理器 100%」而任务管理器显示 17%，
        #   用户第一反应是这软件在瞎编 —— 这正是本工具的底线。
        #   所以占用率一律用 Windows 性能计数器（和任务管理器同一个来源），
        #   LHM 只负责温度 / 频率 / 功耗这些确实需要驱动的项。
        #   （取值在下面的「降级」段里统一做。）
        # 温度：AMD 是 Tctl/Tdie，Intel 是 CPU Package
        $r.Temp = Get-SensorValue $s 'Temperature' @('Core (Tctl/Tdie)', 'CPU Package', 'Core Average', 'Core Max', '*Tctl*', '*Package*') -Min 1
        # 频率：取第一个核心的
        $r.Clock = Get-SensorValue $s 'Clock' @('Core #1', 'CPU Core #1', 'Core*') -Min 1
        # 功耗：整包
        $r.Power = Get-SensorValue $s 'Power' @('Package', 'CPU Package', 'CPU Cores') -Min 0.5
    }

    # 占用率：性能计数器优先（见上面的说明）
    if ($Script:DashCpuCounter) {
        try {
            $v = [math]::Round($Script:DashCpuCounter.NextValue())
            $r.Load = [math]::Max(0, [math]::Min(100, $v))
        } catch { }
    }
    # 性能计数器也拿不到（计数器库损坏的机器有过），才退回 LHM
    if ($null -eq $r.Load -and $Script:LhmReady) {
        $r.Load = Get-SensorValue (Get-LhmSensors -HwType 'Cpu') 'Load' @('CPU Total', 'Total')
    }
    if ($null -ne $r.Load) { $r.Load = [math]::Round($r.Load) }
    if ($null -ne $r.Temp) { $r.Temp = [math]::Round($r.Temp) }
    if ($null -ne $r.Clock) { $r.Clock = [math]::Round($r.Clock) }
    if ($null -ne $r.Power) { $r.Power = [math]::Round($r.Power) }
    return $r
}

function Get-DashGpu {
    <#
      @{ Name; Temp; Load; MemUsedMB; MemTotalMB; IsDedicated }

      有独显时优先报独显 —— 双显卡机器上用户关心的是那块独显，
      核显占用率对他没意义。
    #>
    $r = @{ Name = $null; Temp = $null; Load = $null; MemUsedMB = $null; MemTotalMB = $null; IsDedicated = $false }
    if (-not $Script:LhmReady) {
        # 降级：至少认出型号
        try {
            $g = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
                    Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|IDD|Mirage' })
            $d = $g | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc' } | Select-Object -First 1
            if (-not $d) { $d = $g | Select-Object -First 1 }
            if ($d) { $r.Name = "$($d.Name)" }
        } catch { }
        return $r
    }

    try {
        $gpus = @($Script:LhmComputer.Hardware | Where-Object { "$($_.HardwareType)" -like 'Gpu*' })
        if ($gpus.Count -eq 0) { return $r }
        # 挑独显：名字里有独显特征的优先
        $pick = $gpus | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc' } | Select-Object -First 1
        if ($pick) { $r.IsDedicated = $true } else { $pick = $gpus[0] }

        $r.Name = "$($pick.Name)"
        $s = New-Object System.Collections.ArrayList
        foreach ($x in $pick.Sensors) { [void]$s.Add($x) }
        foreach ($sh in $pick.SubHardware) { foreach ($x in $sh.Sensors) { [void]$s.Add($x) } }

        $r.Temp = Get-SensorValue $s 'Temperature' @('GPU Core', 'GPU Hot Spot', 'GPU*') -Min 1
        $r.Load = Get-SensorValue $s 'Load' @('GPU Core', 'D3D 3D', 'GPU*')
        $r.MemUsedMB = Get-SensorValue $s 'SmallData' @('GPU Memory Used', 'D3D Dedicated Memory Used') -Min 1
        $r.MemTotalMB = Get-SensorValue $s 'SmallData' @('GPU Memory Total') -Min 1
    } catch { }

    foreach ($k in 'Temp', 'Load', 'MemUsedMB', 'MemTotalMB') {
        if ($null -ne $r[$k]) { $r[$k] = [math]::Round($r[$k]) }
    }
    return $r
}

function Get-DashRam {
    <# @{ Percent; UsedGB; TotalGB } #>
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalKB = [double]$os.TotalVisibleMemorySize
        $freeKB = [double]$os.FreePhysicalMemory
        if ($totalKB -le 0) { return $null }
        return @{
            Percent = [math]::Round((1 - ($freeKB / $totalKB)) * 100)
            UsedGB  = [math]::Round((($totalKB - $freeKB) * 1KB) / 1GB, 1)
            TotalGB = [math]::Round(($totalKB * 1KB) / 1GB, 1)
        }
    } catch { return $null }
}

function Get-DashFan {
    <# 最快的那个风扇转速。很多笔记本读不到，读不到就返回 $null #>
    if (-not $Script:LhmReady) { return $null }
    try {
        $s = Get-LhmSensors -HwType 'Motherboard'
        $s += Get-LhmSensors -HwType 'SuperIO'
        $max = $null
        foreach ($x in $s) {
            if ("$($x.SensorType)" -ne 'Fan') { continue }
            if ($null -eq $x.Value -or $x.Value -le 0) { continue }
            $v = [math]::Round([double]$x.Value)
            if ($null -eq $max -or $v -gt $max) { $max = $v }
        }
        return $max
    } catch { return $null }
}

function Get-DashDisk {
    <# 系统盘剩余。容量变化很慢，30 秒取一次足够 #>
    if ($Script:DashCacheDisk -and ($Script:DashTick % 30) -ne 0) { return $Script:DashCacheDisk }
    $r = $null
    try {
        $sys = $env:SystemDrive
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sys'" -ErrorAction Stop
        if ($d -and $d.Size -gt 0) {
            $r = @{
                Drive   = $sys
                FreeGB  = [math]::Round($d.FreeSpace / 1GB, 1)
                TotalGB = [math]::Round($d.Size / 1GB, 1)
                UsedPct = [math]::Round((1 - ($d.FreeSpace / $d.Size)) * 100)
            }
        }
    } catch { }
    $Script:DashCacheDisk = $r
    return $r
}

function Add-DashSample {
    <# 往波形图历史里塞一个点，超长丢掉最旧的 #>
    param([string]$Key, $Value)
    if ($null -eq $Value) { return }
    $h = $Script:DashHistory[$Key]
    if ($null -eq $h) { return }
    [void]$h.Add([double]$Value)
    while ($h.Count -gt $Script:DashHistoryLen) { $h.RemoveAt(0) }
}

function Get-DashScore {
    <#
      「健康度」—— 0~100 的分数。

      ★ 算法必须公开，不能是黑箱 ★
        市面上那些「一键体检 98 分」的软件，分数都是编的，
        目的是先吓你再卖你服务。这里每一分的扣法都写在返回值里，
        界面上可以展开看明细。

      返回 @{ Score; Items = @(@{ Name; Minus; Why }) }
    #>
    $items = New-Object System.Collections.ArrayList
    $score = 100

    try {
        $fpsIds = @('SpectreMitigations', 'VBS', 'GameDVR', 'PowerPlan', 'GpuMsiMode', 'HAGS')
        $all = Get-AllTweaks
        $notDone = 0
        foreach ($id in $fpsIds) {
            $tw = $all | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if (-not $tw) { continue }
            try { if (-not (Test-TweakApplied $tw)) { $notDone++ } } catch { }
        }
        if ($notDone -gt 0) {
            $m = $notDone * 4
            $score -= $m
            [void]$items.Add(@{ Name = "还有 $notDone 项能影响帧数的没开"; Minus = $m; Why = '每项扣 4 分。这几项是真能改变平均帧数的，不是手感类。' })
        }
    } catch { }

    try {
        $d = Get-DashDisk
        if ($d) {
            if ($d.FreeGB -lt 10) { $score -= 15; [void]$items.Add(@{ Name = "系统盘只剩 $($d.FreeGB) GB"; Minus = 15; Why = '低于 10 GB，Windows 会开始出各种毛病。' }) }
            elseif ($d.FreeGB -lt 30) { $score -= 8; [void]$items.Add(@{ Name = "系统盘只剩 $($d.FreeGB) GB"; Minus = 8; Why = '低于 30 GB，更新和游戏读图会受影响。' }) }
        }
    } catch { }

    try {
        $r = Get-DashRam
        if ($r -and $r.Percent -ge 85) {
            $score -= 10
            [void]$items.Add(@{ Name = "内存已用 $($r.Percent)%"; Minus = 10; Why = '超过 85% 系统开始往硬盘倒数据，那一下就是明显卡顿。' })
        }
    } catch { }

    # 温度：这一项只有读得到温度时才参与打分
    try {
        $c = Get-DashCpu
        if ($null -ne $c.Temp) {
            if ($c.Temp -ge 95) { $score -= 15; [void]$items.Add(@{ Name = "CPU 温度 $($c.Temp)°C"; Minus = 15; Why = '已经在撞温度墙了，性能被硬压。清灰换硅脂比任何软件优化都管用。' }) }
            elseif ($c.Temp -ge 85) { $score -= 7; [void]$items.Add(@{ Name = "CPU 温度 $($c.Temp)°C"; Minus = 7; Why = '偏高。满载时容易触发降频，该考虑清灰了。' }) }
        }
    } catch { }

    try {
        $st = @(Get-StartupItems | Where-Object { $_.Enabled })
        if ($st.Count -ge 10) {
            $m = [math]::Min(12, ($st.Count - 9) * 2)
            $score -= $m
            [void]$items.Add(@{ Name = "$($st.Count) 个开机自启程序"; Minus = $m; Why = '超过 9 个开始明显拖慢开机，每多一个扣 2 分，最多扣 12 分。' })
        }
    } catch { }

    try {
        if (-not (Test-SystemDriveIsSSD)) {
            $score -= 20
            [void]$items.Add(@{ Name = '系统盘是机械硬盘'; Minus = 20; Why = '影响体验最大的一项，而且软件优化补不回来。换固态是性价比最高的升级。' })
        }
    } catch { }

    if ($score -lt 0) { $score = 0 }
    return @{ Score = [int]$score; Items = $items }
}
