<#
=====================================================================
  Engine.ps1  ——  底层引擎
---------------------------------------------------------------------
  职责：
    1) 日志（同时写文件和界面）
    2) 注册表读写 + 「原始值备份」
    3) 服务启停 + 「原始启动类型备份」
    4) 系统还原点
    5) 一些通用小工具

  ★ 核心设计原则 ★
    这个工具改任何东西之前，先把原来的值原封不动存进
    Backup\original-values.json。
    所以「还原」用的是你这台机器的真实原值，
    而不是网上抄来的、可能根本不适合你的所谓「默认值」。
    这也是它和那些改完就回不去的「优化大师」最大的区别。
=====================================================================
#>

# ---------- 全局状态 ----------
$Script:LogLines   = New-Object System.Collections.ArrayList
$Script:Backup     = @{}        # 备份仓库：键 = "REG|路径|名称" 或 "SVC|服务名" 或 "FLAG|优化项ID"
$Script:BackupFile = $null
$Script:LogFile    = $null
$Script:LogBox     = $null      # 界面上的日志框，由主程序赋值

function Initialize-Engine {
    <# 初始化：准备备份目录、日志文件，并把上次的备份读回内存 #>
    param([string]$RootPath)
    $Script:Root      = $RootPath
    $Script:BackupDir = Join-Path $RootPath 'Backup'
    if (-not (Test-Path -LiteralPath $Script:BackupDir)) {
        New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
    }
    $Script:BackupFile = Join-Path $Script:BackupDir 'original-values.json'
    $Script:LogFile    = Join-Path $Script:BackupDir ('log-{0}.txt' -f (Get-Date -Format 'yyyyMMdd'))
    Import-BackupStore
}

# =====================================================================
#  日志
# =====================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('信息','成功','警告','错误')][string]$Level = '信息'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    [void]$Script:LogLines.Add($line)
    try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($Script:LogBox) {
        try {
            $Script:LogBox.AppendText($line + [Environment]::NewLine)
            $Script:LogBox.ScrollToEnd()
        } catch { }
    }
}

# =====================================================================
#  备份仓库的存 / 取
# =====================================================================
function Import-BackupStore {
    $Script:Backup = @{}
    if (-not (Test-Path -LiteralPath $Script:BackupFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $Script:BackupFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $obj = $raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            $h = @{}
            foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }
            $Script:Backup[$p.Name] = $h
        }
    } catch {
        Write-Log "读取备份文件失败（不影响使用，但还原会退回默认值）：$($_.Exception.Message)" '警告'
    }
}

