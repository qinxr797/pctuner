<#
=====================================================================
  Tweaks.ps1  ——  所有性能优化项的定义
---------------------------------------------------------------------
  每一项的字段含义：
    Id          内部编号（备份、日志用）
    Name        界面上显示的名字
    Category    分组
    Risk        风险：低 / 中 / 高
    Effect      预期效果（老实写，没用的就说没用）
    Recommended 是否属于「一键优化（安全推荐）」
    Reboot      是否需要重启才生效
    Detail      详细说明 —— 这是干什么用的、为什么有效、副作用是什么
    Regs        要改的注册表值（改之前引擎会自动备份原值）
    Services    要改的服务
    Apply       额外动作（注册表搞不定的，比如 powercfg / fsutil）
    Revert      对应的撤销动作
    Test        自定义「当前是否已优化」检测
    Available   返回 $false 时这一项会变灰（比如机械盘就不显示固态专用项）

  ★ 关于 Effect 的诚实说明 ★
    网上很多「游戏优化」其实是安慰剂。这份清单里标了「几乎无感」
    的项目就是真的几乎无感，我把它们留下来只是因为有人想要，
    但它们不在「推荐」里。别指望改几个注册表就把 5 年前的机器
    变成新机器 —— 真正的大头永远是：加内存、换固态、清灰换硅脂、
    更新显卡驱动。这四件事在「系统体检」页里会提醒。
=====================================================================
#>

