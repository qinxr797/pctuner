#Requires -Version 5.1
<#
=====================================================================
  超频陪练 + 厂商软件识别
---------------------------------------------------------------------
  【这个模块一行注册表都不写，一个显卡参数都不调】

  它只做两件事：
    1. 认出你这块显卡属于哪一类，告诉你每个滑块是干什么的、
       从多少起步、怎么一步步试、崩了怎么办
    2. 认出你这台机器是哪家的，告诉你该装哪个厂商工具

  为什么不做成「一键超频」：
    · 每块芯片的体质不一样（业内叫「硅片彩票」），
      网上抄来的数值在你这块卡上可能第一分钟就花屏
    · 超频必须边调边测，测的是**你自己玩的那个游戏**，
      没有人能替你按下那个「稳不稳」的判断
    · 工具里内置一个能改显卡频率的功能，等于给自己埋一个
      「按了之后电脑黑屏」的雷 —— 这个工具的底线是可还原，
      而显存超过头造成的画面错乱是软件还原不回来的

  所以这里的定位是**陪练**：把行家脑子里那套流程写成大白话，
  让没经验的人也能自己动手，而且知道自己在动什么。
=====================================================================
#>

function Get-OcVram {
    <#
      读显存容量，单位 GB。读不准就返回 $null —— 宁可不显示，也不给假数字。

      【不能用 Win32_VideoController.AdapterRAM】
        那个字段是 32 位无符号整数，**顶就是 4294967295**。
        8G、12G、16G 的卡一律报成 4 GB —— 不是读不到，是读出来一个
        看着很合理的错数字，这种最坑人。
        （RTX 3070 Laptop 实测：真实 8 GB，AdapterRAM 报 4 GB。）

      正确的来源是注册表里的 qwMemorySize，那是 64 位的。
    #>
    param($Controller)
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        # ★ 这里必须用 SilentlyContinue，不能用 Stop ★
        #   这个键下面有几个子键的 ACL 是限制访问的，非管理员枚举时
        #   会中途抛「Requested registry access is not allowed」。
        #   用 Stop 的话一抛就整个放弃，连读得到的那几个也拿不到了。
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            # 对上型号再取，否则双显卡机器会拿错那一块
            if ($Controller -and "$($p.DriverDesc)" -ne "$($Controller.Name)") { continue }
            $q = $p.'HardwareInformation.qwMemorySize'
            if ($q -and [double]$q -gt 0) { return [math]::Round([double]$q / 1GB, 1) }
        }
    } catch { }
    return $null
}

function Get-OcGpuInfo {
    <#
      认卡。返回 @{ Name; Vendor; Class; IsLaptop; Vram; Driver; Tool }
        Vendor —— NVIDIA / AMD / Intel / 未知
        Class  —— 独显 / 核显
      读不到就老实返回 $null，不猜。
    #>
    $r = @{ Name = $null; Vendor = '未知'; Class = '核显'; IsLaptop = $false; Vram = $null; Driver = $null; Tool = $null }
    try {
        $all = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|IDD|Mirage|Parsec' })
        if ($all.Count -eq 0) { return $null }
        # 有独显就说独显 —— 双显卡机器上用户想超的是那块独显
        $d = $all | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc' } | Select-Object -First 1
        if ($d) { $r.Class = '独显' } else { $d = $all[0] }
        $r.Name = "$($d.Name)"
        $r.Driver = "$($d.DriverVersion)"
        $r.Vram = Get-OcVram -Controller $d
    } catch { return $null }

    if ($r.Name -match 'NVIDIA|GeForce|RTX|GTX|MX\d') { $r.Vendor = 'NVIDIA' }
    elseif ($r.Name -match 'AMD|Radeon')              { $r.Vendor = 'AMD' }
    elseif ($r.Name -match 'Intel|Arc|UHD|Iris')      { $r.Vendor = 'Intel' }

    try { $r.IsLaptop = [bool](Test-IsLaptop) } catch { }

    $r.Tool = switch ($r.Vendor) {
        'NVIDIA' { 'MSI Afterburner' }
        'AMD'    { 'AMD Software（驱动自带，不用另外装）' }
        default  { $null }
    }
    return $r
}