function Save-BackupStore {
    try {
        ($Script:Backup | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $Script:BackupFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "保存备份文件失败：$($_.Exception.Message)" '错误'
    }
}

# 非注册表类的优化项（比如电源计划、fsutil），用一个「已应用」标记来记住状态
function Set-TweakFlag {
    param([string]$Id, [bool]$On)
    $Script:Backup["FLAG|$Id"] = @{ Kind = 'Flag'; Id = $Id; On = $On }
    Save-BackupStore
}
function Get-TweakFlag {
    param([string]$Id)
    $k = "FLAG|$Id"
    if ($Script:Backup.ContainsKey($k)) { return [bool]$Script:Backup[$k].On }
    return $false
}

# 备忘条目：给需要记住「原来是什么」的非注册表设置用（例如原来的电源计划 GUID）
function Set-BackupNote {
    param([string]$Key, $Value)
    $Script:Backup["NOTE|$Key"] = @{ Kind = 'Note'; Key = $Key; Value = $Value }
    Save-BackupStore
}
function Get-BackupNote {
    param([string]$Key)
    $k = "NOTE|$Key"
    if ($Script:Backup.ContainsKey($k)) { return $Script:Backup[$k].Value }
    return $null
}

# =====================================================================
#  十六进制 <-> 字节数组（注册表二进制值在 JSON 里存成十六进制字符串）
# =====================================================================
function Convert-BytesToHex {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    return (($Bytes | ForEach-Object { '{0:x2}' -f $_ }) -join '')
}
function Convert-HexToBytes {
    param([string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return ,(New-Object byte[] 0) }
    $out = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $out.Length; $i++) {
        $out[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return ,$out
}

# =====================================================================
#  注册表
# =====================================================================
function Get-RegValue {
    <# 读一个注册表值；不存在返回 $null #>
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($item.GetValueNames() -notcontains $Name) { return $null }
    return $item.GetValue($Name)
}

function Backup-RegValue {
    <# 把某个注册表值的「原始状态」记下来。只记第一次，后面重复调用不覆盖。 #>
    param([string]$Path, [string]$Name)
    $key = "REG|$Path|$Name"
    if ($Script:Backup.ContainsKey($key)) { return }

    $entry = @{ Kind = 'Reg'; Path = $Path; Name = $Name; Existed = $false; Type = $null; Value = $null }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            $kind = $item.GetValueKind($Name).ToString()
            $v    = $item.GetValue($Name)
            $entry.Existed = $true
            $entry.Type    = $kind
            if     ($kind -eq 'Binary')      { $entry.Value = Convert-BytesToHex $v }
            elseif ($kind -eq 'MultiString') { $entry.Value = @($v) }
            else                             { $entry.Value = $v }
        }
    }
    $Script:Backup[$key] = $entry
    Save-BackupStore
}

function Set-RegValue {
    <# 写注册表；写之前自动备份原值 #>
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    Backup-RegValue -Path $Path -Name $Name
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Restore-RegValue {
    <#
      还原一个注册表值。
      优先用备份里的原值；没有备份就用优化项自带的 Default（系统公认默认值）。
      Default 写成 '@DELETE@' 表示「原本就没有这个值，删掉即可」。
    #>
    param([string]$Path, [string]$Name, [string]$Type, $Default)
    $key = "REG|$Path|$Name"
    if ($Script:Backup.ContainsKey($key)) {
        $e = $Script:Backup[$key]
        if (-not $e.Existed) {
            if (Test-Path -LiteralPath $Path) {
                Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
            }
        } else {
            $val = $e.Value
            if     ($e.Type -eq 'Binary')      { $val = Convert-HexToBytes $e.Value }
            elseif ($e.Type -eq 'MultiString') { $val = [string[]]@($e.Value) }
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $e.Type -Value $val -Force | Out-Null
        }
        $Script:Backup.Remove($key)
        Save-BackupStore
        return
    }

    # 没有备份，退回默认值
    if ($null -eq $Default -or "$Default" -eq '@DELETE@') {
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        $val = $Default
        if ($Type -eq 'Binary' -and $Default -is [string]) { $val = Convert-HexToBytes $Default }
        New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $val -Force | Out-Null
    }
}

# =====================================================================
#  服务
# =====================================================================
function Get-ServiceStartMode {
    param([string]$Name)
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $s) { return $null }
    return $s.StartMode      # Auto / Manual / Disabled / Boot / System
}

function Set-ServiceStartup {
    <# 修改服务启动类型；改之前备份原状态。Target: Automatic / Manual / Disabled #>
    param([string]$Name, [string]$Target)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log "服务 $Name 在这台机器上不存在，已跳过" '信息'; return $false }

    $key = "SVC|$Name"
    if (-not $Script:Backup.ContainsKey($key)) {
        $Script:Backup[$key] = @{ Kind = 'Svc'; Name = $Name; StartMode = (Get-ServiceStartMode $Name); Status = "$($svc.Status)" }
        Save-BackupStore
    }

    if ($Target -eq 'Disabled') {
        try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch { }
    }
    try {
        Set-Service -Name $Name -StartupType $Target -ErrorAction Stop
    } catch {
        # 有些系统服务受保护，Set-Service 会被拒绝，直接改注册表 Start 值兜底
        # Start: 2=自动 3=手动 4=禁用
        $code = switch ($Target) { 'Automatic' { 2 } 'Manual' { 3 } 'Disabled' { 4 } default { 3 } }
        try {
            Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $code -Force -ErrorAction Stop
        } catch {
            Write-Log "无法修改服务 $Name（受系统保护）：$($_.Exception.Message)" '警告'
            return $false
        }
    }
    if ($Target -eq 'Automatic') { try { Start-Service -Name $Name -ErrorAction SilentlyContinue } catch { } }
    return $true
}