# --- 电源计划 GUID（放在脚本作用域，下面的 Apply/Revert 代码块才能读到）---
$Script:GUID_卓越性能 = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$Script:GUID_高性能   = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$Script:GUID_平衡     = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Get-AllTweaks {

    $tweaks = @()

    # =================================================================
    #  分类一：核心性能
    # =================================================================

    $tweaks += @{
        Id = 'PowerPlan'; Name = '电源计划改为「高性能 / 卓越性能」'
        Category = '核心性能'; Risk = '低'; Effect = '明显（尤其是笔记本和老机器）'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
Windows 默认用「平衡」电源计划。平衡模式为了省电，会在你不动
的时候把 CPU 频率降到很低，需要性能时再慢慢升上去。这个「升
上去」的过程有延迟，表现就是：点开东西卡一下、游戏里突然掉帧。

切到「高性能 / 卓越性能」后，CPU 会一直保持在较高频率待命，
响应更干脆，游戏帧数更稳（平均帧数提升不一定大，但 1% Low
帧，也就是「卡顿感」，会明显改善）。

【代价】
· 台式机：几乎没有代价，就是多耗一点电。
· 笔记本：插电时用没问题；靠电池时会明显更费电、更热。
  所以笔记本建议只在插电打游戏时开。

【怎么做的】
优先启用 Windows 隐藏的「卓越性能」计划（比高性能更激进），
没有就退回「高性能」；两个都被删了就从微软的内置模板重建一个。
切完之后会**验证当前方案是否真的变了**，没变会明确告诉你。

【⚠ 品牌机 / 游戏本要注意】
很多带厂商管理软件的机器（华硕 Armoury Crate、联想电脑管家、
微星 Dragon Center、外星人 Command Center 等），会把「高性能」
「卓越性能」这两个标准方案从系统里删掉，自己建一个「我的自定义计划」
接管，而且你从 Windows 这边改完它还会改回去。

这种情况下这一项会提示切换失败 —— 不是工具坏了，是厂商软件在管。
**正确做法是直接在那个厂商软件里切到「性能 / 野兽 / 狂暴」模式**，
效果是一样的，而且不会打架。
'@
        Apply = {
            $orig = (Invoke-Native 'powercfg.exe' @('/getactivescheme'))
            if ($orig -match '([0-9a-fA-F-]{36})') { Set-BackupNote -Key 'PowerPlanOriginal' -Value $Matches[1] }

            # 在本机已有的方案里找现成的（先卓越、后高性能）
            function Find-Scheme {
                param([string]$Pattern)
                foreach ($line in ((Invoke-Native 'powercfg.exe' @('/list')) -split "`r?`n")) {
                    if ($line -match '([0-9a-fA-F-]{36})\s*\((.+?)\)' -and $Matches[2] -match $Pattern) { return $Matches[1] }
                }
                return $null
            }

            # ★ 这里踩过坑 ★
            # 早期版本的逻辑是：找不到卓越性能 → 直接 setactive 高性能的固定 GUID。
            # 但很多品牌机（尤其 ROG / 拯救者这类带厂商管理软件的笔记本）
            # 会把「高性能」「卓越性能」两个标准方案从系统里删掉，
            # 于是那个固定 GUID 根本不存在，setactive 静默失败 ——
            # 工具还报「已切换」，实际上啥也没变。
            # 现在改成：找不到就从微软的内置模板复制一份出来，最后再验证到底成没成。
            $target = Find-Scheme '卓越|Ultimate'
            if (-not $target) {
                $dup = Invoke-Native 'powercfg.exe' @('-duplicatescheme', $Script:GUID_卓越性能)
                if ($dup -match '([0-9a-fA-F-]{36})') { $target = $Matches[1] }
            }
            if (-not $target) { $target = Find-Scheme '高性能|High performance' }
            if (-not $target) {
                $dup = Invoke-Native 'powercfg.exe' @('-duplicatescheme', $Script:GUID_高性能)
                if ($dup -match '([0-9a-fA-F-]{36})') { $target = $Matches[1] }
            }
            if (-not $target) {
                Write-Log '这台机器上找不到也建不出「高性能/卓越性能」方案 —— 多半是厂商管理软件（Armoury Crate / 联想电脑管家 等）接管了电源方案。请直接在那个软件里切到性能模式。' '警告'
                return
            }

            Invoke-Native 'powercfg.exe' @('/setactive', $target) | Out-Null

            # 验证：真的切过去了吗？不验证就报成功，是上一版最大的问题
            $now = Invoke-Native 'powercfg.exe' @('/getactivescheme')
            if ($now -match [regex]::Escape($target)) {
                Set-BackupNote -Key 'PowerPlanApplied' -Value $target
                Write-Log "电源计划已切换并验证通过（$target）" '成功'
            } else {
                Write-Log "电源计划切换失败：命令执行了，但当前方案没变。很可能是厂商管理软件（Armoury Crate / 联想电脑管家 等）把它改回去了。请直接在那个软件里切到性能模式。" '警告'
            }
        }
        Revert = {
            $orig = Get-BackupNote -Key 'PowerPlanOriginal'
            if (-not $orig) { $orig = $Script:GUID_平衡 }
            Invoke-Native 'powercfg.exe' @('/setactive', $orig) | Out-Null
            Write-Log '电源计划已还原' '成功'
        }
        Test = {
            $cur = Invoke-Native 'powercfg.exe' @('/getactivescheme')
            if ($cur -match '高性能|卓越|High performance|Ultimate') { return $true }
            # 从模板复制出来的方案，名字可能被系统本地化成别的叫法，
            # 所以也认一下「我们上次实际切过去的那个 GUID」
            $applied = Get-BackupNote -Key 'PowerPlanApplied'
            if ($applied -and $cur -match [regex]::Escape($applied)) { return $true }
            return $false
        }
    }

    $tweaks += @{
        Id = 'PowerDetail'; Name = '电源细节调优（USB 不断电 / 硬盘不休眠 / CPU 不降频）'
        Category = '核心性能'; Risk = '低'; Effect = '中等，主要是消除「卡一下」的顿挫感'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
在当前电源计划里关掉四个省电开关：

1. USB 选择性暂停
   Windows 会给「闲着的」USB 设备断电省电。后果是鼠标、手柄、
   耳机偶尔会有一瞬间失灵、或者插着的设备莫名其妙掉线。关掉。

2. 硬盘闲置后关闭
   默认 20 分钟不读写就让硬盘停转。机械盘再次唤醒要 2~3 秒，
   表现为「切出去一会儿，回来点什么都要顿一下」。设为「从不」。

3. PCIe 链接状态电源管理（ASPM）
   给显卡、固态、网卡所在的 PCIe 通道省电。省下的电微乎其微，
   但会给这些设备的响应加上额外延迟。关掉。

4. 处理器最小状态设为 100%
   不让 CPU 降到低频待机，从低频爬回高频的那段延迟就没有了。

【代价】
更耗电、机器更热一点。台式机无所谓；笔记本靠电池时续航会短。
（本工具只改「接通电源」时的策略，不动「使用电池」时的策略，
  所以笔记本用电池时依然省电。）

【还原】
还原时会写回 Windows 的出厂默认值：
CPU 最低 5%、USB 选择性暂停开启、硬盘 20 分钟休眠、ASPM 中等省电。
'@
        Apply = {
            # 语法: powercfg /setacvalueindex <方案> <子组GUID> <设置GUID> <值>
            # 只改 AC（接通电源），不动 DC（电池），笔记本用电池时依然省电
            $ops = @(
                @('SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '100'),                                              # CPU 最低状态 100%
                @('SCHEME_CURRENT', '2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', '0'),     # USB 选择性暂停 = 已禁用
                @('SCHEME_CURRENT', 'SUB_DISK', 'DISKIDLE', '0'),                                                            # 硬盘从不关闭
                @('SCHEME_CURRENT', '501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', '0')      # PCIe ASPM = 关闭
            )
            foreach ($o in $ops) { Invoke-Native 'powercfg.exe' (@('/setacvalueindex') + $o) | Out-Null }
            Invoke-Native 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT') | Out-Null
            Set-TweakFlag -Id 'PowerDetail' -On $true
            Write-Log '电源细节已调优（USB 不断电 / 硬盘不休眠 / CPU 不降频 / PCIe 不省电）' '成功'
        }
        Revert = {
            $ops = @(
                @('SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '5'),
                @('SCHEME_CURRENT', '2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', '1'),
                @('SCHEME_CURRENT', 'SUB_DISK', 'DISKIDLE', '1200'),
                @('SCHEME_CURRENT', '501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', '2')
            )
            foreach ($o in $ops) { Invoke-Native 'powercfg.exe' (@('/setacvalueindex') + $o) | Out-Null }
            Invoke-Native 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT') | Out-Null
            Set-TweakFlag -Id 'PowerDetail' -On $false
            Write-Log '电源细节已还原为系统默认' '成功'
        }
        Test = { return (Get-TweakFlag -Id 'PowerDetail') }
    }

    $tweaks += @{
        Id = 'SysResponsiveness'; Name = '解除后台服务对 CPU 和网络的预留限制'
        Category = '核心性能'; Risk = '低'; Effect = '中等，网游延迟和帧数稳定性有改善'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
Windows 里有个叫 MMCSS（多媒体类调度服务）的机制，它会：

1. SystemResponsiveness —— 默认给后台任务预留 20% 的 CPU 时间。
   这是为了保证你放音乐、录屏时不卡。但对游戏来说，
   这 20% 是白白让出去的。调到 10%（不建议调成 0，
   调成 0 有些人会遇到语音软件破音、音频爆音）。

2. NetworkThrottlingIndex —— 默认限制每秒最多处理 1 万个网络包，
   同样是为了给音视频播放让路。这个限制对网游是纯粹的负担，
   会造成额外的网络延迟抖动。设为 0xFFFFFFFF = 完全不限制。

【效果】
网游（尤其是射击、MOBA）的延迟抖动会小一些。单机游戏提升不明显。
这是少数几个有实测数据支持、不是玄学的注册表优化。

【风险】
低。最坏情况是一边放视频一边玩游戏时视频掉帧，改回去即可。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'SystemResponsiveness';    Type = 'DWord'; Value = 10; Default = 20 }
            # -1 写进注册表就是 0xFFFFFFFF，代表「不限制」
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Type = 'DWord'; Value = -1; Default = 10 }
        )
    }

    $tweaks += @{
        Id = 'MMCSSGames'; Name = '提高「游戏」任务的 CPU / GPU 调度优先级'
        Category = '核心性能'; Risk = '低'; Effect = '小幅，帧生成时间更平滑'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
接上一项。MMCSS 把程序分成几类（音频、游戏、播放……），
每一类有自己的优先级配置。「游戏」这一类的默认配置其实偏保守：
    调度类别 = Medium（中）
    CPU 优先级 = 2（一共 1~8）
    磁盘 IO 优先级 = Normal（普通）

调用了 MMCSS 的游戏（相当一部分 DX 游戏会调用）就只能拿到
中等待遇。这一项把它们提到：
    调度类别 = High（高）
    CPU 优先级 = 6
    磁盘 IO 优先级 = High（高）
    GPU 优先级 = 8（本来就是 8，保持）

【效果】
平均帧数基本不变，但帧生成时间（frametime）更均匀，
主观感受是「更跟手、更少微卡顿」。属于小幅改善，不是质变。

【风险】
低。这只是改优先级，不涉及超频或关闭安全功能。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'GPU Priority';        Type = 'DWord';  Value = 8;      Default = 8 }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Priority';            Type = 'DWord';  Value = 6;      Default = 2 }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Scheduling Category'; Type = 'String'; Value = 'High'; Default = 'Medium' }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'SFIO Priority';       Type = 'String'; Value = 'High'; Default = 'Normal' }
        )
    }

    $tweaks += @{
        Id = 'Win32Priority'; Name = 'CPU 时间片调度调整（Win32PrioritySeparation = 40）'
        Category = '核心性能'; Risk = '中'; Effect = '因机而异，必须自己实测 1% Low 才知道'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
控制 Windows 怎么在「你正在用的窗口」和「后台程序」之间分配
CPU 时间片。这个值是 6 个二进制位拼出来的：
    第 5-4 位：时间片长短（短 / 长）
    第 3-2 位：时间片固定 还是 随前后台变化
    第 1-0 位：前台程序的加成倍率（1:1 / 2:1 / 3:1）

本项设为 40（十六进制 0x28）= 短时间片 + 固定 + 前后台 1:1。
思路是：不给前台额外加成，所有线程按固定长度轮转，
让帧生成时间（frametime）更均匀，减少「平均帧很高但手感发涩」。

【⚠ 顺便戳破一个流传很广的错误】
网上抄得最多的值是 38（0x26）。但 38 = 短时间片 + 动态 + 3:1 加成，
这恰恰就是 **Windows 10/11 桌面版的默认行为**（默认值 2 的实际含义）。
换句话说：把它改成 38，等于什么都没改。
很多「优化教程」和「一键优化工具」这一步是纯粹的安慰剂。
真正和默认不一样的是 40（0x28），所以本工具用 40。

【为什么默认不勾】
效果**高度取决于你的 CPU 核心数和后台负载**：
· 核心多（8 核以上）、后台干净 —— 可能让帧时间更平滑
· 核心少（4 核及以下）、后台一堆东西 —— 可能反而更卡，
  因为后台被饿着，轮到它时要处理一大堆积压

写 CS2 优化贴的人自己都说过一句实话：
「追求输入延迟对大部分玩家几乎没必要，帧数稳定体感更明显」。

【怎么测才算数】
别凭感觉。开 CS2 控制台 cl_showfps 1 或用 CapFrameX，
同一张图、同一段跑图路线，改前改后各跑一次，
**比 1% Low 和 0.1% Low，不要比平均帧**。
没有明显改善就还原，不要为了「我改过了」的心理安慰留着。

【风险】
中。不会损坏系统，但可能让体验变差。随时可还原。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; Name = 'Win32PrioritySeparation'; Type = 'DWord'; Value = 40; Default = 2 }
        )
    }

    $tweaks += @{
        Id = 'MemCompression'; Name = '关闭内存压缩'
        Category = '核心性能'; Risk = '中'; Effect = '内存 16G 以上略有收益；8G 及以下会变卡'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
Win10 会把不常用的内存页「压缩」起来塞在内存里，而不是写到硬盘的
虚拟内存。好处是内存不够时少读写硬盘；代价是压缩解压要花 CPU，
你在任务管理器里看到的 "System" 进程占 CPU，很多时候就是它。

【什么时候该关】
· 内存 16GB 以上、平时用不满 —— 关掉能省一点 CPU，
  System 进程的占用会降下来。
· 内存 8GB 或更少 —— **千万别关**。关了以后内存一不够就疯狂
  读写硬盘（尤其机械盘），会卡到怀疑人生。

【所以】
默认不勾。让工具在「系统体检」页告诉你内存多大，自己决定。

【风险】
中。关错了很卡，但改回来就好，不会损坏任何东西。
'@
        Apply  = { try { Disable-MMAgent -MemoryCompression -ErrorAction Stop; Write-Log '内存压缩已关闭' '成功' } catch { Write-Log "关闭内存压缩失败：$($_.Exception.Message)" '警告' } }
        Revert = { try { Enable-MMAgent  -MemoryCompression -ErrorAction Stop; Write-Log '内存压缩已重新开启' '成功' } catch { Write-Log "开启内存压缩失败：$($_.Exception.Message)" '警告' } }
        Test   = { try { return (-not (Get-MMAgent -ErrorAction Stop).MemoryCompression) } catch { return $false } }
    }

    # =================================================================
    #  分类二：显卡与游戏
    # =================================================================

    $tweaks += @{
        Id = 'GameDVR'; Name = '关闭 Xbox 后台录制（Game DVR）'
        Category = '显卡与游戏'; Risk = '低'; Effect = '明显 —— 这是本清单里最值得做的一项'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
Win10 自带 Xbox Game Bar，里面有个「后台录制」功能：
它会在你玩游戏时**一直在后台默默录屏**，只保留最近 30 秒，
好让你随时按快捷键「保存刚才那波操作」。

绝大多数人从来不用这个功能，但它一直开着，一直在吃：
· GPU 编码单元（NVENC / AMD VCE）
· 3%~10% 的帧数
· 硬盘持续写入

这是所有「游戏优化」里**最实在、最能被测出来**的一项。
老显卡上尤其明显。

【这一项会改什么】
· GameDVR_Enabled = 0        关闭后台录制
· AllowGameDVR   = 0        用组策略层面彻底禁掉，防止被 Xbox 应用改回来

【会不会影响什么】
· Xbox Game Bar 本身还能打开（Win+G），只是不再后台录制。
· 你如果真的靠它录游戏 —— 那就别勾这一项。
· 不影响 OBS、NVIDIA ShadowPlay、AMD ReLive 等第三方录制工具。

【风险】
低，随时可还原。
'@
        Regs = @(
            @{ Path = 'HKCU:\System\GameConfigStore';                              Name = 'GameDVR_Enabled'; Type = 'DWord'; Value = 0; Default = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';         Name = 'AllowGameDVR';    Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR';   Name = 'AppCaptureEnabled'; Type = 'DWord'; Value = 0; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'GameMode'; Name = '开启 Windows 游戏模式'
        Category = '显卡与游戏'; Risk = '低'; Effect = '中等，主要是让后台别来抢资源'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
游戏模式开启后，Windows 检测到你在玩游戏时会：
· 暂缓 Windows Update 的下载和安装（不会玩到一半开始更新）
· 暂缓驱动安装提示、系统通知
· 优先把 CPU / GPU 资源给游戏进程

【效果】
不会直接提升帧数上限，但能显著减少那种「打着打着突然卡 3 秒」
的情况 —— 因为那 3 秒往往就是后台在偷偷更新。

早期（2017 年左右）的游戏模式有 bug 会掉帧，那是老黄历了，
现在的版本是纯收益。微软自己也建议开着。

【风险】
低。这就是个系统自带的官方开关。
'@
        Regs = @(
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled';  Type = 'DWord'; Value = 1; Default = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode';    Type = 'DWord'; Value = 1; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'HAGS'; Name = '开启「硬件加速 GPU 计划」(HAGS)'
        Category = '显卡与游戏'; Risk = '中'; Effect = '因卡而异：新卡可能降延迟，老卡可能掉帧'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
正常情况下，显存的分配和任务排队是由 CPU 上的 Windows 驱动来
管的。开启 HAGS 后，改由显卡自己的调度处理器来管，少绕一道
CPU，理论上能降低一点延迟。

【为什么默认不勾】
这一项是**明确的因机而异**，没有普适答案：
· NVIDIA 10 系（GTX 1060 那一代）及更老 —— 硬件不支持，开了没用
· NVIDIA 16/20 系及以上、AMD RX 5000 系及以上 —— 支持
· 支持的卡上，实测结果也是有人涨 3 帧、有人掉 5 帧
· 某些游戏 + 某些驱动版本组合下会出现闪烁、崩溃

微软和 NVIDIA 官方的说法都是「可以试，不行就关」。
所以这一项交给你自己测：开了跑一遍游戏，不满意就还原。

【怎么验证生效】
重启后：设置 → 系统 → 显示 → 显卡设置 → 看「硬件加速 GPU 计划」

【风险】
中。极少数情况下会花屏或黑屏，这时开机进安全模式把它关掉即可。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Type = 'DWord'; Value = 2; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'FSO'; Name = '全局关闭「全屏优化」'
        Category = '显卡与游戏'; Risk = '中'; Effect = '老游戏可能变顺，新游戏可能变卡'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
Win10 从某个版本起，把游戏的「独占全屏」偷偷换成了
「无边框窗口 + 优化」。好处是 Alt+Tab 切出去秒切、
Game Bar 能叠在上面；坏处是多了一层 DWM 桌面合成，
会增加 1~2 帧的输入延迟。

这一项把它全局关掉，让游戏真正独占全屏。

【为什么默认不勾】
· 老游戏（2015 年前的 DX9/DX11 游戏）—— 关掉通常有好处
· 新游戏、DX12 游戏 —— 关掉可能反而出问题（切屏黑屏、
  HDR 失效、多显示器错乱）
· 竞技射击游戏玩家通常会关，因为在乎那 1 帧延迟

更精准的做法其实是：右键游戏 exe → 属性 → 兼容性 →
勾「禁用全屏优化」，只对那一个游戏生效。
这一项是全局版，图省事用。

【风险】
中。出问题的表现是切屏异常，还原即可。
'@
        Regs = @(
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode';                 Type = 'DWord'; Value = 2; Default = 2 }
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode';        Type = 'DWord'; Value = 1; Default = 0 }
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_DXGIHonorFSEWindowsCompatible';   Type = 'DWord'; Value = 1; Default = 0 }
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_EFSEFeatureFlags';                Type = 'DWord'; Value = 0; Default = 0 }
        )
    }

    $tweaks += @{
        Id = 'MPO'; Name = '关闭多平面叠加 MPO（修复花屏 / 闪烁 / 莫名掉帧）'
        Category = '显卡与游戏'; Risk = '低'; Effect = '修复类 —— 没毛病就别开'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
MPO（Multi-Plane Overlay）是 Windows 的一个显示合成优化。
理论上省电省性能，但它和某些显卡驱动、某些多显示器组合、
某些刷新率组合有长期存在的兼容性 bug，典型症状：

· 浏览器滚动时画面撕裂、闪白条
· 视频播放时画面闪烁
· 双屏用户拖窗口到副屏时卡顿
· 游戏窗口化时帧数莫名其妙腰斩
· 桌面偶尔黑一下再恢复

NVIDIA 官方帮助文档里就有「遇到闪烁请关闭 MPO」的条目。

【所以】
**没有上述症状就不要开这一项**，它不会提升性能。
有症状的话这一项往往是特效药。

【风险】
低。关掉后视频播放会多占一点点 GPU，其他没影响。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; Name = 'OverlayTestMode'; Type = 'DWord'; Value = 5; Default = '@DELETE@' }
        )
    }

    # =================================================================
    #  分类三：系统瘦身（关掉吃后台资源的东西）
    # =================================================================

    $tweaks += @{
        Id = 'Telemetry'; Name = '关闭遥测与数据收集服务'
        Category = '系统瘦身'; Risk = '低'; Effect = '中等，减少后台常驻和磁盘写入'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
关掉 Windows 的使用数据上报：

· DiagTrack（连接用户体验和遥测）
  这是后台常驻的大户，会持续收集你用了什么程序、
  出了什么错，定期打包上传。老机器上它的磁盘写入量不小。

· dmwappushservice（设备管理无线应用推送）
  企业设备管理用的，家用完全不需要。

· AllowTelemetry = 0（组策略层面把上报级别调到最低）

【效果】
· 减少 1~2 个常驻后台进程
· 减少持续的小文件磁盘写入（机械盘用户感受更明显）
· 顺带也是隐私上的改善

【会不会影响 Windows 更新】
不会。Windows Update 是独立的服务，不受影响。

【风险】
低。这是被官方文档承认可以关的服务。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
        Services = @(
            @{ Name = 'DiagTrack';          Target = 'Disabled'; Default = 'Automatic' }
            @{ Name = 'dmwappushservice';   Target = 'Disabled'; Default = 'Manual' }
        )
    }

    $tweaks += @{
        Id = 'DeliveryOpt'; Name = '关闭「更新传递优化」的 P2P 上传'
        Category = '系统瘦身'; Risk = '低'; Effect = '省上传带宽 —— 对网游延迟有实际帮助'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
Windows 默认会把你已经下载好的更新文件，**当种子一样上传
给互联网上其他的 Windows 电脑**（微软管这叫「传递优化」）。

对家用宽带来说这是个坑：家宽的上传速度普遍只有下载的
1/10 到 1/20，上传一旦被占满，**下载和网游延迟会跟着一起爆炸**。
很多人「莫名其妙 ping 值突然飙到 200」就是这个原因。

这一项把模式设为 0 = 只从微软官方服务器下载，不做 P2P 上传。

【代价】
基本没有。下载更新时理论上慢一点点，但家用场景感受不到。

【风险】
低。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'BackgroundApps'; Name = '禁止 UWP 应用在后台自动运行'
        Category = '系统瘦身'; Risk = '低'; Effect = '中等，内存小的机器收益明显'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
「邮件」「日历」「天气」「照片」「Xbox」「小娜」这些
系统自带的 UWP 应用，即使你从来没打开过，也会在后台
定期唤醒、联网、刷新内容。

这一项把「允许应用在后台运行」的总开关关掉。

【效果】
· 少掉一批后台进程，内存占用下降（8GB 内存的机器最受益）
· 开机后到「完全可用」的时间变短
· 笔记本待机耗电减少

【会失去什么】
· 邮件 / 日历不会主动推送提醒了（要自己打开才刷新）
· 天气磁贴不会自动更新
· 不影响任何桌面程序（Steam、QQ、微信、浏览器、游戏全不受影响）

【风险】
低。不用 UWP 应用的人（大多数游戏玩家）纯赚。
'@
        Regs = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled';     Type = 'DWord'; Value = 1; Default = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';                       Name = 'BackgroundAppGlobalToggle'; Type = 'DWord'; Value = 0; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'Cortana'; Name = '关闭小娜 Cortana'
        Category = '系统瘦身'; Risk = '低'; Effect = '小幅，少一个常驻进程'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
关掉小娜。在国内中文环境下，小娜的功能基本等于零
（语音助手不可用、网页搜索走必应），但它是个常驻进程，
吃内存也吃一点 CPU。

【关掉后】
· 任务栏搜索框依然能用，只是变成纯本地文件搜索
· 开始菜单搜索不受影响
· 少一个 SearchUI.exe / Cortana.exe 常驻进程

【风险】
低。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'SysMain'; Name = '关闭 SysMain / Superfetch（仅限固态硬盘）'
        Category = '系统瘦身'; Risk = '中'; Effect = '固态上小幅；机械盘上关了会更慢'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
SysMain（老名字叫 Superfetch）会学习你常开哪些程序，
提前把它们预读进内存，让下次打开更快。

【在机械盘上：非常有用，绝对不要关】
机械盘随机读取慢，预读能救命。

【在固态盘上：价值不大】
固态本来就快，预读省下的时间很少，但 SysMain 自己会：
· 持续占用一部分内存做缓存
· 持续在后台做磁盘扫描（表现为开机后磁盘占用 100% 好几分钟）

所以固态用户关掉它，通常能让「开机后立刻可用」的体验变好。

【注意】
本工具检测到你的系统盘是机械盘时，会自动把这一项变灰不让选。

【风险】
中（选错介质的话）。有人关掉后反而觉得开程序慢了，
那就说明你的使用模式受益于它，还原即可。
'@
        Services = @(
            @{ Name = 'SysMain'; Target = 'Disabled'; Default = 'Automatic' }
        )
        Available = { return (Test-SystemDriveIsSSD) }
    }

    $tweaks += @{
        Id = 'WSearch'; Name = '关闭 Windows 搜索索引服务'
        Category = '系统瘦身'; Risk = '中'; Effect = '机械盘 + 老 CPU 上明显；固态上一般'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
Windows 搜索服务会在后台不停地扫描你的硬盘、给每个文件
建立索引，好让你在开始菜单里搜文件时秒出结果。

代价是：它在建索引的时候会**持续占用磁盘和 CPU**。
装了大量文件、或者刚装完系统的头几天，它能把老机器的
磁盘占用顶到 100%，什么都干不了。

【关掉后会怎样】
· 开始菜单搜文件会变慢（从秒出变成要等几秒到十几秒）
· 资源管理器里搜文件变成实时遍历，大文件夹会很慢
· 邮件应用、Outlook 的搜索会变得很难用

【建议】
· 你平时靠 Everything 这类软件搜文件 → 放心关
· 你经常用开始菜单搜文件 → 别关
（顺便一提：Everything 是免费的，比 Windows 搜索好用一百倍，
  装了它再关索引是最优解）

【风险】
中。功能性损失，性能无损失，随时可还原。
'@
        Services = @(
            @{ Name = 'WSearch'; Target = 'Disabled'; Default = 'Automatic' }
        )
    }

    $tweaks += @{
        Id = 'XboxSvc'; Name = '关闭 Xbox 附属服务'
        Category = '系统瘦身'; Risk = '中'; Effect = '小幅，少几个常驻服务'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
关掉三个 Xbox 相关的后台服务：
· XblAuthManager     Xbox 账号认证
· XblGameSave        Xbox 云存档
· XboxNetApiSvc      Xbox 网络连接

【什么时候不能关】
· 你玩 Game Pass / 微软商店买的游戏 —— 不能关，会登录不上
· 你玩《光环》《极限竞速》等需要 Xbox 账号的游戏 —— 不能关
· 你用 Xbox 手柄 —— 可以关（手柄驱动是 XboxGipSvc，
  本工具**不动**那个服务，所以手柄照常能用）

【什么时候可以关】
只玩 Steam / Epic / 战网的单机和网游 —— 可以关。

【效果】
说实话很小，就是少三个闲置服务。不要期待帧数变化。
放进来是因为很多人问。

【风险】
中。关错了表现为 Game Pass 游戏打不开，还原即可。
'@
        Services = @(
            @{ Name = 'XblAuthManager'; Target = 'Disabled'; Default = 'Manual' }
            @{ Name = 'XblGameSave';    Target = 'Disabled'; Default = 'Manual' }
            @{ Name = 'XboxNetApiSvc';  Target = 'Disabled'; Default = 'Manual' }
        )
    }

    # =================================================================
    #  分类四：开机与界面响应
    # =================================================================

    $tweaks += @{
        Id = 'VisualFX'; Name = '视觉特效改为「性能优先」（保留字体平滑）'
        Category = '开机与响应'; Risk = '低'; Effect = '老机器上明显 —— 界面操作立刻变跟手'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
关掉 Windows 界面上那些纯装饰的动画：窗口最小化的飞入飞出、
菜单淡出、任务栏动画、列表淡入、图标阴影……

这些动画每个只有 200 毫秒左右，但它们是**强制等待**的 ——
动画没播完，你就点不了下一个东西。集成显卡或者老显卡上，
它们本身也要占用一点 GPU。

关掉之后最直观的感受：点开始菜单、切窗口、开文件夹，
全都变成「瞬间出现」，主观上机器像换了一台。

【和系统自带的「调整为最佳性能」有什么区别】
系统那个选项会把**字体平滑（ClearType）也一起关掉**，
结果是字全变成锯齿，特别难看，很多人因此不敢用。

这一项是「自定义」模式：关掉所有动画，但
✓ 保留字体平滑（字还是清晰的）
✓ 保留拖动窗口时显示内容（不会变成只有一个框）
✓ 保留缩略图预览（图片文件夹还是能看到预览图）

【风险】
低，纯外观。不喜欢随时还原。
'@
        Regs = @(
            # 3 = 自定义（配合下面的具体开关）
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Type = 'DWord'; Value = 3; Default = 0 }
            # 这串二进制是「关动画但留字体平滑」的标准组合
            @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'UserPreferencesMask'; Type = 'Binary'; Value = ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)); Default = '9e3e078012000000' }
            @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Type = 'String'; Value = '0'; Default = '1' }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations';  Type = 'DWord'; Value = 0; Default = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewAlphaSelect'; Type = 'DWord'; Value = 0; Default = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewShadow';      Type = 'DWord'; Value = 0; Default = 1 }
            # 明确保留：字体平滑 + 拖动时显示窗口内容
            @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'FontSmoothing';    Type = 'String'; Value = '2'; Default = '2' }
            @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'DragFullWindows';  Type = 'String'; Value = '1'; Default = '1' }
        )
    }

    $tweaks += @{
        Id = 'Transparency'; Name = '关闭任务栏 / 开始菜单的毛玻璃透明效果'
        Category = '开机与响应'; Risk = '低'; Effect = '小幅，集成显卡和老显卡上能感觉到'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
Win10 的任务栏、开始菜单、操作中心默认有一层毛玻璃模糊。
这个效果是**实时高斯模糊**，要一直占用 GPU 来算。

在 RTX 显卡上完全无感；但在集成显卡、GT 730、
GTX 750 这一档的老卡上，关掉能省下可测量的 GPU 占用，
开始菜单的弹出也会更干脆。

【关掉后】
任务栏和开始菜单变成纯色（不透明）。有人觉得更好看。

【风险】
低，纯外观。
'@
        Regs = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Type = 'DWord'; Value = 0; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'MenuDelay'; Name = '取消菜单弹出延迟（界面零延迟）'
        Category = '开机与响应'; Risk = '低'; Effect = '手感提升，非常明显'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
Windows 的菜单在鼠标移上去之后，会**故意等 400 毫秒**再弹出。
这个延迟是 Windows 95 时代留下的设计，本意是防止你划过菜单
时误触发一堆子菜单。

现在这个延迟纯粹是碍事。改成 0 之后，右键菜单、开始菜单的
二级菜单全都瞬间弹出。

这是所有优化里**主观感受最强、风险最低**的一项，
很多人第一次改完的反应是「我电脑什么时候这么快了」。

【风险】
零。就是个延迟数字。要重新登录或重启才生效。
'@
        Regs = @(
            @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'String'; Value = '0'; Default = '400' }
        )
    }

    $tweaks += @{
        Id = 'StartupDelay'; Name = '取消开机启动项的 10 秒延迟'
        Category = '开机与响应'; Risk = '低'; Effect = '开机后能更早开始用'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
Win10 为了让桌面先出来，会**故意把所有开机启动项推迟 10 秒**
再启动。所以你会遇到：桌面出来了，但 QQ、微信、输入法、
Steam 都还没起来，要再等十几秒。

这一项把延迟设为 0，桌面出来的同时启动项就开始加载。

【代价】
桌面刚出来的那几秒会更忙一点（因为启动项在同时抢资源），
但「从开机到真正能用」的总时间是变短的。

【注意】
如果你的启动项很多（十几个），建议先去「启动项管理」页
把没用的关掉，再开这一项，效果才好。

【风险】
低。
'@
        Regs = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'FastStartup'; Name = '关闭「快速启动」'
        Category = '开机与响应'; Risk = '低'; Effect = '开机慢几秒，但解决一大堆玄学问题'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
「快速启动」其实是个障眼法：你点关机的时候，Windows 并没有
真的关机，而是把系统内核状态**休眠**到硬盘上；下次开机直接
把它读回来，所以显得快。

问题是：这意味着你的电脑**可能好几个月没有真正重启过**。
由此产生的经典疑难杂症：

· 驱动更新后不生效，必须手动点「重启」才行
· 关机再开机，问题还在；点「重启」问题就没了
· 双系统用户：Windows 关机后 Linux 读不了硬盘（分区被锁）
· 外接设备（网卡、声卡、USB 设备）关机再开就不认了
· 内存占用越用越高，关机也降不下来

关掉之后每次关机都是真关机，上面这些问题基本消失。

【代价】
开机时间增加 3~10 秒（固态硬盘上几乎感觉不到）。

【强烈建议老机器关掉】
老机器的疑难杂症有相当一部分是快速启动造成的。

【风险】
低。这是 Windows 自带的开关。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled'; Type = 'DWord'; Value = 0; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'Hibernate'; Name = '关闭休眠功能（释放 C 盘几个 GB）'
        Category = '开机与响应'; Risk = '低'; Effect = '省空间：释放约等于内存大小的 C 盘空间'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
Windows 会在 C 盘根目录放一个 hiberfil.sys 文件，专门用来存
休眠时的内存镜像。它的大小大约是你内存的 40%~100%：
· 8GB 内存  → 大约 3~6 GB
· 16GB 内存 → 大约 6~12 GB

关闭休眠后这个文件会被删掉，C 盘立刻多出这么多空间。

【关掉后会失去什么】
· 「休眠」选项消失（注意：是休眠，不是睡眠）
  - 睡眠 = 内存保持供电，秒醒，**不受影响**
  - 休眠 = 断电保存到硬盘，开机恢复到关机前状态，**会消失**
· 「快速启动」也会一并失效（它依赖休眠文件）

【建议】
· 台式机：基本没人用休眠，放心关，白赚几个 GB
· 笔记本：如果你习惯合盖放包里第二天接着用，
  那你用的很可能是休眠 —— 别关

【C 盘快满了的话这是最快的一招】
'@
        Apply = {
            Invoke-Native 'powercfg.exe' @('-h', 'off') | Out-Null
            Set-TweakFlag -Id 'Hibernate' -On $true
            Write-Log '休眠已关闭，hiberfil.sys 已删除' '成功'
        }
        Revert = {
            Invoke-Native 'powercfg.exe' @('-h', 'on') | Out-Null
            Set-TweakFlag -Id 'Hibernate' -On $false
            Write-Log '休眠已重新开启' '成功'
        }
        Test = {
            $v = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
            if ($null -eq $v) { return (Get-TweakFlag -Id 'Hibernate') }
            return ($v -eq 0)
        }
    }

    # =================================================================
    #  分类五：输入与网络
    # =================================================================

    $tweaks += @{
        Id = 'MouseAccel'; Name = '关闭鼠标加速（提高指针精确度）'
        Category = '输入与网络'; Risk = '低'; Effect = '射击游戏玩家必做'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
Windows 默认开着「提高指针精确度」，这个名字起得极具误导性，
它的实际作用是**鼠标加速**：你挥得快，指针就走得更远。

意思是「同样挥 10 厘米，快挥和慢挥，准星落点不一样」。
这对射击游戏是灾难 —— 肌肉记忆根本没法形成。

关掉之后，鼠标移动距离和指针位置严格成正比，
练出来的肌肉记忆才是可靠的。

【谁该关】
· 玩 CS / 无畏契约 / APEX / 使命召唤等 FPS —— 必关
· 玩 MOBA、RTS —— 建议关
· 只办公上网 —— 关不关都行，关了刚开始会有点不习惯，
  一两天就适应了，之后回不去

【三个值的含义】
MouseSpeed=0、MouseThreshold1=0、MouseThreshold2=0
就是把加速曲线彻底拉平。

【顺带一提】
关掉加速后，如果觉得指针太慢，去「设置-鼠标」调 DPI /
指针速度，或者用鼠标自带驱动调 DPI —— 那是线性的，没问题。

【风险】
零。
'@
        Regs = @(
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed';      Type = 'String'; Value = '0'; Default = '1' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; Type = 'String'; Value = '0'; Default = '6' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; Type = 'String'; Value = '0'; Default = '10' }
        )
    }

    $tweaks += @{
        Id = 'Nagle'; Name = '关闭 Nagle 算法（降低网游延迟）'
        Category = '输入与网络'; Risk = '中'; Effect = '网游延迟略降；下载大文件效率略降'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
Nagle 算法是 TCP 协议的一个优化：**先攒一攒小数据包，
攒够了再一起发**，这样能减少网络上的碎包，提高整体效率。

但对网游来说这是坏事：游戏发的全是小包（你的每一次移动、
每一次开枪），攒包意味着**你的操作被延迟发送了**。

关掉后每个包立即发出，延迟更低更稳定。

【实际效果有多大】
不要期待 ping 值从 100 变 30。它影响的是**延迟的稳定性**，
典型是降低 5~20ms 的抖动。竞技游戏玩家能感觉到，
休闲玩家基本无感。

【代价】
网络上的小包变多，理论上会让下载大文件的效率降低一点点，
家用带宽下基本测不出来。

【为什么默认不勾】
效果因人而异，而且要重启。属于「想调到极致再说」的项。

【技术细节】
给每个网卡写 TcpAckFrequency=1、TCPNoDelay=1、TcpDelAckTicks=0。
还原时是把这三个值删掉（恢复系统默认行为）。
'@
        Apply = {
            $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            # 只给真正在用的网卡改（注册表里带 IP 地址的那些）
            $targets = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object {
                    $names = (Get-Item -LiteralPath $_.PSPath).GetValueNames()
                    ($names -contains 'DhcpIPAddress') -or ($names -contains 'IPAddress')
                })
            foreach ($t in $targets) {
                # 用 HKLM:\ 形式而不是 PSPath —— PSPath 是
                # 「Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\...」这种长格式，
                # 功能上能用，但会让备份文件里的路径变得又长又难认。
                $p = 'HKLM:\' + ($t.Name -replace '^HKEY_LOCAL_MACHINE\\', '')
                Set-RegValue -Path $p -Name 'TcpAckFrequency' -Type DWord -Value 1
                Set-RegValue -Path $p -Name 'TCPNoDelay'      -Type DWord -Value 1
                Set-RegValue -Path $p -Name 'TcpDelAckTicks'  -Type DWord -Value 0
            }
            Set-TweakFlag -Id 'Nagle' -On $true
            Write-Log "已对 $($targets.Count) 个网卡关闭 Nagle 算法（重启后生效）" '成功'
        }
        Revert = {
            $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            foreach ($t in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
                $p = 'HKLM:\' + ($t.Name -replace '^HKEY_LOCAL_MACHINE\\', '')
                foreach ($n in 'TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks') {
                    # 走 Restore-RegValue 而不是直接删：
                    # 万一这几个值在用本工具之前就已经存在（别的优化软件设过），
                    # 直接删等于把人家的设置也一起抹了。有备份就还原成原值，
                    # 没备份才删掉（那说明本来就没有）。
                    Restore-RegValue -Path $p -Name $n -Type DWord -Default '@DELETE@'
                }
            }
            Set-TweakFlag -Id 'Nagle' -On $false
            Write-Log 'Nagle 算法设置已还原' '成功'
        }
        Test = { return (Get-TweakFlag -Id 'Nagle') }
    }

    $tweaks += @{
        Id = 'FastDNS'; Name = '把 DNS 换成国内公共 DNS'
        Category = '输入与网络'; Risk = '中'; Effect = '网页/登录服务器解析变快，不影响游戏内延迟'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
把网卡的 DNS 从「自动获取」（也就是用你家路由器 / 运营商的）
改成：
    主 DNS：223.5.5.5    （阿里公共 DNS）
    备 DNS：119.29.29.29 （腾讯 DNSPod）

【为什么可能有用】
部分地区运营商的 DNS 服务器又慢又不稳，还可能插广告、
劫持错误页。换成公共 DNS 之后：
· 网页打开更快（省下等待域名解析的时间）
· 游戏登录、更新服务器连接更顺畅
· 少一些莫名其妙打不开的网站

【说清楚：这不会降低游戏内的 ping 值】
DNS 只在「连接建立之前」起作用。游戏连上服务器之后
的延迟和 DNS 一点关系都没有。别被某些「加速器」忽悠。

【什么时候不要改】
· 公司电脑、学校网络 —— 内网域名会解析不了，
  内网系统、共享盘全都访问不了
· 需要通过路由器做广告过滤（如 AdGuard Home、
  软路由分流）—— 改了会绕过它

【还原】
还原会把 DNS 改回「自动获得」。
'@
        Apply = {
            $idx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
            if (-not $idx) { Write-Log '找不到正在使用的网卡，跳过' '警告'; return }
            $old = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4).ServerAddresses
            Set-BackupNote -Key 'DNSOriginal' -Value (@($old) -join ',')
            Set-BackupNote -Key 'DNSInterface' -Value "$idx"
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('223.5.5.5', '119.29.29.29') -ErrorAction Stop
            Set-TweakFlag -Id 'FastDNS' -On $true
            Write-Log "网卡 #$idx 的 DNS 已设为 223.5.5.5 / 119.29.29.29" '成功'
        }
        Revert = {
            $idx = Get-BackupNote -Key 'DNSInterface'
            if (-not $idx) {
                $idx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
            }
            if ($idx) {
                Set-DnsClientServerAddress -InterfaceIndex ([int]$idx) -ResetServerAddresses -ErrorAction SilentlyContinue
                Write-Log "网卡 #$idx 的 DNS 已改回「自动获得」" '成功'
            }
            Set-TweakFlag -Id 'FastDNS' -On $false
        }
        Test = {
            try {
                $idx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
                if (-not $idx) { return $false }
                $cur = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4).ServerAddresses)
                return ($cur -contains '223.5.5.5')
            } catch { return $false }
        }
    }

    # =================================================================
    #  分类六：磁盘与文件系统
    # =================================================================

    $tweaks += @{
        Id = 'NTFSOpt'; Name = 'NTFS 文件系统优化（关闭访问时间戳 / 8.3 短文件名）'
        Category = '磁盘与文件系统'; Risk = '低'; Effect = '机械盘上小幅；大量小文件时明显'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
两个 NTFS 层面的开关：

1. 关闭「最后访问时间」记录
   默认情况下，**你每读一个文件，Windows 就要写一次硬盘**，
   把「最后访问时间」更新一遍。读 1000 个小文件 = 1000 次
   额外写入。游戏加载、编译代码、扫描文件夹时尤其明显。
   99.99% 的人从来不看这个时间戳。关掉。

2. 关闭 8.3 短文件名生成
   为了兼容 1995 年的 DOS 程序，NTFS 在建立每个文件时还要
   额外算一个 "PROGRA~1" 这样的短名字。纯属历史包袱，
   每建一个文件都要多花一点时间。关掉。

【效果】
不会让帧数变高，但会让「大量文件操作」变快：解压、
游戏加载读取大量资源文件、杀毒扫描、编译。
机械盘上比固态上明显。

【风险 / 注意】
· 关闭 8.3 只影响**以后新建的**文件，已有文件的短名不会被删，
  所以不会把已安装的老软件弄坏。
· 极少数 90 年代的老软件、某些老安装包依赖短文件名，
  遇到装不上的情况把这项还原即可。
· 关闭访问时间戳没有任何已知副作用。
'@
        Apply = {
            $a = Invoke-Native 'fsutil.exe' @('behavior', 'set', 'disablelastaccess', '1')
            $b = Invoke-Native 'fsutil.exe' @('behavior', 'set', 'disable8dot3', '1')
            Write-Log "fsutil: $a / $b" '信息'
            Set-TweakFlag -Id 'NTFSOpt' -On $true
            Write-Log 'NTFS 优化已应用（重启后生效）' '成功'
        }
        Revert = {
            Invoke-Native 'fsutil.exe' @('behavior', 'set', 'disablelastaccess', '2') | Out-Null   # 2 = 系统托管（默认）
            Invoke-Native 'fsutil.exe' @('behavior', 'set', 'disable8dot3', '2') | Out-Null        # 2 = 按卷设置（默认）
            Set-TweakFlag -Id 'NTFSOpt' -On $false
            Write-Log 'NTFS 设置已还原为系统默认' '成功'
        }
        Test = {
            $v = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'NtfsDisableLastAccessUpdate'
            if ($null -eq $v) { return $false }
            # ★ 这里有个坑，踩过一次 ★
            # 这个值实际存的是 0x80000001 这种形式：
            #   高位 0x80000000 是「用户托管」标志位（用户手动设过就会带上），
            #   真正的状态码只在最低 2 位：
            #     0 = 托管 + 开启      1 = 托管 + 关闭
            #     2 = 系统管理 + 开启  3 = 系统管理 + 关闭
            # 早期版本直接拿整个值去跟 1/3 比，读到 0x80000001（也就是 -2147483647）
            # 就判成「未优化」—— 明明 fsutil 改成功了，界面却一直显示没生效。
            # 必须先把标志位掩掉再比。
            $state = $v -band 3
            if ($state -ne 1 -and $state -ne 3) { return $false }

            # 8.3 短文件名那一半也要查，两个都改到位才算「已优化」
            # （1 = 所有卷都关闭；3 = 除系统卷外都关闭，也算达标）
            $d8 = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'NtfsDisable8dot3NameCreation'
            if ($null -eq $d8) { return $false }
            $s8 = $d8 -band 3
            return ($s8 -eq 1 -or $s8 -eq 3)
        }
    }

    # =================================================================
    #  分类七：浏览器
    # -----------------------------------------------------------------
    #  这一整组改的都是【微软官方支持的组策略】，注册表位置：
    #      HKLM\SOFTWARE\Policies\Microsoft\Edge
    #  每一条都在 learn.microsoft.com/deployedge 的策略文档里查得到，
    #  不是网上流传的「魔改注册表」。
    #
    #  ⚠ 共同副作用：设了组策略之后，Edge 设置页里对应的开关会变灰，
    #    显示「由你的组织管理」。这是正常现象，不是中毒。
    #    用「还原」清掉策略之后开关就恢复可点。
    # =================================================================

    $tweaks += @{
        Id = 'EdgeBackground'; Name = 'Edge：关掉「关了窗口还在后台跑」'
        Category = '浏览器'; Risk = '低'; Effect = '明显 —— 不用浏览器的时候能省几百 MB'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
Edge 默认开着两个让它「永远不真正退出」的功能：

1. 启动增强（StartupBoost）
   开机后就预先把 Edge 的一部分进程拉起来常驻，这样你点图标的时候
   显得快一点。代价是：**你根本没开浏览器，它也一直占着内存**。

2. 关闭浏览器后继续运行后台扩展
   你把所有 Edge 窗口都叉掉了，它还留一堆进程在后台跑扩展。
   任务管理器里能看到一堆 msedge.exe，很多人以为是中毒了。

这一项把两个都关掉。想用的时候点图标照常打开，只是启动慢个一两秒。

【为什么这条排第一】
内存小的机器上，这是收益最直接的一条 —— 它省的是
「你完全没在用浏览器时」白白占掉的那部分内存。

【官方策略】
StartupBoostEnabled = 0
BackgroundModeEnabled = 0
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'StartupBoostEnabled';  Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BackgroundModeEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeSleepTabs'; Name = 'Edge：开启睡眠标签页，5 分钟不看就冻结'
        Category = '浏览器'; Risk = '低'; Effect = '明显 —— 开一堆标签页时省得最多'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
把「多久没看的标签页自动冻结」这件事打开，并把时间从默认的
**2 小时**缩短到 **5 分钟**。

冻结之后那个标签页的 JavaScript 停止执行、网络请求停掉，
占用的内存大部分被释放。标签页还在，点一下就立刻恢复，
不会丢失你填了一半的表单。

【为什么默认的 2 小时基本等于没开】
很少有人会盯着同一批标签页两小时不动。改成 5 分钟之后，
你切走去干别的，回来内存就已经被回收了 —— 这才是真的省。

【什么时候会不方便】
· 挂着网页版音乐/视频当背景音 —— 会被冻结（不过播放中的
  媒体标签页 Edge 一般不冻，实际影响不大）
· 挂着后台自动刷新的页面（监控面板、抢购页）—— 会停掉

真遇到不想被冻的网站，Edge 设置里可以单独加白名单。

【官方策略】
SleepingTabsEnabled = 1
SleepingTabsTimeout = 300（单位秒，官方允许的档位：30/300/900/1800/3600/7200…）
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SleepingTabsEnabled'; Type = 'DWord'; Value = 1;   Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SleepingTabsTimeout'; Type = 'DWord'; Value = 300; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeBloat'; Name = 'Edge：关掉侧边栏 / 购物助手 / 个性化上报'
        Category = '浏览器'; Risk = '低'; Effect = '中等 —— 少几个常驻组件'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
关掉三个你多半从来不用、但一直在后台待命的 Edge 附加组件：

· 侧边栏（Hubs Sidebar）—— 右边那条常驻栏，里面塞着必应、
  Copilot、游戏、购物等一堆入口。它是**独立进程**，一直占内存。
· 购物助手 —— 逛购物网站时弹优惠券的那个，会在后台分析页面内容。
· 个性化数据上报 —— 把浏览行为上报给微软用于个性化推荐。

【关了会失去什么】
· 侧边栏没了（要用的话还原这一项就回来）
· 不再弹优惠券
· 必应搜索推荐不再个性化

正常浏览、看视频、用扩展全都不受影响。

【官方策略】
HubsSidebarEnabled = 0
EdgeShoppingAssistantEnabled = 0
PersonalizationReportingEnabled = 0
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled';              Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EdgeShoppingAssistantEnabled';    Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'PersonalizationReportingEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeHwAccel'; Name = 'Edge：确保硬件加速没被关掉（看视频必须开）'
        Category = '浏览器'; Risk = '低'; Effect = '看视频卡顿的话，这条是关键'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
强制打开 Edge 的图形硬件加速。

【为什么重要 —— 尤其是刷视频卡的情况】
硬件加速开着的时候，视频解码交给显卡专门的解码单元去做，
CPU 基本不动。关掉之后就变成 **CPU 软解**：一个 1080p 视频
能把老 CPU 吃掉一半以上，表现就是风扇狂转、画面卡顿、
整机发烫。

这个开关经常在两种情况下被关掉：
· 之前显卡驱动出过问题，网上教程让你「关掉硬件加速试试」
· 某些「优化软件」擅自关掉它

所以就算你觉得自己没动过，也值得确认一遍。

【怎么自己验证有没有真的在用显卡解码】
Edge 地址栏输入 edge://gpu ，看「Video Decode」那一行
是不是 Hardware accelerated。播视频的时候打开任务管理器
→ 性能 → GPU，看「Video Decode」那条曲线有没有动。

【官方策略】
HardwareAccelerationModeEnabled = 1
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HardwareAccelerationModeEnabled'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgePreload'; Name = 'Edge：关掉网页预加载'
        Category = '浏览器'; Risk = '低'; Effect = '小幅省内存和流量'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
Edge 会猜你接下来可能点哪个链接，提前把那个网页下载下来。
猜中了就打开得快，猜错了就白下载 —— 白占内存、白耗流量。

【为什么默认不勾】
这一项是拿「内存和流量」换「打开速度」。
内存紧张（8G 及以下）或者用流量上网的机器值得关；
内存充裕的话留着也无妨。

【官方策略】
NetworkPredictionOptions = 2（2 = 从不预测）
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'NetworkPredictionOptions'; Type = 'DWord'; Value = 2; Default = '@DELETE@' }
        )
    }

    # ---------- 深度瘦身档 ----------

    $tweaks += @{
        Id = 'EdgeNewTab'; Name = 'Edge：清空新标签页（关掉资讯瀑布流）'
        Category = '浏览器'; Risk = '低'; Effect = '明显 —— 新标签页从「一直在加载」变成秒开'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
把 Edge 新标签页上那一整片资讯流关掉，变成干净的空白页 + 搜索框。

【为什么这条收益不小】
默认的新标签页不是一个静态页面 —— 它是一个**一直在联网拉内容的
资讯瀑布流**：新闻、图片、视频预览、广告卡片。你每开一个新标签页，
它就在后台拉一遍，往下滚还会无限加载更多。

对内存小的机器，这意味着：
· 每开一个新标签页就多一份持续增长的内存占用
· 一直在跑网络请求和图片解码
· 有些卡片带自动播放的视频

而绝大多数人开新标签页只是为了输个网址。

【关了之后】
资讯瀑布流没了，新标签页秒开。

★ 你自己的那排快捷方式（常用网站磁贴）**会保留** ★
   收藏夹栏也不受影响。

（早期版本把快捷方式一起关掉了，而且是默认勾选的，
  害得人家用惯的那排链接突然消失 —— 已经改掉。
  真想要全空白的，用下面单独那一项「连快捷方式也隐藏」。）

【官方策略】
NewTabPageContentEnabled = 0      资讯流内容
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'NewTabPageContentEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeNewTabBlank'; Name = 'Edge：连快捷方式磁贴也隐藏（新标签页全空白）'
        Category = '浏览器'; Risk = '低'; Effect = '纯观感 —— 对性能几乎没影响'
        Recommended = $false; Reboot = $false
        Detail = @'
★ 这一项默认不勾。想要全空白页再开。★

【这是干什么的】
在上面那条「关掉资讯流」的基础上，把新标签页上**你自己的那排
快捷方式磁贴**也一起藏掉，变成真正的一片空白 + 搜索框。

【先说清楚代价】
你平时点的那排常用网站（自己加的、以及 Edge 按访问频率排的）
**会从新标签页上消失**。

【但是数据不会丢】
这只是「不显示」，不是「删除」——
你的快捷方式和收藏夹都还原样存在 Edge 的配置里。
哪天想要回来，把这一项「还原」，重启 Edge 就全回来了，
一个不少。

【收藏夹栏不受影响】
浏览器顶部那条收藏夹栏是另一回事，这里管不着它。

【官方策略】
NewTabPageQuickLinksEnabled = 0    快速链接磁贴
NewTabPageHideDefaultTopSites = 1  微软预置的推荐网站
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'NewTabPageQuickLinksEnabled';   Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'NewTabPageHideDefaultTopSites'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeExtras'; Name = 'Edge：关掉 Drop / 工作区 / 网页截图 / 推广位'
        Category = '浏览器'; Risk = '低'; Effect = '中等 —— 少一批常驻功能模块'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
关掉四个「微软想推、但你多半没用过」的功能：

· Drop —— Edge 内置的「发给自己」网盘，会常驻同步
· 工作区（Workspaces）—— 多人协作的标签页组
· 网页截图（Web Capture）—— 右键里那个截图工具
· 全页推广 —— 更新后弹出来占满整个标签页介绍新功能的那种页面

【关了会失去什么】
就是这四个功能本身。浏览、扩展、收藏、密码全都不受影响。
右键截图没了可以用 Win+Shift+S（系统自带的，更好用）。

【官方策略】
EdgeEDropEnabled = 0
EdgeWorkspacesEnabled = 0
WebCaptureEnabled = 0
PromotionalTabsEnabled = 0
SpotlightExperiencesAndRecommendationsEnabled = 0
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EdgeEDropEnabled';       Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EdgeWorkspacesEnabled';  Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'WebCaptureEnabled';      Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'PromotionalTabsEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SpotlightExperiencesAndRecommendationsEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeTelemetry'; Name = 'Edge：关掉资源投放服务与必应广告'
        Category = '浏览器'; Risk = '低'; Effect = '小幅 —— 减少后台网络活动'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
· 资源投放服务（Asset Delivery Service）—— Edge 用它在后台下载
  各种功能素材（图标、动画、推荐内容）。关掉就不再拉这些东西。
· 必应广告屏蔽 —— 用必应搜索时不再显示广告结果。

【效果说实话】
省的内存不多，主要是减少后台网络请求。放进「深度瘦身」
是因为它零代价 —— 关了没有任何功能损失。

【官方策略】
EdgeAssetDeliveryServiceEnabled = 0
BingAdsSuppression = 1
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EdgeAssetDeliveryServiceEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BingAdsSuppression';              Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeEfficiency'; Name = 'Edge：效率模式常开（台式机也生效）'
        Category = '浏览器'; Risk = '低'; Effect = '中等 —— 后台标签页更快被压制'
        Recommended = $true; Reboot = $false
        Detail = @'
【这是干什么的】
打开 Edge 的效率模式（新版叫「节能模式」），并设成最激进的档位。

效率模式会降低后台标签页的资源占用：限制它们的 CPU 时间片、
降低后台动画帧率、让不活跃的标签页更快进入睡眠。

【为什么要两个策略一起设 —— 这里有个坑】
微软文档写明：**没有电池的设备（台式机），节能模式在
「AlwaysActive」以外的任何档位都不会生效**。

而 AlwaysActive 这个档位在 Edge 110 之后已经不支持了。

所以台式机要让它真正生效，必须靠 EfficiencyModeEnabled 这个
独立开关把功能本身打开，再用 EfficiencyMode 设档位。
只设其中一个，在台式机上等于白设。

【官方策略】
EfficiencyModeEnabled = 1   把功能打开（台式机的关键）
EfficiencyMode = 5          MaximumSavings，最激进档位
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EfficiencyModeEnabled'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'EfficiencyMode';        Type = 'DWord'; Value = 5; Default = '@DELETE@' }
        )
    }

    # ---------- 极致档（有代价，看清楚再勾）----------

    $tweaks += @{
        Id = 'EdgeProcessPerSite'; Name = 'Edge：同一网站共用一个进程（省约 25% 内存）'
        Category = '浏览器'; Risk = '中'; Effect = '明显 —— 这是单项省内存最多的一条'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
给 Edge 加一个启动参数 --process-per-site。

默认情况下 Chromium 是**一个标签页一个进程**。开 10 个知乎标签页
就是 10 个进程，每个进程都有自己的一份基础开销。
加上这个参数之后，**同一个网站的所有标签页共用一个进程** ——
10 个知乎标签页合并成 1 个进程。

【效果】
Chromium 社区的实测数据是省约 25% 内存，具体取决于你开的标签页
里有多少是同一个网站。习惯开一堆同站标签页的人省得最多。

【代价 —— 必须想清楚】
进程合并了，隔离性就下降了：
· 某个网站的一个标签页崩溃 / 卡死，**同一个网站的所有标签页
  会一起崩**（原来只崩一个）
· 一个吃 CPU 的页面会拖慢同站的其他页面
· 安全隔离变弱（站点之间仍然隔离，同站内部不再隔离）

Chromium 官方的态度是「不建议随便改进程模型，结果不好预测」。
所以这一项默认不勾，放在极致档里。

【怎么实现的 · 局限性】
Edge 没有「设置启动参数」的官方策略，所以这一项是**改快捷方式**：
把参数追加到桌面、开始菜单、任务栏的 Edge 快捷方式上。
原有参数会保留（比如任务栏那个带的 --profile-directory）。

⚠ 局限：只有**从这些快捷方式启动**才生效。
如果你习惯在开始菜单里搜「edge」然后回车，那走的不是快捷方式，
参数不生效。这一点工具没法绕过。

还原时会把参数原样摘掉，其余参数不动。
'@
        Apply = {
            $lnks = Get-EdgeShortcuts
            if ($lnks.Count -eq 0) { Write-Log '没找到任何 Edge 快捷方式，这一项无法应用' '警告'; return }
            # 先把每个快捷方式的原始参数整体备份下来，还原时按原样写回
            $backup = @{}
            foreach ($l in $lnks) { $backup[$l.Path] = $l.Arguments }
            Set-BackupNote -Key 'EdgeShortcutArgs' -Value ($backup | ConvertTo-Json -Compress)
            $n = Set-EdgeShortcutFlag -Flag '--process-per-site' -Add $true
            Set-TweakFlag -Id 'EdgeProcessPerSite' -On $true
            Write-Log "已给 $n 个 Edge 快捷方式加上 --process-per-site（重开浏览器生效）" '成功'
        }
        Revert = {
            $n = Set-EdgeShortcutFlag -Flag '--process-per-site' -Add $false
            Set-TweakFlag -Id 'EdgeProcessPerSite' -On $false
            Write-Log "已从 $n 个 Edge 快捷方式摘掉 --process-per-site" '成功'
        }
        Test = {
            $lnks = @(Get-EdgeShortcuts)
            if ($lnks.Count -eq 0) { return $false }
            # 全部快捷方式都带上了才算「已应用」
            return (@($lnks | Where-Object { $_.Arguments -match '--process-per-site' }).Count -eq $lnks.Count)
        }
    }

    $tweaks += @{
        Id = 'EdgeNoComponentUpdate'; Name = 'Edge：关掉组件后台更新'
        Category = '浏览器'; Risk = '中'; Effect = '小幅 —— 少一个后台更新进程'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
关掉 Edge 的「组件更新」——那是独立于浏览器版本的一套小模块的
自动更新（视频版权模块 Widevine、拼写词典、证书吊销列表、
广告过滤规则等），会在后台定期联网检查和下载。

【关了会怎样 —— 有实际代价】
· Widevine 不更新 → 以后某些正版视频网站（Netflix 这类需要
  DRM 的）可能会放不了
· 证书吊销列表不更新 → 安全性略有下降
· 浏览器本体的版本更新**不受影响**，该更新还是会更新

【所以默认不勾】
省的资源很有限，代价却是实实在在的。
只有在「机器特别弱、而且只用来上普通网站」的情况下才值得。

【官方策略】
ComponentUpdatesEnabled = 0
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'ComponentUpdatesEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'EdgeNoSmartScreen'; Name = 'Edge：关闭 SmartScreen 安全检查'
        Category = '浏览器'; Risk = '高'; Effect = '小幅省资源，但安全性明显下降'
        Recommended = $false; Reboot = $false
        Detail = @'
★ 这一项拿安全换性能，收益很小，代价很大。看清楚再决定。★

【这是干什么的】
关掉 Microsoft Defender SmartScreen。它的工作是：你每打开一个
网址、每下载一个文件，都拿去和微软的恶意网站/恶意文件库比对。

【关了能省多少】
很少。它主要是网络请求，内存占用很低。

【关了的代价】
· 打开钓鱼网站时不再有拦截页
· 下载到恶意文件时不再有警告
· 这是普通用户**最后一道自动防线**

【我的建议：别关】
这一项放进来只是为了「极致瘦身」的完整性。
真正吃内存的是前面那几项，这一项省的那点资源
完全不值得用安全去换。

如果你朋友不太会分辨钓鱼网站，这一项一定不要勾。

【官方策略】
SmartScreenEnabled = 0
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SmartScreenEnabled'; Type = 'DWord'; Value = 0; Default = '@DELETE@' }
        )
    }

    # =================================================================
    #  分类八：激进优化（真能动帧数的，但每条都有明确代价）
    # -----------------------------------------------------------------
    #  这一整组和前面的性质不一样。
    #  前面那些大多是「关掉没人用的东西」，代价接近零；
    #  这一组是【拿安全性、稳定性、功耗去换性能】，
    #  每一条的代价都写在说明里，自己看完再决定。
    #
    #  全部默认不勾，也不进任何预设。
    # =================================================================

    $tweaks += @{
        Id = 'SpectreMitigations'; Name = '关闭 Spectre / Meltdown 漏洞缓解措施'
        Category = '激进优化'; Risk = '高'; Effect = '★ 这一组里最大的一条，老 CPU 上 5%~30%'
        Recommended = $false; Reboot = $true
        Detail = @'
★ 如果你觉得「之前那些优化都没用」，先看这一条。★
  这是所有 Windows 设置里，对 CPU 性能影响最大的一项，
  而且绝大多数人的机器上它是开着的（= 一直在损失性能）。

【这是干什么的】
2018 年爆出的 Spectre / Meltdown 是 CPU 硬件层面的漏洞。
微软的补救办法是在操作系统里加一层「缓解措施」——
本质上是在 CPU 每次做分支预测、每次内核态切换时插入额外检查。

问题是：**这些检查是永久性的运行时开销**。
它影响的是系统调用密集的场景，而游戏恰恰是系统调用大户
（每一帧都要提交绘制命令、读输入、读文件）。

【影响有多大】
和 CPU 代次强相关：
· Intel 6~8 代、AMD Zen1/Zen+ 这些老 U —— 损失最大，
  实测差距能到 15%~30%，尤其体现在 1% Low（卡顿感）
· Intel 10 代以后、AMD Zen3 以后 —— 硬件层面修了一部分，
  损失小一些，大约 3%~8%
· 最新的 CPU —— 影响已经很小

**机器越老，这一条的收益越大。** 朋友那台如果是几年前的，
这可能是唯一一条能让他明显感觉到帧数变化的设置。

【代价 —— 说清楚】
关掉之后，你的 CPU 重新暴露在 Spectre / Meltdown 这类
「推测执行侧信道攻击」下。现实中的风险：
· 这类攻击**需要在你机器上运行恶意代码**才能实施
· 主要威胁场景是多租户云服务器（别人的虚拟机偷你的内存）
· 对单人用的家用电脑，实际被攻击的概率很低，
  但不是零 —— 恶意网页的 JS 理论上可以尝试
· 浏览器厂商已经在自己那层做了缓解（站点隔离），
  所以浏览器场景的风险进一步降低

一句话：**这是拿一个理论风险换实打实的帧数。**
自己判断值不值。

【官方依据，不是野路子】
这两个注册表值是微软官方文档 KB4073119 里写明的，
本来就是给「愿意用安全换性能」的场景准备的开关。
    FeatureSettingsOverride = 3
    FeatureSettingsOverrideMask = 3
（3/3 = 关闭缓解；0/3 = 开启缓解）

【怎么验证真的关掉了】
重启后用管理员 PowerShell 跑：
    Install-Module SpeculationControl -Scope CurrentUser
    Get-SpeculationControlSettings
看那几项是不是变成 False。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Name = 'FeatureSettingsOverride';     Type = 'DWord'; Value = 3; Default = '@DELETE@' }
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Name = 'FeatureSettingsOverrideMask'; Type = 'DWord'; Value = 3; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'GpuMsiMode'; Name = '显卡改用 MSI 中断模式（降低 DPC 延迟）'
        Category = '激进优化'; Risk = '中'; Effect = '帧生成时间更平滑；很多新驱动本来就开着'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
