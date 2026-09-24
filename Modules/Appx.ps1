<#
=====================================================================
  Appx.ps1  ——  微软自带应用（UWP / Microsoft Store 应用）管理
---------------------------------------------------------------------
  做这个页面的原因：
  Windows 预装了一大堆 UWP 应用，绝大多数人一次都没打开过，
  但它们会：
    · 占 C 盘空间（加起来常常有 3~8 GB）
    · 在后台跑（天气、资讯、Xbox 那几个尤其烦）
    · 往开始菜单和通知里塞推荐内容

  但是 —— 这里面**混着几个删了会出事的**：
    · Microsoft.WindowsStore      删了应用商店基本装不回来
    · Microsoft.VCLibs / NET.Native / UI.Xaml   是别的应用的运行库
    · Microsoft.SecHealthUI       Windows 安全中心的界面
    · Microsoft.AccountsControl   登录/授权弹窗

  网上那些「一键卸载所有自带应用」的脚本，栽就栽在这里。

  所以这个模块的核心不是「能删」，是「拦住不该删的」：
    1. 每个包都有人话说明 + 三档结论（可以删 / 看情况 / 必须留）
    2. 「必须留」的项在界面上根本勾不上
    3. 就算绕过界面调用，Remove-AppxSafe 还有一道硬黑名单兜底
    4. 卸载只针对当前用户，不动系统镜像 —— 随时能从商店装回来
=====================================================================
#>

# =====================================================================
#  硬黑名单 —— 最后一道防线
# ---------------------------------------------------------------------
#  不管界面怎么点、不管知识库里怎么写，只要包名命中这个正则，
#  Remove-AppxSafe 一律拒绝执行。
#
#  ★ 这一条是故意和知识库分开写的 ★
#    知识库是给人看的说明，可能写漏；
#    这个正则是给机器看的红线，宁可拦错也不放过。
# =====================================================================
$Script:AppxProtected = @(
    # ---- 应用商店本体和它的依赖：删了以后所有 UWP 应用都装不回来 ----
    'Microsoft\.WindowsStore'
    'Microsoft\.StorePurchaseApp'
    'Microsoft\.Services\.Store\.Engagement'
    'Microsoft\.DesktopAppInstaller'      # winget 也靠它

    # ---- 运行库：别的应用（包括第三方）跑起来要用 ----
    'Microsoft\.VCLibs'
    'Microsoft\.NET\.Native'
    'Microsoft\.UI\.Xaml'
    'Microsoft\.WindowsAppRuntime'
    'Microsoft\.WinAppRuntime'                    # 含 DDLM.xxx 那一堆
    'MicrosoftCorporationII\.WinAppRuntime'
    'Microsoft\.Winget'                           # winget 的源，删了装软件会报错

    # ---- PowerShell 本体：这个工具自己就跑在它上面 ----
    # （曾经因为前缀匹配把它误判成「Power Automate」，见 Get-AppxCatalog 里的注释）
    'Microsoft\.PowerShell'

    # ---- 语言包：删了系统会变回英文，输入法也可能出问题 ----
    'Microsoft\.LanguageExperiencePack'

    # ---- 系统界面组件：删了会出现「开始菜单点不开」这类问题 ----
    'Microsoft\.Windows\.ShellExperienceHost'
    'Microsoft\.Windows\.StartMenuExperienceHost'
    'Microsoft\.Windows\.CloudExperienceHost'
    'Microsoft\.Windows\.ContentDeliveryManager'
    'Microsoft\.Windows\.Search'
    'Microsoft\.Windows\.PeopleExperienceHost'
    'Microsoft\.Windows\.CapturePicker'          # 截图/录屏的选择器
    'Microsoft\.Windows\.PinningConfirmationDialog'
    'Microsoft\.Windows\.XGpuEjectDialog'
    'Microsoft\.LockApp'                          # 锁屏界面
    'windows\.immersivecontrolpanel'              # 「设置」应用本体
    'Microsoft\.Win32WebViewHost'
    'Microsoft\.ECApp'

    # ---- 账号 / 安全 / 输入：删了会登不上、没法授权、打不了字 ----
    'Microsoft\.AccountsControl'
    'Microsoft\.AAD\.BrokerPlugin'
    'Microsoft\.CredDialogHost'
    'Microsoft\.BioEnrollment'                    # 指纹/人脸
    'Microsoft\.SecHealthUI'                      # Windows 安全中心界面
    'Microsoft\.AsyncTextService'                 # 输入法相关
    'Microsoft\.InputApp'
    'Microsoft\.Windows\.CallingShellApp'

    # ---- 浏览器内核 ----
    'Microsoft\.MicrosoftEdge'
    'Microsoft\.Edge'
) -join '|'