function Get-OcPlan {
    <#
      按卡的类型给一套调试方案。
      返回一串 @{ Kind; Title; Text }，Kind 决定界面上那张卡片的颜色：
        动手 —— 可以调的滑块
        当心 —— 风险和限制
        步骤 —— 操作流程
        信息 —— 背景知识
    #>
    $g = Get-OcGpuInfo
    $out = New-Object System.Collections.ArrayList
    function Add-P { param($Kind, $Title, $Text) [void]$out.Add([PSCustomObject]@{ Kind = $Kind; Title = $Title; Text = $Text }) }

    if (-not $g -or -not $g.Name) {
        Add-P '当心' '没认出显卡' @'
读不到显卡型号，没法给针对性的建议。

通常是驱动没装好。先去设备管理器看一眼「显示适配器」下面
是不是有个带感叹号的项，有的话先把驱动装上再回来。
'@
        return $out
    }

    # ---------- 先说清这块卡是什么 ----------
    $vram = if ($g.Vram) { "，显存约 $($g.Vram) GB" } else { '' }
    $body = if ($g.IsLaptop) { '笔记本' } else { '台式机' }
    Add-P '信息' "你这块卡：$($g.Name)" @"
$body 上的$($g.Class)$vram。驱动版本 $($g.Driver)。

下面这些建议是照着这块卡的类型给的。
"@

    # ---------- 核显：直说不值得 ----------
    if ($g.Class -eq '核显') {
        Add-P '当心' '核显没有超频这回事，别浪费时间' @'
核显（CPU 里自带的那块显示核心）的频率是跟着 CPU 的功耗和温度走的，
没有独立的频率滑块可以调。网上那些「核显超频教程」调的其实是
BIOS 里的内存频率和功耗墙，收益极小，翻车概率却不低。

想让核显跑得快一点，真正管用的只有三条：
· 内存插成双通道（核显没有自己的显存，用的就是内存，单通道直接砍一半带宽）
· 内存开 XMP / DOCP（同样是带宽）
· 电源计划设成「高性能」，别让它省电降频

这三条这个工具里都有，去「系统体检」页看结论。
'@
        return $out
    }

    # ---------- 笔记本独显：先讲降压，不是超频 ----------
    if ($g.IsLaptop) {
        Add-P '当心' '笔记本先别想超频，该做的是「降压」' @'
笔记本上限制性能的几乎永远是**散热**，不是频率上限。

机器一热就自动降频保护，这时候你把频率往上调没有任何意义——
它本来就达不到原来那个频率。真正有效的是反过来做：
**同样的频率用更低的电压跑**，发热少了，反而能一直维持高频。
这个操作叫「降压」（Undervolt），在笔记本上比超频靠谱得多，
而且风险更小：不稳定的表现是驱动重启，调回去就好。

顺序应该是：
1. 先清灰换硅脂（老机器的收益比任何软件调教都大）
2. 再降压
3. 功耗墙和频率滑块最后考虑，而且笔记本上多半是锁死的

另外：NVIDIA 从 535 版驱动起，笔记本上的功耗墙和电压控制
大部分被锁了，命令行 nvidia-smi -pl 会直接报不支持。
Afterburner 里那几个滑块在笔记本上经常拖不动，不是软件坏了。
'@
    }

    # ---------- 逐个滑块讲清楚 ----------
    if ($g.Vendor -eq 'NVIDIA') {
        Add-P '动手' '核心频率偏移（Core Clock）—— 先动这个' @'
【它是什么】
不是把频率定死在某个数，而是在显卡原本的自动调频曲线上
**整体加一个偏移量**。原来某个负载下跑 1800，加 +100 之后跑 1900。

【从多少起步】
+50 MHz 起步，每次加 25~50，直到出问题为止，再退回上一档再退 25。
桌面卡最后大多落在 +75 ~ +150 这个区间，笔记本卡通常更低。

【为什么不直接给一个数】
每块芯片的体质不一样（业内叫「硅片彩票」），同型号的两块卡
能差出 100 MHz 以上。抄别人的数值就是在赌，而且赌输了要花
一晚上排查是哪一项的问题。

【出问题长什么样】
画面出现雪花点、闪烁的三角形、游戏突然退出、
屏幕黑一下然后弹出「显示驱动程序已停止响应并已恢复」。
看到任何一个就是过头了，往回退。
'@

        Add-P '动手' '显存频率偏移（Memory Clock）—— 这个有个坑' @'
【它是什么】
显存的频率。提升它等于拓宽显卡和显存之间的带宽，
高分辨率、开光追的时候收益比核心频率更明显。

【从多少起步】
+200 MHz 起步，每次加 100~200。

【【这里有个新手必踩的坑】】
现在的显存（GDDR6 / GDDR6X）自带纠错机制。频率推过头的时候，
它**不会崩溃，而是默默地反复重传出错的数据**——
画面一切正常，帧数却反而下降了。

所以显存不能只看「崩没崩」，必须看帧数：
每加一档就跑一次同样的测试，**帧数不再涨、甚至开始掉，
那就是已经过头了**，退回帧数最高的那一档。

这一条是超频里最容易白忙活的地方 ——
很多人「超了显存 +1500 也不崩」，其实早就在倒扣性能了。
'@

        if (-not $g.IsLaptop) {
            Add-P '动手' '功耗墙和温度墙（Power / Temp Limit）' @'
【功耗墙】
显卡允许消耗的最大电力，通常能往上拉 10%~20%（有的卡拉不动，是锁死的）。
拉满之后显卡在重负载下更不容易掉频。代价是耗电和发热一起上去，
电源功率不够的机器会直接黑屏重启 —— 电源是杂牌或者年头久了的先别动它。

【温度墙】
到多少度开始自动降频。默认一般是 83°C。
往上调能让它晚一点降频，但**长期在 85°C 以上跑对显卡寿命不好**，
一般不建议超过 87。

真正该做的是让它凉下来，而不是允许它更热：
机箱风道理顺、显卡进风口别顶着玻璃、该清灰就清灰。
'@

            Add-P '动手' '风扇曲线 —— 最值得调、也最安全的一项' @'
显卡出厂的风扇曲线都偏保守（为了安静），经常是温度都到 75 度了
风扇才转到 50%。手动把曲线调陡一点，温度能降 5~10 度，
温度下来了核心自动就能跑更高的频率 —— 等于白赚一档超频，
而且**零风险**。

一个够用的曲线：
  40°C → 30%     55°C → 45%
  65°C → 60%     75°C → 80%
  80°C → 100%

嫌吵就把中间几档往下挪 10%，自己听着办。
'@
        }

        Add-P '步骤' '完整流程：照着做就行' @'
1.【先装工具】
   MSI Afterburner（官网 msi.com 下载，免费）。
   安装时会一起装 RivaTuner，那是用来显示帧数和温度的，装上。

2.【记下现在的水平】
   什么都不改，先跑一次测试，把帧数、最高温度记下来。
   没有这个基准线，后面根本不知道有没有变好。

3.【先调风扇曲线】
   见上面那条。先让温度下来，很多时候光这一步帧数就涨了。

4.【再调核心，一次只动一项】
   +50 → 测 → 稳 → +25 → 测 …… 直到出问题，退回上一档再退 25。
   【一次只动一个滑块】 同时动两个，崩了你不知道是哪个的锅。

5.【然后调显存】
   核心定下来之后再动显存，方法一样，但要盯帧数（见上面那个坑）。

6.【长时间验稳】
   短测试过了不代表稳。找一个你真正常玩的游戏，连续玩一小时。
   很多不稳定要跑热了才暴露。

7.【存成配置档】
   Afterburner 右边有 1~5 个存档位，存好，勾上「开机自动应用」。
   不勾的话重启就没了。

【怎么测】
· 甜甜圈（FurMark）只适合测散热，不适合测超频稳不稳 —— 它的负载
  和真实游戏差太远，过了甜甜圈照样在游戏里崩
· 3DMark 的 Time Spy 压力测试比较接近真实负载
· 但**最权威的还是你自己玩的那个游戏**
'@

        Add-P '当心' '崩了怎么办 —— 先说清楚，免得慌' @'
超频翻车不会烧卡。现在的显卡有硬件保护，频率给高了只会
黑屏、花屏或者驱动重启，**重启一次就回到默认状态**。

· 花屏 / 驱动重启 → Afterburner 里点那个圆形「重置」按钮，归零
· 开机直接黑屏进不去 → 安全模式进系统，删掉 Afterburner 的
  开机自启（或者删掉它的配置文件），重启就正常了
· 怎么进安全模式 → 开机时连续强制关机三次，Windows 会自动
  进入恢复环境，选「疑难解答 → 高级选项 → 启动设置 → 重启 → 4」

真正需要担心的只有一条：**显存推过头长期跑**。
它不崩，但会持续出错重传，长期下来对显存颗粒不好。
所以显存那一项一定要按帧数判断，别按「崩没崩」判断。
'@

    } elseif ($g.Vendor -eq 'AMD') {
        Add-P '动手' 'A 卡不用装第三方软件，驱动里就有' @'
AMD 的驱动自带调节面板：
  右键桌面 → AMD Software → 性能 → 调节 → 切到「手动」

里面这几项对应的是：
· **GPU 最大频率**：核心能跑到的上限。从默认值 +3% 起步往上试。
· **GPU 电压**：A 卡上更值得做的是**往下调**（降压）。
  电压降 50~100 mV，温度下来了，实际能维持的频率反而更高。
· **显存频率 / 快速时序（Fast Timing）**：显存这边打开「快速时序」
  通常有稳定收益，比单纯拉频率划算。
· **功率限制**：能往上拉 10%~15%，代价是耗电发热。

A 卡有个 NVIDIA 没有的好东西：面板里有「自动欠压」和
「自动超频」两个一键选项。不想自己折腾的话，先点「自动欠压」，
这一项在绝大多数 A 卡上都是白赚的。
'@
        Add-P '步骤' '流程和注意事项' @'
1. 先记基准：什么都不改，跑一次你常玩的游戏，记下帧数和最高温度
2. 先点「自动欠压」，再测一次 —— 多数卡到这一步就够了
3. 想继续的话，手动模式下**一次只动一项**，每次加一点就测
4. 显存频率加过头时 A 卡也一样会「不崩但掉帧」，要盯帧数不是盯崩没崩
5. 每套设置记得点右上角存成配置档，不然重启就回默认

【出问题长什么样】
花屏、驱动重启（屏幕黑一下）、游戏闪退。
点面板里的「重置」就全部归零，不会有后遗症。
'@
    } else {
        Add-P '当心' 'Intel 独显（Arc）的调节在驱动里' @'
Intel 的 Arc 显卡用「Intel Arc Control」调，里面有
性能档位和功耗设置，但可调的范围比 N 卡 A 卡小得多。

Arc 目前最大的性能变数不是超频，而是**主板 BIOS 里的
Resizable BAR 有没有开**。这一项对 Arc 的影响非常大，
关着的话某些游戏能差出 30% 以上。开机进 BIOS，
找 Resizable BAR / Smart Access Memory，打开它。
'@
    }

    Add-P '信息' '实话：超频能涨多少' @'
显卡超频在现在的卡上，**实际游戏帧数一般涨 3%~8%**。
60 帧变 63~65 帧。这就是真实水平。

那些宣传「超频提升 30%」的，要么是在跑分软件里跑出来的，
要么是原本就处于降频状态（过热、功耗墙拉太低）被修好了。

所以如果你现在卡得厉害，超频不是解药。先去「系统体检」页
看一眼结论 —— 十有八九是散热、内存单通道、或者游戏跑在核显上。
'@

    return $out
}