把显卡的中断方式从「传统 IRQ 线」换成 MSI（消息信号中断）。

传统方式下，多个设备共用物理中断线，显卡想找 CPU 的时候
可能要排队等别的设备。MSI 是显卡直接往一个内存地址写消息，
每个设备有自己的通道，不用抢。

【效果】
不会让显卡渲染得更快，**它改善的是帧生成时间的一致性**——
也就是「平均帧数没变，但不那么一顿一顿了」。
如果你的症状是 DPC 延迟高、音频爆音、画面微卡顿，这条有用。

【先看清楚：你可能本来就开着】
现代 N 卡 / A 卡驱动大多默认就启用 MSI 了。
工具会先检测，如果本来就是开的，这一项会显示「已优化」——
那就不用管它，没有额外收益。

【代价】
极少数老硬件 / 老驱动在 MSI 模式下不稳定，表现为
黑屏、花屏甚至蓝屏。真遇到就还原这一项（安全模式里也能还原）。

【官方依据】
MSISupported 是微软驱动开发文档里明确的注册表项：
learn.microsoft.com/windows-hardware/drivers/kernel/
enabling-message-signaled-interrupts-in-the-registry
'@
        Apply = {
            $n = 0
            foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
                if (-not $g.PNPDeviceID) { continue }
                if ($g.Name -match 'Microsoft Basic|Remote|Virtual|IDD|Mirage') { continue }
                $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                try { Set-RegValue -Path $k -Name 'MSISupported' -Type DWord -Value 1; $n++ } catch { Write-Log "给 $($g.Name) 开 MSI 失败：$($_.Exception.Message)" '警告' }
            }
            Set-TweakFlag -Id 'GpuMsiMode' -On $true
            Write-Log "已为 $n 个显卡启用 MSI 中断模式（重启后生效）" '成功'
        }
        Revert = {
            foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
                if (-not $g.PNPDeviceID) { continue }
                $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                Restore-RegValue -Path $k -Name 'MSISupported' -Type DWord -Default '@DELETE@'
            }
            Set-TweakFlag -Id 'GpuMsiMode' -On $false
            Write-Log '显卡中断模式已还原' '成功'
        }
        Test = {
            $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                      Where-Object { $_.PNPDeviceID -and $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|IDD|Mirage' })
            if ($gpus.Count -eq 0) { return $false }
            foreach ($g in $gpus) {
                $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($g.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                if ((Get-RegValue -Path $k -Name 'MSISupported') -ne 1) { return $false }
            }
            return $true
        }
    }

    $tweaks += @{
        Id = 'CoreParking'; Name = '关闭 CPU 核心停放 + 禁止进入空闲状态'
        Category = '激进优化'; Risk = '中'; Effect = '降低调度和唤醒延迟；功耗温度明显上升'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
两件事一起做：

1. 关闭核心停放（Core Parking）
   Windows 为了省电，在负载不高时会把一部分 CPU 核心「停放」
   起来（近似于休眠）。需要用的时候再唤醒——**唤醒是有延迟的**。
   游戏里负载忽高忽低，核心反复停放/唤醒，就会产生微卡顿。
   设成 100% 表示所有核心永远在线待命。

2. 禁止 CPU 进入空闲状态（C-State）
   比上面更激进：连单个核心的低功耗状态都不让进。
   CPU 永远保持在可立即执行的状态，唤醒延迟直接归零。

【效果】
影响的主要是 **1% Low 和帧生成时间的一致性**，
平均帧数变化不大。症状是「平均帧看着挺高但就是一顿一顿」
的机器，这条值得试。

【代价 —— 这条代价很实在】
· **功耗明显上升**，CPU 温度上升
· **笔记本续航会显著缩短**（所以工具只改「接通电源」时的策略，
  用电池时不受影响）
· 散热本来就差的机器，温度上去反而可能触发降频 ——
  **结果是更慢**。老笔记本尤其要小心

如果你的机器已经在 85 度以上跑，**别开这一项**，
先去清灰换硅脂。

【怎么做的】
这两个是 Windows 电源计划里的隐藏设置，工具会先用
powercfg -attributes 把它们从隐藏状态放出来，再设值。
还原时设回默认（核心停放 5%、允许空闲状态）。
'@
        Apply = {
            # 这两个电源设置默认在界面上是隐藏的，先取消隐藏才能设
            Invoke-Native 'powercfg.exe' @('-attributes', 'SUB_PROCESSOR', '0cc5b647-c1df-4637-891a-dec35c318583', '-ATTRIB_HIDE') | Out-Null
            Invoke-Native 'powercfg.exe' @('-attributes', 'SUB_PROCESSOR', '5d76a2ca-e8c0-402f-a133-2158492d58ad', '-ATTRIB_HIDE') | Out-Null
            # CPMINCORES=100（全核常驻）、IDLEDISABLE=1（禁止空闲状态）
            Invoke-Native 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', '0cc5b647-c1df-4637-891a-dec35c318583', '100') | Out-Null
            Invoke-Native 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', '5d76a2ca-e8c0-402f-a133-2158492d58ad', '1') | Out-Null
            Invoke-Native 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT') | Out-Null
            Set-TweakFlag -Id 'CoreParking' -On $true
            Write-Log '已关闭 CPU 核心停放并禁止进入空闲状态（仅接通电源时生效）' '成功'
        }
        Revert = {
            Invoke-Native 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', '0cc5b647-c1df-4637-891a-dec35c318583', '5') | Out-Null
            Invoke-Native 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', '5d76a2ca-e8c0-402f-a133-2158492d58ad', '0') | Out-Null
            Invoke-Native 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT') | Out-Null
            Set-TweakFlag -Id 'CoreParking' -On $false
            Write-Log 'CPU 核心停放和空闲状态已还原为系统默认' '成功'
        }
        Test = { return (Get-TweakFlag -Id 'CoreParking') }
    }

    $tweaks += @{
        Id = 'PageCombining'; Name = '关闭内存页面组合'
        Category = '激进优化'; Risk = '中'; Effect = '省一点 CPU；内存占用会上升'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
Windows 会在后台扫描物理内存，把内容完全相同的内存页合并成一份
（页面组合 / Page Combining），以此节省内存。

代价是：**这个扫描和比对本身要花 CPU**，而且是持续进行的。
你在任务管理器里看到 System 进程莫名占 CPU，有一部分是它。

【什么时候该关】
· 内存充裕（16GB 以上）——关掉，用内存换 CPU，划算
· 内存紧张（8GB 及以下）——**别关**，关了内存占用会上升，
  一旦不够就开始往硬盘倒，那比省下的 CPU 代价大得多

【代价】
内存占用上升（具体多少取决于你开了什么，通常几百 MB）。

【和「关闭内存压缩」的区别】
那是另一件事：内存压缩是把不常用的页压缩起来，
页面组合是把重复的页合并。两个都关最激进，但 8G 机器
两个都不能关。
'@
        Apply  = { try { Disable-MMAgent -PageCombining -ErrorAction Stop; Write-Log '内存页面组合已关闭' '成功' } catch { Write-Log "关闭页面组合失败：$($_.Exception.Message)" '警告' } }
        Revert = { try { Enable-MMAgent  -PageCombining -ErrorAction Stop; Write-Log '内存页面组合已重新开启' '成功' } catch { Write-Log "开启页面组合失败：$($_.Exception.Message)" '警告' } }
        Test   = { try { return (-not (Get-MMAgent -ErrorAction Stop).PageCombining) } catch { return $false } }
    }

    $tweaks += @{
        Id = 'TdrDelay'; Name = '延长显卡超时判定（治「显示驱动已停止响应」）'
        Category = '激进优化'; Risk = '中'; Effect = '修复类 —— 没这个症状就别开'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
Windows 有个 TDR 机制：如果显卡超过 2 秒没响应，就判定它挂了，
强制重置显卡驱动 —— 就是你看到的那句
「显示驱动程序已停止响应并且已恢复」，画面黑一下，
游戏经常直接崩溃退出。

这一项把这个超时从默认的 2 秒延长到 10 秒，
给显卡更多时间把手头的活干完。

【什么时候有用】
· 玩游戏时偶发黑屏 + 「显示驱动已停止响应」
· 跑重负载（高画质、光追、渲染）时崩溃
· 老显卡跑不动新游戏时的偶发崩溃

**没有这些症状就别开**，它不会提升帧数。

【代价】
显卡真的死锁时，你要多等 8 秒才会恢复 ——
在那 8 秒里整个画面是卡住的。
这是拿「偶尔多卡几秒」换「不要直接崩溃退出游戏」。

【注意：这只是缓解，不是根治】
频繁出现 TDR 通常意味着更底层的问题：显卡超频不稳、
显存有问题、供电不足、驱动 bug、显卡过热。
延长超时只是让它不那么容易触发。
真的频繁崩，该查硬件还是要查。

【注册表】
HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\TdrDelay = 10
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'TdrDelay'; Type = 'DWord'; Value = 10; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'DefenderRealtime'; Name = '关闭 Windows Defender 实时保护'
        Category = '激进优化'; Risk = '高'; Effect = '游戏加载和读图明显变快；但机器等于裸奔'
        Recommended = $false; Reboot = $false
        Detail = @'
★★ 这是整个工具里代价最大的一项。看完再决定。★★

【这是干什么的】
关掉 Windows Defender 的实时监控。

【为什么它影响性能】
实时保护的工作方式是：**每一次文件读写都要先过一遍扫描**。
游戏加载时要读几千上万个资源文件，每一个都被拦下来检查一遍，
读图时间明显变长。运行中的游戏流式加载贴图时也会受影响。

这也是为什么「把游戏文件夹加进白名单」有效 ——
那其实是这一项的温和版。

【代价 —— 完整说清楚】
· 你的电脑将**没有任何实时病毒防护**
· 下载的文件不再被扫描
· 运行恶意程序时不会被拦
· 浏览器下载、U 盘插入、解压文件，全都不设防

【强烈建议先用温和版】
「系统体检」页有一个「把游戏文件夹加入杀毒白名单」，
那个只对你指定的游戏目录免检，其余照常保护 ——
**性能收益的大部分都能拿到，风险几乎为零**。

除非你：
· 装了别的杀毒软件（那 Defender 本来就该关）
· 或者非常清楚自己在干什么

否则请用白名单，别用这一项。

【篡改保护会挡住这个操作】
Windows 11 / 较新的 Win10 默认开着「篡改保护」，
它会阻止任何程序（包括本工具）修改 Defender 设置。
需要你先手动关掉：
  Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 篡改保护 → 关

工具检测到篡改保护开着时会直接告诉你，不会假装成功。

【还原】
随时可以还原。另外 Defender 有个特性：实时保护被关掉后，
系统在一段时间后可能会自己重新打开它。
'@
        Apply = {
            try {
                $st = Get-MpComputerStatus -ErrorAction Stop
                if ($st.IsTamperProtected) {
                    Write-Log '关闭实时保护失败：系统开着「篡改保护」。请先在 Windows 安全中心 → 病毒和威胁防护 → 管理设置 里关掉篡改保护，再回来应用这一项。' '警告'
                    return
                }
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
                Set-TweakFlag -Id 'DefenderRealtime' -On $true
                Write-Log 'Windows Defender 实时保护已关闭 —— 机器目前没有实时病毒防护' '警告'
            } catch {
                Write-Log "关闭实时保护失败：$($_.Exception.Message)" '错误'
            }
        }
        Revert = {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Set-TweakFlag -Id 'DefenderRealtime' -On $false
                Write-Log 'Windows Defender 实时保护已重新开启' '成功'
            } catch { Write-Log "开启实时保护失败：$($_.Exception.Message)" '错误' }
        }
        Test = {
            try { return ((Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled -eq $false) } catch { return $false }
        }
        Available = { try { $null = Get-MpComputerStatus -ErrorAction Stop; return $true } catch { return $false } }
    }

    $tweaks += @{
        Id = 'PowerThrottlingOff'; Name = '关闭 CPU 电源限流（Power Throttling）'
        Category = '激进优化'; Risk = '中'; Effect = '笔记本上效果明显；后台程序不再被降频'
        Recommended = $false; Reboot = $true
        Detail = @'
【这是干什么的】
Windows 10 之后有个叫 Power Throttling 的机制：系统自己判断
「这个程序不重要」，就把它丢到 CPU 的低功耗核心/低频状态上跑，
用来省电。

问题是它**判断得并不准**。常见的踩坑：
· 游戏的后台线程（音频、网络、资源加载）被判成不重要 → 卡顿
· 挂在后台的语音软件（YY / Discord）被降频 → 声音断断续续
· 串流、录制软件被降频 → 掉帧

关掉之后，所有进程都按正常调度跑，系统不再自作主张。

【效果】
**笔记本上最明显**，因为笔记本的省电策略比台式机激进得多。
台式机上影响小一些。

同样主要改善的是**一致性**（不卡顿、不断流），
平均帧数变化不大。

【代价】
· 功耗上升，笔记本续航缩短
· 温度上升 —— 散热差的机器要留意

【和「关闭核心停放」的区别】
核心停放管的是「几个核心在线」，
Power Throttling 管的是「某个程序准不准跑满频」。
两件事，可以一起开，也可以只开一个。

【注册表】
HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling
  PowerThrottlingOff = 1
这是微软官方文档里写明的开关。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'GlobalTimerRes'; Name = '恢复全局定时器精度（Win10 2004 之后的回退开关）'
        Category = '激进优化'; Risk = '中'; Effect = '有人明显改善卡顿，有人完全没感觉 —— 要实测'
        Recommended = $false; Reboot = $true
        Detail = @'
【先说清楚：这一条要自己实测，不保证有效】
它在 FPS 玩家圈子里争议很大，有人说立竿见影，有人说毫无变化。
原因见下面，是机制决定的。

【背景】
Windows 用一个「定时器精度」来决定线程被唤醒的最小时间颗粒。
默认是 15.6 毫秒，程序可以申请提高到 1 毫秒甚至更细，
游戏和音频软件普遍会申请。

**Windows 10 版本 2004 改了规则**：
以前一个程序申请了高精度，**全系统**都享受；
2004 之后改成**只有申请的那个程序自己**享受，
其他进程还是 15.6ms。

微软同时留了一个开关，可以把行为改回老样子 ——
就是这一项。

【为什么有人有效有人没效】
· 如果你的游戏**自己就申请了**高精度定时器 —— 它本来就是快的，
  开这个没有额外收益，你不会感觉到变化
· 如果你的游戏**没申请**，但你开着某个申请了的软件 ——
  开这个之后游戏能蹭到，会有改善
· 如果两边都没申请 —— 没变化

所以这不是「一定涨帧」的开关，是「有可能解锁一点一致性」的开关。

【代价】
· 全局高精度定时器会**增加一点 CPU 唤醒次数和功耗**
· 笔记本续航略降
· 极少数情况下反而变差（系统开销大于收益）——
  所以要实测，觉得没用就还原

【怎么实测】
开之前和开之后各跑一次同样的场景，看 1% Low 和帧生成时间曲线
（游戏内帧数显示 / N 卡的性能叠加层都能看）。
只看平均帧数很可能看不出区别。

【注册表】
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel
  GlobalTimerResolutionRequests = 1
这是微软自己为了兼容性留的官方开关。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Name = 'GlobalTimerResolutionRequests'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'NoAutoDriverUpdate'; Name = '禁止 Windows 更新自动覆盖显卡驱动'
        Category = '激进优化'; Risk = '低'; Effect = '防止帧数某天突然掉下来'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
阻止 Windows Update 自动给你装显卡驱动。

【为什么要管这个】
这是一个很多人栽过、但从来想不到原因的坑：

你在官网装了最新的显卡驱动，一切正常。
过几天 Windows 自动更新，**悄悄把你的驱动换成了微软仓库里
那个更老的 WHQL 版本**。你什么都没干，帧数就掉了，
或者开始花屏、黑屏、游戏崩溃。

更烦的是它会反复干这件事 —— 你装回去，它下次更新又换掉。

【开了这一项之后】
显卡驱动完全由你自己控制：想更新就去 N 卡 / A 卡官网下载。
Windows 不再插手。

【代价】
· 你得**自己记得更新驱动**。新游戏发售时的优化驱动要手动装
· 其他硬件（网卡、声卡、打印机）的驱动也一并不再自动更新 ——
  一般没影响，但万一插了新设备没驱动，要自己去装

【建议】
装机/重装系统之后先去官网装好显卡驱动，再开这一项锁住。

【注册表】
· DriverSearching\SearchOrderConfig = 0
    （不从 Windows Update 找驱动）
· Policies\...\WindowsUpdate\ExcludeWUDriversInQualityUpdate = 1
    （质量更新里不带驱动）
两个都是微软文档化的策略项。
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; Name = 'SearchOrderConfig'; Type = 'DWord'; Value = 0; Default = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ExcludeWUDriversInQualityUpdate'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    $tweaks += @{
        Id = 'DefenderCloud'; Name = '关闭 Defender 云查杀与样本上传（保留本地防护）'
        Category = '激进优化'; Risk = '中'; Effect = '★ 「关掉实时保护」的温和替代品，先试这个'
        Recommended = $false; Reboot = $false
        Detail = @'
★ 如果你在考虑「关闭 Defender 实时保护」，先看这一条。★

【这是干什么的】
只关掉 Defender 的两个联网功能，**本地的病毒特征库扫描照常工作**：

1. 云查杀（MAPS / 云提供的保护）
   遇到不认识的文件时，Defender 会连微软服务器问一下。
   问的时候**文件会被挂起等待结果**，这就是卡顿的来源。
   网络不好时这个等待可能有好几秒。

2. 自动样本提交
   把它认为可疑的文件直接上传给微软。

【为什么这条值得先试】
「启动游戏时卡好几秒」「解压大文件时卡住」这类症状，
很大一部分是云查杀在等网络，**不是本地扫描慢**。
关掉这两个，卡顿改善明显，而本地防护一点没少。

【代价 —— 比全关实时保护小得多】
· 对**全新出现、特征库还没收录**的病毒，检出率会下降。
  云查杀的价值就在于应对零日样本
· 本地特征库仍然每天更新，已知病毒照样拦得住

【三个档位，自己选】
  最安全 ── 什么都不关，只把游戏文件夹加白名单（体检页有）
  中间档 ── 就是这一项：关云查杀，留本地防护  ← 推荐从这里开始
  最激进 ── 关闭实时保护（上面那一项），等于完全不设防

【篡改保护】
和上一项一样，系统开着「篡改保护」时改不了，
工具会直接告诉你，不会假装成功。
'@
        Apply = {
            try {
                $st = Get-MpComputerStatus -ErrorAction Stop
                if ($st.IsTamperProtected) {
                    Write-Log '关闭云查杀失败：系统开着「篡改保护」。请先在 Windows 安全中心 → 病毒和威胁防护 → 管理设置 里关掉篡改保护。' '警告'
                    return
                }
                Set-MpPreference -MAPSReporting 0 -SubmitSamplesConsent 2 -ErrorAction Stop
                Set-TweakFlag -Id 'DefenderCloud' -On $true
                Write-Log 'Defender 云查杀与样本上传已关闭（本地实时防护仍然开着）' '成功'
            } catch { Write-Log "关闭云查杀失败：$($_.Exception.Message)" '错误' }
        }
        Revert = {
            try {
                Set-MpPreference -MAPSReporting 2 -SubmitSamplesConsent 1 -ErrorAction Stop
                Set-TweakFlag -Id 'DefenderCloud' -On $false
                Write-Log 'Defender 云查杀已恢复' '成功'
            } catch { Write-Log "恢复云查杀失败：$($_.Exception.Message)" '错误' }
        }
        Test = {
            try { return ((Get-MpPreference -ErrorAction Stop).MAPSReporting -eq 0) } catch { return $false }
        }
        Available = { try { $null = Get-MpComputerStatus -ErrorAction Stop; return $true } catch { return $false } }
    }

    $tweaks += @{
        Id = 'ErrorReporting'; Name = '关闭 Windows 错误报告'
        Category = '激进优化'; Risk = '低'; Effect = '游戏崩溃后不再卡住几十秒收集数据'
        Recommended = $false; Reboot = $false
        Detail = @'
【这是干什么的】
关掉 Windows 错误报告（WER）。

【为什么影响体验】
程序崩溃时，WER 会：
· 把整个进程的内存快照**写到硬盘上**（几百 MB 到几个 GB）
· 然后尝试上传给微软

游戏崩溃本来就烦，崩完之后机器还要卡住几十秒写 dump 文件 ——
就是它干的。而且这些 dump 堆在 C 盘慢慢占空间。

【代价】
· 崩溃信息不再自动收集。如果你想**自己排查**某个程序为什么崩，
  没有 dump 文件可看
· 「可靠性监视器」里的记录会变少

一般人用不到那些 dump，关掉没损失。
真要排查问题时，把这一项还原回去复现一次就行。

【注册表】
HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Disabled = 1
'@
        Regs = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Type = 'DWord'; Value = 1; Default = '@DELETE@' }
        )
    }

    # =================================================================
    #  分类九：修复（把被别的「优化软件」改坏的地方改回来）
    # =================================================================

    $tweaks += @{
        Id = 'FixBadTweaks'; Name = '修复被「优化大师」类软件改坏的开机参数'
        Category = '修复'; Risk = '低'; Effect = '如果中招了，效果非常明显'
        Recommended = $true; Reboot = $true
        Detail = @'
【这是干什么的】
市面上大量「游戏加速器」「优化大师」会往开机配置（BCD）里
写几个参数，声称能提速，实际上**全都是有害的**。
这一项把它们删掉，恢复 Windows 默认行为。

会检查并清除的参数：

1. useplatformclock = yes  ← 最大的坑
   强制系统用 HPET（高精度事件计时器）做主时钟。
   HPET 读一次的开销比默认的 TSC 高一个数量级，结果是
   **帧生成时间抖动变大，游戏出现规律性微卡顿**。
   这是被 AMD、Intel、无数评测反复证实的负优化。
   如果你朋友的机器有「莫名其妙一顿一顿」的症状，
   八成就是这个。

2. useplatformtick / tscsyncpolicy / disabledynamictick
   同一类计时器相关的瞎改，一并清掉。

3. numproc / onecpu（限制启动时使用的 CPU 核心数）
   有些人在 msconfig 里手贱勾了「处理器个数」，
   以为是「解锁核心」，其实是**限制核心**。
   勾了之后系统启动时只用指定数量的核心。
   清掉之后恢复使用全部核心。

4. truncatememory / removememory（限制可用内存）
   同上，msconfig 里的「最大内存」，勾了会白白浪费内存。

【怎么判断自己中没中招】
点这一项旁边的「检测」，工具会告诉你有没有这些参数。
状态显示「已优化」= 干净，没中招。

【风险】
低。这是在**删除**非默认配置，让系统回到出厂行为。
'@
        Apply = {
            $params = @('useplatformclock', 'useplatformtick', 'tscsyncpolicy', 'disabledynamictick', 'numproc', 'onecpu', 'truncatememory', 'removememory')
            $removed = @()
            foreach ($p in $params) {
                $r = Invoke-Native 'bcdedit.exe' @('/deletevalue', $p)
                if ($r -notmatch '找不到|not found|无法找到|element') { $removed += $p }
            }
            Set-TweakFlag -Id 'FixBadTweaks' -On $true
            if ($removed.Count -gt 0) {
                Write-Log "已清除有害开机参数：$($removed -join ', ')（重启后生效）" '成功'
            } else {
                Write-Log '检查完毕：开机参数是干净的，没有被乱改过' '成功'
            }
        }
        Revert = {
            Set-TweakFlag -Id 'FixBadTweaks' -On $false
            Write-Log '这一项是「清理有害设置」，没有还原的必要（也不建议把坑再挖回去）' '信息'
        }
        Test = {
            $enum = Invoke-Native 'bcdedit.exe' @('/enum', '{current}')
            foreach ($p in 'useplatformclock', 'useplatformtick', 'tscsyncpolicy', 'disabledynamictick', 'numproc', 'onecpu', 'truncatememory', 'removememory') {
                if ($enum -match $p) { return $false }
            }
            return $true
        }
    }

    # =================================================================
    #  分类十：安全性权衡（收益大，但要想清楚）
    # =================================================================

    $tweaks += @{
        Id = 'VBS'; Name = '关闭「内核隔离 / 内存完整性」(VBS + HVCI)'
        Category = '安全性权衡'; Risk = '高'; Effect = 'CS2 实测约 +25 帧；无畏契约国服/三角洲是启动硬性要求'
        Recommended = $false; Reboot = $true
        Detail = @'
【★ 玩腾讯系 FPS 的话，这一项不是优化，是必须做 ★】
无畏契约【国服】和三角洲行动都用腾讯 ACE 反作弊。
ACE 需要独占 CPU 虚拟化来对抗 DMA 硬件外挂，
所以内存完整性(HVCI)开着的时候，游戏会弹
「CPU虚拟化未开启或被其他软件占用」，**根本进不去**。
腾讯游戏安全中心的官方文档就是让你关掉它。

CS2 这边虽然不强制，但第三方实测关掉后平均帧数约 +25 帧，
是单项收益最大的 Windows 设置。

⚠ 唯一的反例：【国际服】Valorant 用的是 Riot 自家的 Vanguard，
   要求正好相反 —— 必须开着内存完整性，关了会报
   "VAN: RESTRICTION - HVCI"。要玩国际服就把这一项还原回去。

⚠ 还有一件事工具改不了：ACE 同时要求 BIOS 里的虚拟化是【开】的
   （Intel 开 VT-x + VT-d，AMD 开 SVM + IOMMU）。
   方向别搞反：BIOS 里要开，Windows 里要关。
   「系统体检」页会检测并告诉你当前状态。

────────────────────────────────

【这是干什么的】
VBS（基于虚拟化的安全性）和 HVCI（内存完整性）是 Windows
用硬件虚拟化做的一层安全防护，用来防止恶意驱动篡改内核。

它的代价是：**所有内存访问都要多过一层虚拟化转换**。
微软自己承认会带来性能损失，第三方评测普遍测到游戏
帧数下降 5%~15%，老 CPU 上损失更大。

Win11 和部分预装 Win10 的品牌机默认是开着的。

【关掉的收益】
如果你的机器开着 VBS，关掉是这份清单里**收益最大的单项**，
远超所有注册表小改动加起来。

【关掉的代价 —— 请认真读】
· 系统的安全防护等级会下降。具体来说，恶意的内核级驱动
  更容易得手。日常上网、装正规软件的风险增加不大，
  但如果你会去下载来路不明的破解补丁、外挂、驱动级工具，
  那这层防护是有意义的。
· 部分带反作弊的网游（如《无畏契约》《使命召唤》）
  在 Win11 上可能**要求开启**，关了会进不去游戏。
  遇到这种情况把它还原就行。

【怎么先确认自己开着没】
这一项的状态如果显示「已优化」，说明本来就是关的，
不用管它，也不会有收益。

【风险】
高（安全层面，不是稳定性层面）。系统不会坏，随时能还原。
'@
        Regs = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Name = 'Enabled'; Type = 'DWord'; Value = 0; Default = 1 }
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'; Name = 'EnableVirtualizationBasedSecurity'; Type = 'DWord'; Value = 0; Default = 1 }
        )
    }

    $tweaks += @{
        Id = 'HyperV'; Name = '关闭 Hyper-V 虚拟化层'
        Category = '安全性权衡'; Risk = '高'; Effect = '无畏契约国服/三角洲的启动硬性要求；用 WSL 的人会坏事'
        Recommended = $false; Reboot = $true
        Detail = @'
【★ 和上一项配套，玩腾讯系 FPS 必须做 ★】
Hyper-V 开着的时候，它会把 CPU 的虚拟化功能【独占】走。
腾讯 ACE 反作弊（无畏契约国服 / 三角洲行动）也要用虚拟化，
拿不到就弹「CPU虚拟化未开启或被其他软件占用」，游戏起不来。

官方给的命令就是这一项做的事：
    bcdedit /set hypervisorlaunchtype off

所以「关闭内核隔离」+「关闭 Hyper-V」这两项通常要一起做，
勾上之后重启一次。

────────────────────────────────

【这是干什么的】
执行 bcdedit /set hypervisorlaunchtype off，让 Windows 开机时
不加载 Hyper-V 虚拟机监控程序。

【什么时候该关 —— 收益很大】
· 你用**安卓模拟器**（雷电、MuMu、夜神、BlueStacks）
  模拟器需要独占 CPU 的虚拟化指令。Hyper-V 开着的时候
  模拟器只能退回软件模拟模式，慢到没法用，还会疯狂占 CPU。
  关掉 Hyper-V 后模拟器速度是几倍的差距。
· 你用 VMware / VirtualBox 装虚拟机 —— 同理。
· 你只是打游戏，从来不用上面这些 —— 关掉能顺带省掉
  虚拟化层的一点点开销。

【什么时候千万别关 —— 会直接坏事】
· 你用 WSL / WSL2（在 Windows 里跑 Linux）→ 会完全用不了
· 你用 Docker Desktop → 会完全用不了
· 你用 Windows 沙盒 / Hyper-V 虚拟机 → 会完全用不了
· 你开着「内存完整性」→ 它依赖 Hyper-V，会一起失效

【提醒】
这一项和上面的「关闭内核隔离」是两件事，但方向一致。
如果你两个都要关，一起勾上重启一次就行。

【风险】
高（功能层面）。还原就是把它设回 auto，重启即可。
'@
        Apply = {
            $r = Invoke-Native 'bcdedit.exe' @('/set', 'hypervisorlaunchtype', 'off')
            Write-Log "bcdedit: $r" '信息'
            Set-TweakFlag -Id 'HyperV' -On $true
            Write-Log 'Hyper-V 虚拟化层已关闭（重启后生效）' '成功'
        }
        Revert = {
            Invoke-Native 'bcdedit.exe' @('/set', 'hypervisorlaunchtype', 'auto') | Out-Null
            Set-TweakFlag -Id 'HyperV' -On $false
            Write-Log 'Hyper-V 虚拟化层已恢复（重启后生效）' '成功'
        }
        Test = {
            $enum = Invoke-Native 'bcdedit.exe' @('/enum', '{current}')
            return ($enum -match 'hypervisorlaunchtype\s+Off')
        }
    }

    return $tweaks
}


