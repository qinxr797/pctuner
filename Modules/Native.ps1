#Requires -Version 5.1
<#
=====================================================================
  Native.ps1  ——  直接调 Windows API 的那几处（v6.2）
---------------------------------------------------------------------
  ★ 为什么不用 Add-Type 写 C# ★
    Add-Type 在 PowerShell 5.1 里是现场调 csc.exe 编译一个临时 DLL 再加载 ——
    「PowerShell 拉起编译器、往临时目录写 DLL」正是杀毒软件最爱盯的行为，还每次启动都多花几百毫秒。
    这里用 .NET 自带的反射在内存里声明几个系统函数（DefinePInvokeMethod），
    不编译、不落盘，效果和 [DllImport] 一样。

  ★ 同一个进程里只建一次 ★
    后台线程（Start-BgWork）也会载入这个文件，而动态类型在一个进程里不能重名定义两次，
    所以建好的类型存在 AppDomain 上，谁先来谁建，后来的直接拿。

  现在用到的：
    · 读 NVMe 固态自己的健康日志（剩余寿命、备用块、累计写入、通电时长）—— 硬盘健康
    · 声明 / 查询 DPI 感知级别 —— 高分屏下界面不发虚
=====================================================================
#>

function Get-NativeApi {
    $t = [AppDomain]::CurrentDomain.GetData('PCTuner.NativeApi')
    if ($t) { return $t }
    $asm = [AppDomain]::CurrentDomain.DefineDynamicAssembly((New-Object Reflection.AssemblyName 'PCTunerNative'), 'Run')
    $mod = $asm.DefineDynamicModule('PCTunerNative')
    $tb = $mod.DefineType('PCTuner.NativeApi', 'Public, Class, Sealed')
    $add = {
        param([string]$Name, [string]$Dll, [Type]$Ret, [Type[]]$Params)
        $m = $tb.DefinePInvokeMethod($Name, $Dll,
            [Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
            [Reflection.CallingConventions]::Standard, $Ret, $Params,
            [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
        $m.SetImplementationFlags('PreserveSig')
    }
    & $add 'CreateFileW' 'kernel32.dll' ([IntPtr]) @([string], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr])
    & $add 'DeviceIoControl' 'kernel32.dll' ([bool]) @([IntPtr], [uint32], [byte[]], [uint32], [byte[]], [uint32], [uint32].MakeByRefType(), [IntPtr])
    & $add 'CloseHandle' 'kernel32.dll' ([bool]) @([IntPtr])
    & $add 'SetProcessDpiAwarenessContext' 'user32.dll' ([bool]) @([IntPtr])
    & $add 'GetThreadDpiAwarenessContext' 'user32.dll' ([IntPtr]) @()
    & $add 'GetAwarenessFromDpiAwarenessContext' 'user32.dll' ([int]) @([IntPtr])
    & $add 'SetProcessDPIAware' 'user32.dll' ([bool]) @()
    $t = $tb.CreateType()
    [AppDomain]::CurrentDomain.SetData('PCTuner.NativeApi', $t)
    return $t
}

# =====================================================================
#  NVMe 健康日志
# ---------------------------------------------------------------------
#  走 IOCTL_STORAGE_QUERY_PROPERTY（StorageDeviceProtocolSpecificProperty），
#  取 NVMe 规范里的 SMART / Health Information 日志页（Log Page 0x02，512 字节）。
#  这是盘自己记的账，Windows 的「设置 → 存储 → 磁盘和卷」里显示的「估计剩余寿命」读的也是它。
#
#  ★ 为什么不用 Get-StorageReliabilityCounter 的 Wear ★（2026-09-28 实测）
#    老板这台三星 PM981：界面上（Wear）显示 0，盘自己的日志写的是「已用 6%」。
#    朋友的三星 980 用了四五年也显示 0。Wear 在不少 NVMe 盘上是一个占位的 0，
#    而且非管理员直接读不了（报「无法从客户端中访问 CIM 资源」）。
#    这条 IOCTL 非管理员也能读（打开盘时不申请读写权限，只查属性）。
#
#  返回 @{ Used; Spare; SpareThreshold; Critical; TempC; WrittenTB; Hours; MediaErrors; UnsafeShutdowns }
#  读不到（SATA 盘、U 盘、虚拟盘、驱动不支持）返回 $null —— 调用处显示「—」，不编。
# =====================================================================
function Get-NvmeHealth {
    param([int]$DiskNumber)
    $api = $null
    try { $api = Get-NativeApi } catch { return $null }
    $h = $api::CreateFileW("\\.\PhysicalDrive$DiskNumber", 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]::new(-1)) { return $null }
    try {
        # STORAGE_PROPERTY_QUERY(8) + STORAGE_PROTOCOL_SPECIFIC_DATA(40) + 日志 512
        $buf = New-Object byte[] 560
        [BitConverter]::GetBytes([int]50).CopyTo($buf, 0)     # StorageDeviceProtocolSpecificProperty
        [BitConverter]::GetBytes([int]0).CopyTo($buf, 4)      # PropertyStandardQuery
        [BitConverter]::GetBytes([int]3).CopyTo($buf, 8)      # ProtocolTypeNvme
        [BitConverter]::GetBytes([int]2).CopyTo($buf, 12)     # NVMeDataTypeLogPage
        [BitConverter]::GetBytes([int]2).CopyTo($buf, 16)     # 日志页 0x02 = SMART / Health
        [BitConverter]::GetBytes([int]40).CopyTo($buf, 24)    # 数据紧跟在这个结构后面
        [BitConverter]::GetBytes([int]512).CopyTo($buf, 28)
        $got = [uint32]0
        if (-not $api::DeviceIoControl($h, 0x2D1400, $buf, 560, $buf, 560, [ref]$got, [IntPtr]::Zero)) { return $null }
        if ($got -lt 560) { return $null }
        # 返回的是 STORAGE_PROTOCOL_DATA_DESCRIPTOR：Version(4) Size(4) 再接同样的 40 字节结构
        $off = 8 + [BitConverter]::ToInt32($buf, 8 + 16)
        $len = [BitConverter]::ToInt32($buf, 8 + 20)
        if ($len -lt 192 -or $off + 192 -gt $buf.Length) { return $null }
        $u64 = { param($o) [double][BitConverter]::ToUInt64($buf, $off + $o) }   # 16 字节计数器只取低 8 字节，够用几百年
        $tempK = [BitConverter]::ToUInt16($buf, $off + 1)
        $r = @{
            Critical        = [int]$buf[$off]
            TempC           = $(if ($tempK -gt 200) { [int]($tempK - 273) } else { $null })
            Spare           = [int]$buf[$off + 3]
            SpareThreshold  = [int]$buf[$off + 4]
            Used            = [int]$buf[$off + 5]                                   # 可以超过 100（规范允许到 255）
            WrittenTB       = [math]::Round((& $u64 48) * 512000 / 1e12, 1)         # 单位是「1000 个 512 字节」
            Hours           = [long](& $u64 128)
            UnsafeShutdowns = [long](& $u64 144)
            MediaErrors     = [long](& $u64 160)
        }
        # 全零的日志 = 驱动给了个空壳，不是真读数
        if ($r.Spare -eq 0 -and $r.Used -eq 0 -and $r.Hours -eq 0 -and $r.WrittenTB -eq 0) { return $null }
        return $r
    } catch { return $null }
    finally { [void]$api::CloseHandle($h) }
}