function Test-AppxProtected {
    <# 包名是否命中硬黑名单 —— 命中就永远不许卸 #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }   # 名字都没有，宁可不动
    return ($Name -match $Script:AppxProtected)
}

# =====================================================================
#  知识库：这个应用到底是干什么的，该不该留
# ---------------------------------------------------------------------
#  Verdict：'可以删' / '看情况' / '必须留'
#  Label  ：中文名（Get-AppxPackage 给的 DisplayName 经常是空的或英文）
#  Size   ：粗略占用，仅供参考，写「—」表示很小
# =====================================================================
function Get-AppxKnowledge {
    @{
        # ================= 明确可以删的：预装广告位 =================
        'Microsoft.BingWeather' = @{ Verdict = '可以删'; Label = '天气'; Size = '约 50 MB'; Text = @'
开始菜单磁贴里那个天气，以及任务栏上的「资讯和兴趣」。

【为什么建议删】
· 它会常驻后台联网拉数据和广告
· 任务栏那个天气条是不少人「鼠标划过就卡一下」的元凶
· 手机上看天气比这个方便得多

删了之后任务栏天气条一起消失。想看天气用浏览器或手机。
'@ }

        'Microsoft.BingNews' = @{ Verdict = '可以删'; Label = '资讯 / Microsoft News'; Size = '约 100 MB'; Text = @'
微软的新闻推送应用，本质上是个广告分发渠道。

【为什么建议删】
· 后台持续联网拉内容
· 锁屏和任务栏上那些「你可能感兴趣」的推送就是它推的
· 国内用户基本看不到有用的内容

放心删，没有任何系统功能依赖它。
'@ }

        'Microsoft.GetHelp' = @{ Verdict = '可以删'; Label = '获取帮助'; Size = '—'; Text = @'
微软的在线客服入口。点开就是连微软支持的聊天窗口。

【为什么建议删】
国内基本用不上，而且真遇到问题你也是去搜索引擎搜，不会用它。
删了不影响任何系统功能。
'@ }

        'Microsoft.Getstarted' = @{ Verdict = '可以删'; Label = '使用技巧 / 入门'; Size = '—'; Text = @'
「Windows 使用技巧」那个应用，会时不时弹通知教你用 Windows。

删了之后那些烦人的「试试这个新功能」通知也会少很多。
'@ }

        'Microsoft.MicrosoftOfficeHub' = @{ Verdict = '可以删'; Label = 'Office 推广入口'; Size = '—'; Text = @'
★ 注意：这个**不是 Office**，只是个推广壳子。★

它的作用是在开始菜单放一个「Office」图标，点开引导你订阅
Microsoft 365。你真正装的 Word / Excel 和它没关系，
删掉它不会影响你已经装好的 Office。

这是预装里最纯粹的广告之一，放心删。
'@ }

        'Microsoft.MicrosoftSolitaireCollection' = @{ Verdict = '可以删'; Label = '微软纸牌'; Size = '约 150 MB'; Text = @'
纸牌游戏合集。

【为什么建议删】
现在这个版本**带广告**，而且会后台更新、推送通知让你回来玩。
不玩的话删掉，能省一百多 MB 和一堆通知。
'@ }

        'Microsoft.MixedReality.Portal' = @{ Verdict = '可以删'; Label = '混合现实门户'; Size = '约 200 MB'; Text = @'
微软 VR 头显（Windows Mixed Reality）的配套软件。

微软已经**官方宣布停止支持** Windows Mixed Reality 了。
除非你手上真有一台 WMR 头显，否则这个百分之百是废的，删。
'@ }

        'Microsoft.WindowsFeedbackHub' = @{ Verdict = '可以删'; Label = '反馈中心'; Size = '—'; Text = @'
给微软提 Bug 和建议用的。

普通用户一次都不会打开。删了不影响任何功能。
'@ }

        'Microsoft.People' = @{ Verdict = '可以删'; Label = '联系人'; Size = '—'; Text = @'
UWP 版的通讯录应用。

只有在你用「邮件」和「日历」那两个自带应用时才有意义。
如果你收邮件用的是浏览器或 Foxmail / Outlook 桌面版，
这个就是纯占地方。
'@ }

        'Microsoft.YourPhone' = @{ Verdict = '可以删'; Label = '手机连接 / 你的手机'; Size = '约 100 MB'; Text = @'
把安卓手机连到电脑上，在电脑上看短信、照片、接电话。

【要不要删看你用不用】
· 真在用这个功能 → 留着，挺好用的
· 从来没连过手机 → 删，它是**开机自启常驻后台**的，
  不用还一直占内存

国内手机（小米/华为/OPPO 等）大多用自家的互传方案，
这个用得上的人不多。
'@ }

        'Microsoft.WindowsMaps' = @{ Verdict = '可以删'; Label = '地图'; Size = '约 80 MB'; Text = @'
微软自带地图。

国内的地图数据基本不能用（微软用的不是国内图商的数据），
查路线还是得用高德/百度。删。
'@ }

        'Microsoft.Todos' = @{ Verdict = '可以删'; Label = 'Microsoft To Do'; Size = '约 80 MB'; Text = @'
微软的待办清单应用。

在用就留着，没用过就删 —— 它会开机自启并常驻。
'@ }

        'MicrosoftTeams' = @{ Verdict = '可以删'; Label = 'Teams 个人版（聊天）'; Size = '约 150 MB'; Text = @'
Win11 任务栏上那个紫色的「聊天」图标。

★ 注意区分：★
· 这个是**个人版** Teams，微软硬塞的，国内几乎没人用
· 如果你公司用 Teams 办公，那装的是「Microsoft Teams (work or school)」，
  是另一个包，不是这个

个人版开机自启、常驻内存，不用的话删了能省不少。
'@ }

        'Microsoft.Windows.DevHome' = @{ Verdict = '可以删'; Label = '开发人员主页'; Size = '约 100 MB'; Text = @'
Win11 新塞的开发者工具面板。

不写代码的话完全用不到，删。
（写代码的也基本不用它，大家用 VS Code。）
'@ }

        'Clipchamp.Clipchamp' = @{ Verdict = '可以删'; Label = 'Clipchamp 视频剪辑'; Size = '约 300 MB'; Text = @'
微软收购来的在线视频剪辑工具，Win11 预装。

功能要联网、要登录、免费版导出还有限制。
剪视频国内一般用剪映，这个删了不可惜，能省三百多 MB。
'@ }

        # ★ 这个 key 必须写全名 ★
        #   早期写成 'Microsoft.Power'，结果把 Microsoft.PowerShell 也匹配了，
        #   界面上显示成「Power Automate —— 可以删」。别再缩短它。
        'Microsoft.PowerAutomateDesktop' = @{ Verdict = '可以删'; Label = 'Power Automate 桌面版'; Size = '约 400 MB'; Text = @'
微软的流程自动化工具，Win11 预装。

面向企业办公自动化，个人用户几乎不会用，但它个头不小。
删了能省三四百 MB。
'@ }

        'Microsoft.WindowsAlarms' = @{ Verdict = '可以删'; Label = '闹钟和时钟'; Size = '—'; Text = @'
闹钟、秒表、计时器、世界时钟。

用手机定闹钟的话这个就是纯占地方。
（不过它个头很小，删不删差别不大。）
'@ }

        'MicrosoftCorporationII.WindowsSubsystemForLinux' = @{ Verdict = '看情况'; Label = 'WSL（Linux 子系统）'; Size = '约 300 MB'; Text = @'
在 Windows 里跑 Linux 的组件。

· 你知道 WSL 是什么并且在用 → 留着
· 不知道这是啥 → 说明你不用它，可以删，能省三百多 MB

删了之后想用再从商店装回来。
'@ }

        # ---- 媒体扩展：名字看着像可删的小组件，其实删了会出事 ----
        'Microsoft.HEIFImageExtension' = @{ Verdict = '必须留'; Label = 'HEIF 图片格式支持'; Size = '—'; Text = @'
★ 看着不起眼，但删了会出问题。★

这是解码 HEIC / HEIF 格式图片的组件。
**iPhone 拍的照片默认就是 HEIC 格式** —— 删了之后
从手机导进来的照片在电脑上会打不开，显示一片空白或报错。

它只有几 MB，删了省不到空间，却会让人摸不着头脑地
「照片打不开」。留着。
'@ }

        'Microsoft.VP9VideoExtensions' = @{ Verdict = '必须留'; Label = 'VP9 视频解码'; Size = '—'; Text = @'
★ 删了会影响看视频。★

VP9 是 YouTube、部分网页视频和很多录屏文件用的编码格式。
删了之后这些视频可能**只有声音没有画面**，或者
从硬件解码掉回 CPU 软解 —— 看 4K 时 CPU 占用飙升、风扇狂转。

只有几 MB，留着。
'@ }

        'Microsoft.WebMediaExtensions' = @{ Verdict = '必须留'; Label = '网页媒体扩展'; Size = '—'; Text = @'
★ 删了会影响网页播放。★

支持 OGG / WebM 等开放格式的解码组件，很多网页播放器依赖它。

几 MB 的东西，删了没收益，却可能让某些网站的视频放不了。留着。
'@ }

        'Microsoft.AV1VideoExtension' = @{ Verdict = '必须留'; Label = 'AV1 视频解码'; Size = '—'; Text = @'
★ 删了会影响看高清视频。★

AV1 是 B 站、YouTube、Netflix 正在推的新一代编码。
删了之后这些平台的高清片源可能放不了，或者掉回 CPU 软解，
表现为**看 4K 时电脑突然很卡、风扇狂转**。

新显卡都有 AV1 硬件解码，留着这个才用得上。
'@ }

        'Microsoft.Windows.NarratorQuickStart' = @{ Verdict = '看情况'; Label = '讲述人快速入门'; Size = '—'; Text = @'
屏幕朗读功能（讲述人）的新手引导。

不需要无障碍功能的话可以删，但它很小，删不删差别不大。
'@ }

        'MicrosoftCorporationII.QuickAssist' = @{ Verdict = '可以删'; Label = '快速助手（远程协助）'; Size = '—'; Text = @'
微软的远程协助工具，让别人远程看你屏幕帮你修电脑。

【安全提示】
这个工具是**电信诈骗的常用道具** —— 骗子冒充客服让你打开它，
然后远程操作你的电脑转账。

如果你不需要远程协助，删掉它反而更安全。
真需要的时候从商店再装回来就行。
'@ }

        'Microsoft.SkypeApp' = @{ Verdict = '可以删'; Label = 'Skype'; Size = '约 150 MB'; Text = @'
微软已经**正式停止 Skype 服务**，功能并入 Teams。

这个预装版本现在基本是个死壳子，删。
'@ }

        'Microsoft.Wallet' = @{ Verdict = '可以删'; Label = '微软钱包'; Size = '—'; Text = @'
微软支付服务，国内完全不可用（不支持国内的支付方式）。删。
'@ }

        'Microsoft.549981C3F5F10' = @{ Verdict = '可以删'; Label = 'Cortana 小娜'; Size = '约 150 MB'; Text = @'
语音助手小娜。（包名就是这么一串数字，微软自己起的。）

微软已经**把 Cortana 从 Windows 里下架**了，
国区本来也不支持中文语音。纯占地方，删。
'@ }

        'Microsoft.BingSearch' = @{ Verdict = '可以删'; Label = '任务栏必应搜索'; Size = '—'; Text = @'
让你在任务栏搜索框里搜到网络结果（用必应）的组件。

【为什么很多人想删它】
你想搜本地文件，它非要给你弹一堆网页结果，还慢。
删了之后搜索框只搜本机内容，**反而快得多**。
'@ }

        # ================= 看情况：用得上就留 =================
        'Microsoft.ZuneMusic' = @{ Verdict = '看情况'; Label = '媒体播放器 / Groove 音乐'; Size = '约 100 MB'; Text = @'
Win11 的自带媒体播放器（Win10 上叫 Groove 音乐）。

【留还是删】
· 你是双击视频/音频就播放的习惯 → **留着**，删了之后
  双击媒体文件会没有默认播放器
· 你装了 PotPlayer / VLC / 网易云 → 可以删

删之前建议先装好替代品，不然会出现「双击视频没反应」。
'@ }

        'Microsoft.ZuneVideo' = @{ Verdict = '看情况'; Label = '电影和电视'; Size = '约 80 MB'; Text = @'
微软的视频播放 + 影片购买应用。

购买影片的功能国区用不了。如果你有 PotPlayer 之类的播放器，
这个可以删；没有的话它还能当个基础播放器用。
'@ }

        'Microsoft.WindowsCalculator' = @{ Verdict = '看情况'; Label = '计算器'; Size = '—'; Text = @'
系统自带计算器。

个头很小、不占后台，**一般建议留着** —— 哪天要算个数
发现计算器没了会很烦，而且它还能做单位换算和汇率。

真删了也能从商店装回来。
'@ }

        'Microsoft.WindowsNotepad' = @{ Verdict = '看情况'; Label = '记事本'; Size = '—'; Text = @'
Win11 把记事本做成了可卸载的应用。

**建议留着。** 它很小，而且是系统里最后一个能打开任何
文本文件的保底工具。删了之后打开 .txt / .log / .ini
会很麻烦（除非你装了 Notepad++ / VS Code）。
'@ }

        'Microsoft.Paint' = @{ Verdict = '看情况'; Label = '画图'; Size = '—'; Text = @'
画图工具。个头小，偶尔用来裁个图、标个箭头还挺方便。

用不上就删，但省不了多少空间。
'@ }

        'Microsoft.ScreenSketch' = @{ Verdict = '看情况'; Label = '截图工具 (Win+Shift+S)'; Size = '—'; Text = @'
★ 删之前想清楚：这个就是 Win+Shift+S 截图。★

删了之后 **Win+Shift+S 快捷键会失效**，PrintScreen 截图
也会受影响。

如果你用微信/QQ 截图（Alt+A / Ctrl+Alt+A）习惯了，
删掉没问题；否则强烈建议留着。
'@ }

        'Microsoft.Windows.Photos' = @{ Verdict = '看情况'; Label = '照片'; Size = '约 300 MB'; Text = @'
系统默认的图片查看器。

【删之前一定要想清楚】
删了之后**双击图片会没有程序打开**，得先装一个替代品
（比如 Honeyview、IrfanView，或者用浏览器看）。

这个应用确实臃肿（三百多 MB，启动慢），很多人换掉它，
但**先装替代品再删**，顺序别搞反。
'@ }

        'Microsoft.WindowsCamera' = @{ Verdict = '看情况'; Label = '相机'; Size = '—'; Text = @'
调用摄像头拍照录像的应用。

台式机没摄像头的话可以删。笔记本建议留着 ——
有时候要测试摄像头好不好使，或者某些网页调用它。
'@ }

        'Microsoft.WindowsSoundRecorder' = @{ Verdict = '看情况'; Label = '录音机'; Size = '—'; Text = @'
简单的录音工具。个头很小。

用不上就删，但也省不了多少。
'@ }

        'Microsoft.WindowsTerminal' = @{ Verdict = '看情况'; Label = 'Windows 终端'; Size = '约 100 MB'; Text = @'
新版命令行窗口（PowerShell / CMD 的外壳）。

不敲命令的话用不上。但它也不会自启、不占后台，
留着有备无患 —— 哪天需要跑个命令会用到。
'@ }

        'Microsoft.OutlookForWindows' = @{ Verdict = '看情况'; Label = '新版 Outlook（邮件）'; Size = '约 200 MB'; Text = @'
微软用来替代「邮件和日历」的新版 Outlook。

【注意】它本质上是个网页套壳，要联网登录才能用。
· 用微软邮箱收邮件 → 留着
· 用 QQ 邮箱 / 163 / Foxmail → 删
'@ }

        # ================= Xbox 那一堆：单独说 =================
        'Microsoft.XboxGamingOverlay' = @{ Verdict = '看情况'; Label = 'Xbox Game Bar（Win+G）'; Size = '约 100 MB'; Text = @'
★ 这个和游戏性能直接相关，要说清楚。★

按 Win+G 弹出来的那个游戏浮层，带录屏、性能监控、聊天。

【删它的理由】
· 它会往每个全屏游戏里**注入一层浮层**，有额外开销
· 「游戏中按错键弹出来」是老问题
· 录屏功能（Game DVR）是持续掉帧的常见原因

【留它的理由】
· Win+G 里的**帧数/占用监控**其实挺好用，调优时能看数据
· 有人用它的即时回放录精彩操作

【折中做法（推荐）】
不删这个包，改成在「性能优化」页开「关闭 Xbox 后台录制
（Game DVR）」—— 那样录制的开销没了，监控还能用。

如果你从来不用 Win+G，直接删也行。
'@ }

        'Microsoft.XboxApp' = @{ Verdict = '看情况'; Label = 'Xbox 主应用'; Size = '约 200 MB'; Text = @'
Xbox 游戏商店和社交。

【看你玩不玩 Game Pass】
· 玩 Game Pass / 微软商店的游戏 → **必须留**，游戏靠它启动
· 只玩 Steam / Epic / 国服网游 → 删，它开机自启还常驻
'@ }

        'Microsoft.GamingApp' = @{ Verdict = '看情况'; Label = 'Xbox（新版 Game Pass 客户端）'; Size = '约 250 MB'; Text = @'
Win11 上新版的 Xbox 应用，Game Pass 游戏从这里下载运行。

· 订阅了 Game Pass → **必须留**
· 没订阅 → 删
'@ }

        'Microsoft.XboxIdentityProvider' = @{ Verdict = '必须留'; Label = 'Xbox 账号登录组件'; Size = '—'; Text = @'
★ 这个看着像 Xbox 的东西，其实不能删。★

它负责 Xbox 账号的登录验证。**很多第三方 PC 游戏
（包括 Steam 上买的）也用它来登录微软账号**，
删了之后那些游戏会直接报错进不去 ——
《极限竞速》《光环》《帝国时代》这类微软发行的游戏尤其明显。

它个头极小、不占后台，留着没有任何代价。
'@ }

        'Microsoft.XboxSpeechToTextOverlay' = @{ Verdict = '可以删'; Label = 'Xbox 语音转文字浮层'; Size = '—'; Text = @'
Xbox 游戏里的语音转字幕功能。国区基本不支持中文。

不玩 Xbox 游戏的话删掉没影响。
'@ }

        'Microsoft.XboxGameOverlay' = @{ Verdict = '可以删'; Label = 'Xbox 游戏浮层（旧版组件）'; Size = '—'; Text = @'
Game Bar 的旧版辅助组件。

和上面的 XboxGamingOverlay 配套。不用 Win+G 的话可以一起删。
'@ }

        # ================= 必须留 =================
        'Microsoft.WindowsStore' = @{ Verdict = '必须留'; Label = 'Microsoft Store 应用商店'; Size = '约 200 MB'; Text = @'
★★ 千万别删这个。★★

删了应用商店之后，**上面所有应用你都装不回来了**。
微软没有提供正常的重装途径，只能靠一堆命令行操作硬修，
或者重装系统。

网上那些「一键清理自带应用」的脚本翻车，一大半就是栽在这。

这个工具在界面上**不允许**勾选它。
'@ }

        'Microsoft.SecHealthUI' = @{ Verdict = '必须留'; Label = 'Windows 安全中心界面'; Size = '—'; Text = @'
★ 不能删。★

这是「Windows 安全中心」那个界面。删了之后你就**打不开
病毒防护设置了** —— 杀毒还在跑，但你看不见也改不了，
想加白名单、想关实时保护都没有入口。
'@ }

        'Microsoft.DesktopAppInstaller' = @{ Verdict = '必须留'; Label = '应用安装程序 / winget'; Size = '—'; Text = @'
★ 不能删。★

它负责安装 .appx/.msix 格式的应用，同时也是 winget
（微软官方的命令行装软件工具）的本体。

个头很小，删了却会让一批安装行为失败。
'@ }
    }
}

# =====================================================================
#  扫描当前装了哪些自带应用
# =====================================================================
function Get-AppxCatalog {
    <#
      返回 @{ Name; Label; Verdict; Size; Text; Protected; Publisher }
      只列**微软自己的**包，第三方从商店装的不动
      （那些应该去「设置-应用」里正常卸载）。
    #>
    $kb   = Get-AppxKnowledge
    $list = New-Object System.Collections.ArrayList

    try {
        $pkgs = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
                # 只要微软签名的；框架包(Framework)本身不显示，它们是纯运行库
                $_.Publisher -match 'CN=Microsoft Corporation' -and -not $_.IsFramework
            })
    } catch {
        # ★ 这里最常见的失败不是「没有应用」，是「解释器不对」★
        #   PowerShell 7（pwsh）里 Appx 模块直接报
        #   「Operation is not supported on this platform」。
        #   一键启动.bat 走的是 powershell.exe(5.1) 所以没事，
        #   但万一有人用 pwsh 跑，得把真实原因说出来，
        #   不能让界面显示「你是精简版系统」误导人。
        $msg = "$($_.Exception.Message)"
        if ($msg -match 'not supported on this platform|0x80131539') {
            $Script:AppxFailReason = 'pwsh'
        } else {
            $Script:AppxFailReason = $msg
        }
        Write-Log "读取自带应用列表失败：$msg" '警告'
        return @()
    }

    foreach ($p in $pkgs) {
        $name = "$($p.Name)"

        # 知识库匹配：先精确，再「带边界的前缀」
        #
        # ★ 这里踩过一个坑，别改回去 ★
        #   最早写的是 `$name -like "$k*"`，纯前缀匹配。
        #   结果 'Microsoft.Power'（本想匹配 Power Automate）
        #   把 **Microsoft.PowerShell** 也匹配上了，
        #   界面上就会显示「Power Automate 桌面版 —— 可以删」，
        #   照着删就把 PowerShell 卸了。
        #
        #   所以前缀后面必须跟一个分隔符（. 或 _ 或 -），
        #   也就是只允许「同一个包的带后缀变体」，
        #   不允许匹配到另一个名字更长的包。
        $info = $null
        if ($kb.ContainsKey($name)) {
            $info = $kb[$name]
        } else {
            foreach ($k in $kb.Keys) {
                if ($name.Length -le $k.Length) { continue }
                if (-not $name.StartsWith("$k", [StringComparison]::OrdinalIgnoreCase)) { continue }
                $nextChar = $name[$k.Length]
                if ($nextChar -eq '.' -or $nextChar -eq '_' -or $nextChar -eq '-') {
                    $info = $kb[$k]; break
                }
            }
        }

        $protected = Test-AppxProtected $name

        if ($info) {
            $verdict = $info.Verdict
            $label   = $info.Label
            $size    = $info.Size
            $text    = $info.Text
        } else {
            # 知识库里没有的包 —— 不猜，老老实实说不认识
            $verdict = '看情况'
            $label   = if ($p.DisplayName) { "$($p.DisplayName)" } else { $name }
            $size    = '—'
            $text    = @"
这个包不在本工具的说明清单里，所以我不敢替你下结论。

包名：$name

【怎么自己判断】
1. 先看名字能不能认出来。认不出来的，多半是系统组件
2. 拿包名去搜索引擎搜一下
3. **拿不准就别删** —— 大多数系统组件个头很小，
   留着的代价远小于删错的代价

这一项默认不勾选。
"@
        }

        # 黑名单命中的，结论一律强制改成「必须留」——
        # 知识库要是写错了，以这里为准
        if ($protected) { $verdict = '必须留' }

        [void]$list.Add([PSCustomObject]@{
                Name      = $name
                Label     = $label
                Verdict   = $verdict
                Size      = $size
                Text      = $text
                Protected = $protected
                Version   = "$($p.Version)"
            })
    }

    # 可以删的排前面，必须留的沉底
    $order = @{ '可以删' = 0; '看情况' = 1; '必须留' = 2 }
    return ($list | Sort-Object @{ E = { $order["$($_.Verdict)"] } }, Label)
}

# =====================================================================
#  卸载（只卸当前用户，不动系统镜像）
# =====================================================================
function Remove-AppxSafe {
    <#
      卸载一个自带应用。

      ★ 故意只卸当前用户，不加 -AllUsers、不动 ProvisionedPackage ★
        这样做的后果是「新建的 Windows 用户还会有这些应用」，
        听起来不够干净，但换来的是：
          · 随时能从应用商店原样装回来
          · 不会影响系统更新（动了系统镜像有时会让更新失败）
        对一台自己用的机器来说，这个取舍是划算的。
    #>
    param([string]$Name)

    if (Test-AppxProtected $Name) {
        Write-Log "拒绝卸载 $Name —— 它在受保护名单里，删了会影响系统正常使用" '警告'
        return $false
    }

    try {
        $pkg = @(Get-AppxPackage -Name $Name -ErrorAction Stop)
        if ($pkg.Count -eq 0) {
            Write-Log "$Name 本来就没装" '信息'
            return $true
        }
        foreach ($p in $pkg) {
            Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
        }
        Write-Log "已卸载自带应用：$Name" '成功'
        return $true
    } catch {
        Write-Log "卸载 $Name 失败：$($_.Exception.Message)" '警告'
        return $false
    }
}