# =====================================================================
#  统一的「应用 / 还原 / 检测」入口
# =====================================================================

function Test-TweakApplied {
    <# 返回 $true 表示这一项当前已经处于「已优化」状态 #>
    param($Tweak)
    try {
        if ($Tweak.Test) { return [bool](& $Tweak.Test) }

        $hasCheck = $false
        foreach ($r in $Tweak.Regs) {
            $hasCheck = $true
            $cur = Get-RegValue -Path $r.Path -Name $r.Name
            if ($null -eq $cur) { return $false }
            if ($r.Type -eq 'Binary') {
                if ((Convert-BytesToHex $cur) -ne (Convert-BytesToHex $r.Value)) { return $false }
            } elseif ("$cur" -ne "$($r.Value)") { return $false }
        }
        foreach ($s in $Tweak.Services) {
            $mode = Get-ServiceStartMode -Name $s.Name
            if ($null -eq $mode) { continue }    # 服务不存在就不算数
            $hasCheck = $true
            $want = if ($s.Target -eq 'Automatic') { 'Auto' } else { $s.Target }
            if ($mode -ne $want) { return $false }
        }
        if (-not $hasCheck) { return (Get-TweakFlag -Id $Tweak.Id) }
        return $true
    } catch {
        return $false
    }
}