function Restore-Service {
    param([string]$Name, [string]$Default = 'Manual')
    $key  = "SVC|$Name"
    $mode = $Default
    if ($Script:Backup.ContainsKey($key)) {
        $mode = $Script:Backup[$key].StartMode
        $Script:Backup.Remove($key)
        Save-BackupStore
    }
    $target = switch ("$mode") {
        'Auto'      { 'Automatic' }
        'Automatic' { 'Automatic' }
        'Manual'    { 'Manual' }
        'Disabled'  { 'Disabled' }
        default     { 'Manual' }
    }
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    try { Set-Service -Name $Name -StartupType $target -ErrorAction Stop } catch {
        $code = switch ($target) { 'Automatic' { 2 } 'Manual' { 3 } 'Disabled' { 4 } default { 3 } }
        try { Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $code -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($target -eq 'Automatic') { try { Start-Service -Name $Name -ErrorAction SilentlyContinue } catch { } }
    return $true
}

# =====================================================================
#  外部命令（powercfg / fsutil / bcdedit 等）
# =====================================================================
function Invoke-Native {
    <# 执行一个命令行程序并返回它的全部输出（含错误输出），方便写日志 #>
    param([string]$File, [string[]]$Arguments)
    try {
        $out = & $File @Arguments 2>&1 | Out-String
        return $out.Trim()
    } catch {
        return "执行失败：$($_.Exception.Message)"
    }
}

# =====================================================================
#  系统还原点
# =====================================================================
function New-SystemRestorePoint {
    <#
      在动手改设置之前建一个系统还原点——这是最后一道保险。
      万一哪个改动让机器不舒服，进「恢复」里回滚就行。
    #>
    param([string]$Description = 'PC调优助手-修改前备份')
    try {
        # Windows 默认「24 小时内只建一个还原点」，这里临时解除限制
        $srPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        if (-not (Test-Path -LiteralPath $srPath)) { New-Item -Path $srPath -Force | Out-Null }
        New-ItemProperty -LiteralPath $srPath -Name 'SystemRestorePointCreationFrequency' -PropertyType DWord -Value 0 -Force | Out-Null

        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log "系统还原点创建成功：$Description" '成功'
        return $true
    } catch {
        Write-Log "创建还原点失败（可能是系统保护被关闭了）：$($_.Exception.Message)" '警告'
        return $false
    }
}

# =====================================================================
#  杂项
# =====================================================================
function Format-Size {
    <# 字节数 -> 人类可读 #>
    param([double]$Bytes)
    if ($Bytes -lt 1KB) { return ('{0:N0} B'  -f $Bytes) }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Get-EdgeShortcuts {
    <#
      找出本机所有指向 msedge.exe 的快捷方式（桌面 / 开始菜单 / 任务栏）。

      为什么需要这个：Edge 没有「设置启动参数」的官方组策略，
      想给它加 --process-per-site 这类命令行开关，只能改快捷方式。
    #>
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $out = @()
    $sh = $null
    try {
        $sh = New-Object -ComObject WScript.Shell
        foreach ($d in $dirs) {
            foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.lnk -Recurse -Force -ErrorAction SilentlyContinue)) {
                try {
                    $l = $sh.CreateShortcut($f.FullName)
                    if ($l.TargetPath -match '(?i)msedge\.exe$') {
                        $out += [PSCustomObject]@{ Path = $f.FullName; Arguments = "$($l.Arguments)" }
                    }
                } catch { }
            }
        }
    } catch { } finally {
        if ($sh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
    }
    return $out
}

function Set-EdgeShortcutFlag {
    <#
      给所有 Edge 快捷方式追加 / 摘掉一个命令行开关，返回成功改动的个数。

      ★ 关键：必须「追加」而不是「覆盖」★
        任务栏上那个 Edge 快捷方式自带 --profile-directory=Default，
        直接覆盖 Arguments 会把它弄丢，结果是 Edge 打开时加载错配置文件
        （收藏夹、登录状态看起来全没了，很吓人）。
        所以这里只在原参数基础上加减，其余原样保留。
    #>
    param([string]$Flag, [bool]$Add)
    $n = 0
    $sh = $null
    try {
        $sh = New-Object -ComObject WScript.Shell
        foreach ($item in (Get-EdgeShortcuts)) {
            try {
                $l = $sh.CreateShortcut($item.Path)
                $args = "$($l.Arguments)"
                $has = $args -match [regex]::Escape($Flag)
                if ($Add -and -not $has) {
                    $l.Arguments = ($args.Trim() + ' ' + $Flag).Trim()
                    $l.Save(); $n++
                } elseif (-not $Add -and $has) {
                    $l.Arguments = (($args -replace [regex]::Escape($Flag), '') -replace '\s{2,}', ' ').Trim()
                    $l.Save(); $n++
                }
            } catch {
                Write-Log "改不动快捷方式 $($item.Path)：$($_.Exception.Message)" '警告'
            }
        }
    } catch {
        Write-Log "操作 Edge 快捷方式失败：$($_.Exception.Message)" '错误'
    } finally {
        if ($sh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
    }
    return $n
}

function Test-IsLaptop {
    <# 判断是笔记本还是台式机（休眠、电源策略的建议不一样） #>
    try {
        $types = (Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes
        foreach ($t in $types) { if ($t -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) { return $true } }
    } catch { }
    return $false
}

function Test-SystemDriveIsSSD {
    <# 判断系统盘是固态还是机械——很多优化项只对其中一种有意义 #>
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" }
        if ($disk) {
            if ($disk.MediaType -eq 'SSD') { return $true }
            if ($disk.MediaType -eq 'HDD') { return $false }
            # 有些老驱动报 Unspecified，用转速兜底：0 = 固态
            if ($disk.SpindleSpeed -eq 0 -or $null -eq $disk.SpindleSpeed) { return $true }
            return $false
        }
    } catch { }
    return $true   # 判断不出来时按固态处理（更保守，不会去动只有机械盘才需要的服务）
}