function Get-VendorSoftware {
    <#
      认出这台机器是哪家的，告诉用户该装哪个厂商工具、它管什么。
      返回一串 @{ Kind; Title; Text }，和 Get-OcPlan 同构。
    #>
    $out = New-Object System.Collections.ArrayList
    function Add-V { param($Kind, $Title, $Text) [void]$out.Add([PSCustomObject]@{ Kind = $Kind; Title = $Title; Text = $Text }) }

    $maker = ''; $model = ''; $isLaptop = $false
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $maker = "$($cs.Manufacturer)"
        $model = "$($cs.Model)"
    } catch { }
    try { $isLaptop = [bool](Test-IsLaptop) } catch { }

    if (-not $maker) {
        Add-V '当心' '读不到机器品牌' '读不到主板/整机信息，没法判断该装哪个厂商工具。'
        return $out
    }

    Add-V '信息' '这台机器' ("$maker $model" + $(if ($isLaptop) { '（笔记本）' } else { '（台式机）' }))

    if (-not $isLaptop) {
        Add-V '信息' '台式机基本不需要厂商工具' @'
台式机的风扇转速、性能模式这些都在主板 BIOS 里调，
厂商那些 Windows 端的「管家」软件（华硕 Armoury Crate、
微星 Center、技嘉 Control Center 之类）主要是管灯效的，
常驻内存、开机自启一堆服务，性价比很低。

真正需要的只有两个：
· 显卡驱动（去 NVIDIA / AMD 官网下，别用厂商打包的老版本）
· 主板芯片组驱动（主板官网，装一次就行）

灯效不重要的话，那些管家软件可以直接不装。
'@
        return $out
    }

    # ---------- 笔记本：按品牌给建议 ----------
    if ($maker -match 'ASUS|ASUSTeK') {
        Add-V '动手' '华硕笔记本：强烈建议换成 G-Helper' @'
华硕自带的 Armoury Crate（奥创）功能是齐的，问题是太重了：
开机自启七八个服务、常驻几百 MB 内存、还经常自己弹更新。
很多人装它只是为了切一下性能模式和风扇曲线。

【替代方案】G-Helper
  开源免费（github.com/seerge/g-helper），十几 MB，
  常驻内存几十 MB，托盘里一个图标。
  性能模式、风扇曲线、显卡模式切换（核显/独显/混合）、
  键盘灯、充电限制 —— 奥创上常用的它基本都有。

【要注意的一点】
G-Helper 依赖华硕的底层驱动（Asus System Control Interface），
这个驱动本身还是要装的 —— 装奥创的时候已经带进来了。
所以正确顺序是：先用奥创把驱动装好，再卸掉奥创的主程序，
留下驱动，然后装 G-Helper。

【最值得用的一个功能】
充电限制设成 80%。笔记本长期插电的话，这一项比什么优化
都更能延长电池寿命。
'@
        Add-V '信息' '为什么这个工具不把这些功能做进来' @'
说实话：做不了，也不该做。

G-Helper 那些功能靠的是华硕自家的驱动接口，换个牌子的
笔记本就完全没有。而且它是 GPL-3.0 协议 —— 把它的代码搬过来，
整个工具就得跟着改成 GPL，那和本工具的 MIT 协议是冲突的。

所以这里只做一件事：认出你的机器，告诉你该用哪个现成的好东西。
'@
    } elseif ($maker -match 'Lenovo|LENOVO') {
        Add-V '动手' '联想笔记本：Lenovo Vantage 留着，但关掉它的广告' @'
联想的 Vantage 本身有用（性能模式、电池养护、驱动更新），
但默认会推一堆「联想应用中心」的推广。

进 Vantage → 设置 → 把「接收消息推送」「个性化推荐」都关掉。

【最值得用的两个功能】
· 电池养护模式（充到 60% 就停，长期插电的话一定要开）
· 性能模式切换（Fn+Q 也能切：节能 / 智能 / 野兽）

拯救者系列的「野兽模式」在插电时才生效，电池上按了没反应
是正常的，不是坏了。
'@
    } elseif ($maker -match 'MSI|Micro-Star') {
        Add-V '动手' '微星笔记本：MSI Center 只留需要的模块' @'
MSI Center 是模块化的 —— 装完之后进去，把用不到的功能块
（Mystic Light 灯效、App Player、各种推广模块）卸掉，
只留「User Scenario」（性能模式）和「Battery Master」（电池养护）。

这样能从常驻几百 MB 降到几十 MB。

【电池养护】Battery Master 里的「Best for Battery」
是充到 60% 就停，长期插电的话开着。
'@
    } elseif ($maker -match 'Hewlett|HP') {
        Add-V '动手' '惠普笔记本：HP Command Center' @'
惠普的性能模式和风扇控制在 HP Command Center 里
（暗影精灵/光影精灵系列叫 OMEN Gaming Hub）。

OMEN Gaming Hub 里有个「Performance Control」，
能切性能模式、调风扇。其余的游戏推广、Oasis 之类
都可以不管。

惠普的工具比较轻，一般不用折腾。
'@
    } elseif ($maker -match 'Dell|Alienware') {
        Add-V '动手' '戴尔笔记本：Alienware Command Center / Dell Power Manager' @'
· 游戏本（游匣 G 系列 / 外星人）：Alienware Command Center，
  里面有性能模式和风扇曲线（Fn+F7 也能直接切性能模式）
· 商务本（灵越 / Latitude）：Dell Power Manager，
  主要是电池养护，里面的「主要用交流电」模式会把充电上限压到 80%
'@
    } else {
        Add-V '信息' "$maker 这个牌子没有专门的建议" @'
没收录这个品牌的厂商工具信息。

通用原则：
· 厂商的「管家」软件只装到能切性能模式和调风扇就够了，
  灯效、游戏推广、应用商店那些模块能卸就卸
· 显卡驱动去 NVIDIA / AMD 官网下，别用厂商打包的老版本
· 笔记本一定要找找有没有「充电上限 80%」这个设置，
  长期插电的话这一项最值钱
'@
    }

    Add-V '当心' '厂商工具和这个工具的分工' @'
这个工具动的是 Windows 这一层：注册表、服务、电源计划、启动项。
厂商工具动的是硬件这一层：风扇转速、功耗墙、显卡直连、充电上限。

两层不冲突，但**有一件事必须让厂商工具来做** ——
笔记本的性能模式。它背后是主板固件（EC）里的功耗和风扇策略，
Windows 这边的「电源计划」改不到。

所以笔记本上正确的顺序是：
先用厂商工具把性能模式切到高性能，再回来做这里的优化。
只做这边不做那边，效果会打对折。
'@

    return $out
}