function Test-TweakAvailable {
    param($Tweak)
    if (-not $Tweak.Available) { return $true }
    try { return [bool](& $Tweak.Available) } catch { return $true }
}

function Invoke-TweakApply {
    param($Tweak)
    try {
        foreach ($r in $Tweak.Regs) {
            Set-RegValue -Path $r.Path -Name $r.Name -Type $r.Type -Value $r.Value
        }
        foreach ($s in $Tweak.Services) {
            Set-ServiceStartup -Name $s.Name -Target $s.Target | Out-Null
        }
        if ($Tweak.Apply) { & $Tweak.Apply }
        Write-Log "已应用：$($Tweak.Name)" '成功'
        return $true
    } catch {
        Write-Log "应用失败 [$($Tweak.Name)]：$($_.Exception.Message)" '错误'
        return $false
    }
}

function Invoke-TweakRevert {
    param($Tweak)
    try {
        if ($Tweak.Revert) { & $Tweak.Revert }
        foreach ($r in $Tweak.Regs) {
            Restore-RegValue -Path $r.Path -Name $r.Name -Type $r.Type -Default $r.Default
        }
        foreach ($s in $Tweak.Services) {
            Restore-Service -Name $s.Name -Default $s.Default | Out-Null
        }
        Write-Log "已还原：$($Tweak.Name)" '成功'
        return $true
    } catch {
        Write-Log "还原失败 [$($Tweak.Name)]：$($_.Exception.Message)" '错误'
        return $false
    }
}
