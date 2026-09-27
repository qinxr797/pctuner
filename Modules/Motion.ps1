#Requires -Version 5.1
<#
=====================================================================
  交互引擎
---------------------------------------------------------------------
  这个模块存在的理由，是老板的一句话：
  「交互的逻辑太机械和简单了，能不能和市面上的软件一样更鲜活」。

  他说得对。在这之前，界面上所有东西都是**瞬间切换**的：
  健康度 96 是一下子蹦出来的，进度条是一下子到位的，
  卡片按下去毫无反应，数字每秒跳一次像秒表。
  功能全对，但没有一点「过程感」——用起来像个脚本，不像个软件。

  ★ 一条分界线，别搞混 ★
    网页设计的那套动画规矩（「每个区块都淡入上移会显得廉价」）
    是给**营销页**写的。工具软件不一样：这里的动效不是装饰，
    是**操作反馈** —— 它回答「我刚才按的那下生效了吗」
    「这个数字是变了还是我看错了」。该有的必须有。

    判断标准：这个动效在回答用户的一个问题吗？
      · 按钮按下去缩一下   → 回答「点上了吗」        ✔ 留
      · 数字滚上去          → 回答「这是新值」        ✔ 留
      · 每个区块进场都上移  → 不回答任何问题          ✘ 砍

  ★ 缓动曲线来自 Emil Kowalski（Sonner / Vaul 作者）那套 ★
    WPF 自带的 CubicEase 太软，一律用 KeySpline
    —— 它和 CSS 的 cubic-bezier 是同一个东西，控制点可以直接照抄。

  ★ 性能 ★
    这工具的用户有一大票老机器。所以：
      · 只动 Opacity / Transform（走 GPU 合成，不触发重新布局）
      · 不做每帧回调的 JS 式补间，全部交给 WPF 的 Storyboard
      · 系统「显示动画」关掉时自动降级（见 Test-SystemReducedMotion）
      · 用户在「个性化」页关掉效果时，所有函数直接返回，不建 Storyboard
=====================================================================
#>

# ---------------------------------------------------------------------
#  缓动曲线
# ---------------------------------------------------------------------
#  等价的 CSS 写法写在注释里，方便和网页那边对照。
$Script:Ease = @{
    # cubic-bezier(.23,1,.32,1) —— 冲出去然后很快稳住。默认用这个
    Out    = @(0.23, 1.0, 0.32, 1.0)
    # cubic-bezier(.77,0,.175,1) —— 两头慢中间快，用于位置移动
    InOut  = @(0.77, 0.0, 0.175, 1.0)
    # cubic-bezier(.34,1.56,.64,1) —— 末尾冲过头一点再回来，用于「弹起来」
    Spring = @(0.34, 1.56, 0.64, 1.0)
    # cubic-bezier(.4,0,1,1) —— 起步慢、越来越快。**只用于「消失」**
    #
    # ★ 别拿 In 做按下反馈 ★
    #   直觉上「按下要立刻到位 -> 用 In」是**反的**：
    #   ease-in 是起步最慢的那条，实测 70ms 的动画跑到 60ms 时
    #   才走了不到两成（ScaleX 1 -> 0.987，目标是 0.93）。
    #   用户已经按下去了，界面却还在慢慢启动 —— 看起来就是「没反应」。
    #   要「立刻到位」用 Out：它前 30% 的时间走完 70% 的距离。
    In     = @(0.4, 0.0, 1.0, 1.0)
}

# 时长（毫秒）。统一在这里改，别在调用处写死数字。
$Script:Dur = @{
    # ★ 产品 UI 的动效一律压在 150~250ms ★
    #   用户在任务流里，不想等编排。900ms 的数字滚动是营销页的节奏，
    #   放在一个每秒刷新的读数上只会一直在抖。
    Press   = 90     # 按下
    Hover   = 130    # 悬停
    Tab     = 170    # 切页
    Panel   = 200    # 面板进场
    Count   = 240    # 数字补间
    Bar     = 220    # 进度条补间
    Flash   = 380    # 数值变化闪一下
    Stagger = 35     # 依次错开的步长
}

function Test-MotionOn {
    <# 动效总开关：用户关了、或者系统关了「显示动画」，就全部不做 #>
    if (-not $Script:AnimEnabled) { return $false }
    return $true
}

function New-Spline {
    <# 把四个控制点变成 WPF 的 KeySpline（= CSS cubic-bezier） #>
    param([double[]]$P)
    New-Object System.Windows.Media.Animation.KeySpline (
        (New-Object System.Windows.Point $P[0], $P[1]),
        (New-Object System.Windows.Point $P[2], $P[3]))
}

function New-DoubleTween {
    <#
      造一条 double 动画。所有补间的地基。
      Curve 传 $Script:Ease 里的某一条。
    #>
    param(
        [double]$From, [double]$To, [double]$Ms,
        [double[]]$Curve = $null, [double]$DelayMs = 0
    )
    if (-not $Curve) { $Curve = $Script:Ease.Out }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms + $DelayMs))
    if ($DelayMs -gt 0) {
        # 用一个「停在原地」的关键帧来做延迟，比 BeginTime 更好控
        $hold = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
            $From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(0)))
        $a.KeyFrames.Add($hold) | Out-Null
        $hold2 = New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
            $From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($DelayMs)))
        $a.KeyFrames.Add($hold2) | Out-Null
    }
    $kf = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
        $To,
        [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($Ms + $DelayMs)),
        (New-Spline $Curve))
    $a.KeyFrames.Add($kf) | Out-Null
    return $a
}

function Start-Prop {
    <# 把一条 double 动画挂到某个元素的某个属性上跑起来 #>
    param($Element, $Property, [double]$From, [double]$To, [double]$Ms,
        [double[]]$Curve = $null, [double]$DelayMs = 0)
    if ($null -eq $Element) { return }
    try {
        $Element.BeginAnimation($Property, (New-DoubleTween -From $From -To $To -Ms $Ms -Curve $Curve -DelayMs $DelayMs))
    } catch { }
}

# =====================================================================
#  数字滚动
# =====================================================================
function Start-CountUp {
    <#
      让一个数字从当前值**滚**到目标值，而不是啪地换掉。

      ★ 为什么值得专门做 ★
        「96」直接出现，用户不确定它是不是刚算出来的；
        从 0 滚到 96，这个过程本身就在说「我刚给你测完」。
        这是整个界面最容易做出「活」的一处。

      ★ 实现上不用 Storyboard ★
        WPF 没法直接补间 TextBlock.Text（那是字符串）。
        所以补一个挂在元素上的附加 double，每帧回调里改文字。
        这是全模块唯一一处每帧回调，所以特意限制了时长和帧数。

      Decimals 给小数位数；Suffix 拼在后面（比如 '' 或 ' GB'）。
    #>
    param(
        $Target,                       # TextBlock
        [double]$To,
        [int]$Decimals = 0,
        [string]$Suffix = '',
        [double]$Ms = 0
    )
    if ($null -eq $Target) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Count }

    # 从当前显示的数字起步。读不出来（比如现在是「--」）就从 0 起步
    $from = 0.0
    $cur = "$($Target.Text)" -replace '[^\d.\-]', ''
    if ($cur -and [double]::TryParse($cur, [ref]$null)) { $from = [double]$cur }

    $fmt = if ($Decimals -gt 0) { "F$Decimals" } else { 'F0' }

    # 动效关了就直接写最终值
    if (-not (Test-MotionOn)) {
        $Target.Text = $To.ToString($fmt) + $Suffix
        return
    }
    # 差得太小不值得动（比如占用率从 21 变 22），直接写，省得一直在抖
    if ([math]::Abs($To - $from) -lt ([math]::Pow(10, -$Decimals) * 2)) {
        $Target.Text = $To.ToString($fmt) + $Suffix
        return
    }

    # ★ 必须先掐掉这个元素上还没跑完的那个补间 ★
    #   读数每秒刷一次，上一轮的 380ms 补间可能还在跑。
    #   两个 DispatcherTimer 同时往一个 TextBlock 里写字，
    #   数字会来回跳（一帧 21、一帧 19），看起来像读数不稳 ——
    #   而这个工具最不能出现的就是「数字看起来不可信」。
    try { if ($Target.Tag -is [System.Windows.Threading.DispatcherTimer]) { $Target.Tag.Stop() } } catch { }

    $spline = New-Spline $Script:Ease.Out
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    # 约 60fps。老机器上 WPF 自己会丢帧，不会因为这里排得密就卡住
    $timer.Interval = [TimeSpan]::FromMilliseconds(16)
    $state = @{ T = $Target; From = $from; To = $To; Ms = $Ms; Fmt = $fmt; Suffix = $Suffix; Sw = $sw; Sp = $spline }
    $timer.Add_Tick({
            $st = $this.Tag
            $p = $st.Sw.Elapsed.TotalMilliseconds / $st.Ms
            if ($p -ge 1) {
                $st.T.Text = $st.To.ToString($st.Fmt) + $st.Suffix
                $this.Stop()
                return
            }
            # GetSplineProgress 就是 CSS 那条 cubic-bezier 在 p 处的 y 值
            $e = $st.Sp.GetSplineProgress($p)
            $v = $st.From + ($st.To - $st.From) * $e
            $st.T.Text = $v.ToString($st.Fmt) + $st.Suffix
        })
    $timer.Tag = $state
    $Target.Tag = $timer      # 记住它，下一轮好掐掉
    $timer.Start()
}

function Start-ValueFlash {
    <#
      读数变了，让它极短暂地提亮一下再回落。

      解决的问题：四个读数每秒都在刷，用户盯着看的时候
      分不清「这个数刚变了」还是「我眼花」。闪一下就说清了。
      幅度必须很小 —— 一秒闪一次的东西稍微夸张一点就会烦人。
    #>
    param($Element)
    if (-not (Test-MotionOn) -or $null -eq $Element) { return }
    try {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Script:Dur.Flash))
        # ★ 最后一帧必须回到 1.0 ★
        #   动画结束后属性会**停在最后一帧的值**上。
        #   写成「1.0 → 0.82」的话，读数每闪一次就停在 0.82，
        #   下一次又从 1.0 掉到 0.82 —— 看起来是「越刷越暗」，
        #   而且永远回不到正常亮度。必须闪下去再回来。
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    0.72, [Windows.Media.Animation.KeyTime]::FromPercent(0.14), (New-Spline $Script:Ease.Out)))) | Out-Null
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    1.0, [Windows.Media.Animation.KeyTime]::FromPercent(1.0), (New-Spline $Script:Ease.Out)))) | Out-Null
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch { }
}

function Start-BarTo {
    <#
      进度条/填充条平滑滑到目标宽度。
      直接设 Width 是瞬间跳变，看不出「涨了还是跌了」。
    #>
    param($Bar, [double]$ToWidth, [double]$Ms = 0)
    if ($null -eq $Bar) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Bar }
    if (-not (Test-MotionOn)) { $Bar.Width = $ToWidth; return }
    $from = if ([double]::IsNaN($Bar.Width)) { 0 } else { [double]$Bar.Width }
    Start-Prop $Bar ([System.Windows.FrameworkElement]::WidthProperty) $from $ToWidth $Ms $Script:Ease.Out
}

# =====================================================================
#  可交互元素：悬停 / 按下 / 焦点
# =====================================================================
function Add-Interactive {
    <#
      一行给任意 Border 挂上完整的交互反馈。
      以后所有可点的卡片都走这个，别再各写各的。

        悬停  底色过渡 + 边框提亮 + 上移 1px
        按下  整体缩到 0.985（有「被按进去」的实感）
        松开  用 Spring 曲线弹回来

      ★ 为什么缩放而不是变暗 ★
        变暗在深色皮肤上几乎看不出来。缩放是尺寸变化，
        任何配色下都能感知到，而且走 RenderTransform 不触发重新布局。

      ★ 缩放中心必须设在正中 ★
        默认中心在左上角，缩放时整张卡会往左上角跑，像在抖。
    #>
    param(
        $Border,
        [string]$BgNormal = $null,
        [string]$BgHover = $null,
        [string]$BorderNormal = $null,
        [string]$BorderHover = $null,
        [switch]$NoLift,
        # 悬停时在指针位置浮一小团光，跟着鼠标走。
        # 只给「值得端详一下」的东西用（皮肤色样、预设卡），
        # 满页的列表行都加就成了满屏乱晃。
        [switch]$Spotlight
    )
    if ($null -eq $Border) { return }
    if (-not $BgNormal) { $BgNormal = $Script:CARD_BG }
    if (-not $BgHover) { $BgHover = $Script:CARD_HOVER }
    if (-not $BorderNormal) { $BorderNormal = $Script:CARD_BORDER }
    if (-not $BorderHover) { $BorderHover = '#D2D0C9' }   # BorderMed

    try {
        $Border.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
        $tg = New-Object System.Windows.Media.TransformGroup
        $tg.Children.Add((New-Object System.Windows.Media.ScaleTransform 1, 1)) | Out-Null
        $tg.Children.Add((New-Object System.Windows.Media.TranslateTransform 0, 0)) | Out-Null
        $Border.RenderTransform = $tg
    } catch { return }

    # ★ 绝对不能用 $Border.Tag 存配置 ★
    #   整个项目里 Tag 是「卡片背后的那条数据」：
    #     预设卡   Select-Preset $this.Tag
    #     优化项卡 Show-TweakDetail $this.Tag
    #     清理项卡 Show-CleanDetail $this.Tag
    #   在这里覆盖掉，点卡片就把一个 hashtable 当数据传下去 ——
    #   表现是「点了没反应」，不报错，极难查。（真踩过。）
    #   改用元素自带的 Resources 字典：跟着元素生命周期走，不泄漏。
    $Border.Resources['__motion'] = @{
        BgN = $BgNormal; BgH = $BgHover; BdN = $BorderNormal; BdH = $BorderHover
        Lift = (-not $NoLift); Spot = [bool]$Spotlight
    }

    $Border.Add_MouseEnter({
            $m = $this.Resources['__motion']
            if ($Script:SelectedCard -eq $this -or $Script:SelectedPresetCard -eq $this) { return }
            if ($m.Spot) { Start-Spotlight $this } else { Start-ColorFade $this $m.BgH }
            try { $this.BorderBrush = Get-Brush $m.BdH } catch { }
            if ($m.Lift -and (Test-MotionOn)) {
                Start-Prop $this.RenderTransform.Children[1] ([System.Windows.Media.TranslateTransform]::YProperty) `
                    0 -1 $Script:Dur.Hover $Script:Ease.Out
            }
        })
    $Border.Add_MouseLeave({
            $m = $this.Resources['__motion']
            if ($Script:SelectedCard -eq $this -or $Script:SelectedPresetCard -eq $this) { return }
            if ($m.Spot) { Stop-Spotlight $this }
            Start-ColorFade $this $m.BgN
            try { $this.BorderBrush = Get-Brush $m.BdN } catch { }
            if (Test-MotionOn) {
                Start-Prop $this.RenderTransform.Children[1] ([System.Windows.Media.TranslateTransform]::YProperty) `
                    -1 0 $Script:Dur.Hover $Script:Ease.Out
                Start-Prop $this.RenderTransform.Children[0] ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 0.985 1 $Script:Dur.Press $Script:Ease.Out
                Start-Prop $this.RenderTransform.Children[0] ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.985 1 $Script:Dur.Press $Script:Ease.Out
            }
        })
    if ($Spotlight) {
        $Border.Add_MouseMove({
                $rb = $this.Resources['__spot']
                if ($null -eq $rb) { return }
                try {
                    $p = [System.Windows.Input.Mouse]::GetPosition($this)
                    $w = [math]::Max(1, $this.ActualWidth)
                    $h = [math]::Max(1, $this.ActualHeight)
                    $pt = New-Object System.Windows.Point ($p.X / $w), ($p.Y / $h)
                    # ★ 直接赋值，不做动画 ★
                    #   指针本身就在动，再给圆心加个缓动，光斑会「拖在手后面」，
                    #   手感变黏。跟手就是最好的手感。
                    $rb.Center = $pt
                    $rb.GradientOrigin = $pt
                } catch { }
            })
    }

    # ================================================================
    #  按下反馈
    # ----------------------------------------------------------------
    #  ★ 行不缩放 ★
    #    上一版这里是缩到 0.985，实测在一行 322px 上只有 4.8px 变化，
    #    而且 ease-out 前段太快（50% 进度就走完 98%）——
    #    小到肉眼和像素测量都看不出来，等于没做。
    #    老板的原话就是「点击动画还没做出来」。
    #
    #    而且缩放本来就是**卡片**的语汇：一整行横着缩，
    #    会让旁边那一列看起来在抖。
    #
    #  正确的做法是回答「我点上了吗」这个问题，用两样能立刻看见的东西：
    #    · 背景瞬时压到比悬停更深一档
    #    · 整行下沉 1px（像被按进去）
    #
    #  ★ 按下用 Out，松开用 Spring ★
    #    按下要「立刻到位」，而 Out 才是起步最快的那条
    #    （前 30% 的时间走完 70% 的距离）。
    #    直觉上想用 In 是反的 —— 见曲线表里那条注释。
    # ================================================================
    $Border.Add_PreviewMouseLeftButtonDown({
            $m = $this.Resources['__motion']
            try { $this.Background = Get-Brush $m.BdN } catch { }   # 压到比悬停更深
            if (-not (Test-MotionOn)) { return }
            Start-Prop $this.RenderTransform.Children[1] ([System.Windows.Media.TranslateTransform]::YProperty) `
                0 1 60 $Script:Ease.Out
        })
    $Border.Add_PreviewMouseLeftButtonUp({
            $m = $this.Resources['__motion']
            try { $this.Background = Get-Brush $m.BgH } catch { }   # 松开回到悬停色
            if (-not (Test-MotionOn)) { return }
            Start-Prop $this.RenderTransform.Children[1] ([System.Windows.Media.TranslateTransform]::YProperty) `
                1 0 180 $Script:Ease.Spring
        })
}

function Start-Spotlight {
    <#
      把这一行的底色换成一支径向渐变：指针处亮一档，边缘落回悬停色。

      ★ 为什么是换刷子，不是加一层覆盖层 ★
        加层要多一个元素、要设 IsHitTestVisible、还得跟着换肤一起重建。
        换刷子零结构改动 —— 而且 Background 本来就归交互引擎管。

      ★ 两个渐变停止点的颜色用动画淡进去 ★
        直接换上去会「啪」地亮一下。让它和原来的底色过渡一样柔，
        130ms，和 Start-ColorFade 同一个时长。
    #>
    param($Border)
    $m = $Border.Resources['__motion']
    if ($null -eq $m) { return }
    try {
        $cN = (Get-Brush $m.BgN).Color
        $cH = (Get-Brush $m.BgH).Color
        # 光心：在悬停色基础上再提亮一档。提亮量按当前亮度自适应 ——
        # 深色皮肤上 +14 就看得见，浅色皮肤上要 +10 才不过曝。
        $lum = (0.299 * $cH.R + 0.587 * $cH.G + 0.114 * $cH.B)
        $lift = if ($lum -lt 128) { 20 } else { 11 }
        $cS = [System.Windows.Media.Color]::FromArgb(255,
            [byte][math]::Min(255, $cH.R + $lift),
            [byte][math]::Min(255, $cH.G + $lift),
            [byte][math]::Min(255, $cH.B + $lift))

        $rb = New-Object System.Windows.Media.RadialGradientBrush
        $rb.RadiusX = 0.62
        $rb.RadiusY = 1.05          # 行比光斑扁，横向半径小一点才圆
        $rb.Center = New-Object System.Windows.Point 0.5, 0.5
        $rb.GradientOrigin = $rb.Center
        $g0 = New-Object System.Windows.Media.GradientStop $cN, 0.0
        $g1 = New-Object System.Windows.Media.GradientStop $cN, 1.0
        $rb.GradientStops.Add($g0)
        $rb.GradientStops.Add($g1)
        $Border.Background = $rb
        $Border.Resources['__spot'] = $rb

        if (-not (Test-MotionOn)) {
            $g0.Color = $cS; $g1.Color = $cH
            return
        }
        $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Script:Dur.Hover))
        foreach ($pair in @(@($g0, $cS), @($g1, $cH))) {
            $a = New-Object System.Windows.Media.Animation.ColorAnimation
            $a.From = $cN; $a.To = $pair[1]; $a.Duration = $dur
            $pair[0].BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $a)
        }
    } catch { }
}

function Stop-Spotlight {
    <# 指针离开：把刷子交还给普通底色过渡（Start-ColorFade 需要 SolidColorBrush） #>
    param($Border)
    try {
        $Border.Resources.Remove('__spot')
        $m = $Border.Resources['__motion']
        if ($m) { $Border.Background = (Get-Brush $m.BgH).Clone() }
    } catch { }
}

function Add-PressFeedback {
    <#
      给普通 Button 加按下反馈。
      HandyControl 的按钮自带颜色变化，但没有位移/缩放，
      在深色皮肤下那点颜色变化几乎看不出来。
    #>
    param($Button)
    if ($null -eq $Button) { return }
    try {
        $Button.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
        $Button.RenderTransform = New-Object System.Windows.Media.ScaleTransform 1, 1
    } catch { return }
    # ★ 幅度要够被看见 ★
    #   0.96 在一个 110px 宽的按钮上只有 4.4px，配上 ease-out
    #   （50% 进度走完 98%）几乎是瞬间闪一下，感知不到。
    #   0.93 是 7.7px，按下去有实感，又不会夸张到像在弹跳。
    #   按下用 Out（起步快，30% 时间走完 70% 距离）＝ 立刻到位，
    #   松开用 Spring 回弹。
    $Button.Add_PreviewMouseLeftButtonDown({
            if (-not (Test-MotionOn)) { return }
            Start-Prop $this.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 0.93 70 $Script:Ease.Out
            Start-Prop $this.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1 0.93 70 $Script:Ease.Out
        })
    $Button.Add_PreviewMouseLeftButtonUp({
            if (-not (Test-MotionOn)) { return }
            Start-Prop $this.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 0.93 1 210 $Script:Ease.Spring
            Start-Prop $this.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.93 1 210 $Script:Ease.Spring
        })
    # 鼠标按着移出去：也要回弹，不然按钮会一直卡在缩小状态
    $Button.Add_MouseLeave({
            if (-not (Test-MotionOn)) { return }
            Start-Prop $this.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $this.RenderTransform.ScaleX 1 160 $Script:Ease.Out
            Start-Prop $this.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleYProperty) $this.RenderTransform.ScaleY 1 160 $Script:Ease.Out
        })
}

function Add-PressFeedbackAll {
    <#
      给**所有** Button 挂上按下反馈，包括现在还不存在的那些。

      ★ 不能靠遍历可视树 ★
        WPF 的 TabControl 只为**当前选中的那一页**建可视树，
        其余九页在启动时根本不存在。启动时遍历一遍的话，
        只有概览页的按钮挂上了，切过去的九页全是死的 ——
        而且因为概览页有效果，很容易误以为整个功能都好了。
        （实测就是这么漏的：按「全部不选」毫无反应。）

      正确做法是**类级注册**：给 Button 这个类型注册一次处理器，
      之后创建的每一个实例都自动带上，不用管它什么时候生成。

      幂等：只注册一次，重复调用直接返回。
    #>
    param($Root)
    if ($Script:PressHandlerInstalled) { return }
    try {
        $down = [System.Windows.Input.MouseButtonEventHandler] {
            param($s, $e)
            if (-not (Test-MotionOn)) { return }
            $sc = Get-PressTransform $s
            if ($sc) {
                Start-Prop $sc ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 0.93 70 $Script:Ease.Out
                Start-Prop $sc ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1 0.93 70 $Script:Ease.Out
            }
        }
        $up = [System.Windows.Input.MouseButtonEventHandler] {
            param($s, $e)
            if (-not (Test-MotionOn)) { return }
            $sc = Get-PressTransform $s
            if ($sc) {
                Start-Prop $sc ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 0.93 1 210 $Script:Ease.Spring
                Start-Prop $sc ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 0.93 1 210 $Script:Ease.Spring
            }
        }
        # 鼠标按着移出去也要回弹，否则按钮会卡在缩小状态
        $leave = [System.Windows.Input.MouseEventHandler] {
            param($s, $e)
            if (-not (Test-MotionOn)) { return }
            $sc = Get-PressTransform $s
            if ($sc -and $sc.ScaleX -lt 0.999) {
                Start-Prop $sc ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $sc.ScaleX 1 160 $Script:Ease.Out
                Start-Prop $sc ([System.Windows.Media.ScaleTransform]::ScaleYProperty) $sc.ScaleY 1 160 $Script:Ease.Out
            }
        }
        foreach ($t in @([System.Windows.Controls.Button], [System.Windows.Controls.Primitives.ToggleButton])) {
            [System.Windows.EventManager]::RegisterClassHandler($t,
                [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent, $down, $true)
            [System.Windows.EventManager]::RegisterClassHandler($t,
                [System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent, $up, $true)
            [System.Windows.EventManager]::RegisterClassHandler($t,
                [System.Windows.UIElement]::MouseLeaveEvent, $leave, $true)
        }
        $Script:PressHandlerInstalled = $true
    } catch { $Script:PressHandlerError = "$($_.Exception.Message)" }
}

function Get-PressTransform {
    <#
      拿到（必要时建立）某个控件用于按下缩放的 ScaleTransform。

      ★ 缩放中心必须在正中 ★
        默认中心在左上角，缩放时控件会往左上角跑，看起来像在抖。
    #>
    param($Ctrl)
    if ($null -eq $Ctrl) { return $null }
    try {
        if ($Ctrl.RenderTransform -is [System.Windows.Media.ScaleTransform]) {
            return $Ctrl.RenderTransform
        }
        $Ctrl.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
        $sc = New-Object System.Windows.Media.ScaleTransform 1, 1
        $Ctrl.RenderTransform = $sc
        return $sc
    } catch { return $null }
}

function Find-Descendants {
    <# 在可视树里找出某个类型的全部后代 #>
    param($Root, [Type]$Type)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Root) { return $out }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
    for ($i = 0; $i -lt $n; $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)
        if ($Type.IsInstanceOfType($c)) { [void]$out.Add($c) }
        foreach ($g in (Find-Descendants $c $Type)) { [void]$out.Add($g) }
    }
    return $out
}

# =====================================================================
#  进场
# =====================================================================
function Start-RevealIn {
    <#
      元素淡入 + 轻微上移。

      ★ 只在「用户刚做了一个动作、内容因此变了」的时候用 ★
        比如点了某一项、切了页、筛选完。
        纯粹的页面加载不要用 —— 那属于没人问的问题。
    #>
    param($Element, [double]$Ms = 0, [double]$SlideY = 8, [double]$DelayMs = 0)
    if ($null -eq $Element) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Panel }
    if (-not (Test-MotionOn)) { try { $Element.Opacity = 1 } catch { }; return }

    # 系统级「减弱动效」：保留淡入，去掉位移（会关这个的人多半有晕动症）
    if ($Script:SystemAnimOff) { $SlideY = 0 }

    try {
        if ($SlideY -ne 0) {
            $tt = New-Object System.Windows.Media.TranslateTransform 0, $SlideY
            $Element.RenderTransform = $tt
            Start-Prop $tt ([System.Windows.Media.TranslateTransform]::YProperty) $SlideY 0 $Ms $Script:Ease.Out $DelayMs
        }
        Start-Prop $Element ([System.Windows.UIElement]::OpacityProperty) 0 1 $Ms $Script:Ease.Out $DelayMs
    } catch { }
}

function Start-RevealList {
    <#
      一串元素依次进场。

      ★ 错开最多 6 个 ★
        再多的话最后几个要等半天才出来，用户会以为卡住了。
        第 7 个开始全部用第 6 个的延迟。
    #>
    param($Elements, [double]$Ms = 0, [double]$SlideY = 8)
    if ($Ms -le 0) { $Ms = $Script:Dur.Panel }
    $i = 0
    foreach ($e in @($Elements)) {
        $d = [math]::Min($i, 6) * $Script:Dur.Stagger
        Start-RevealIn -Element $e -Ms $Ms -SlideY $SlideY -DelayMs $d
        $i++
    }
}

# =====================================================================
#  忙碌指示
# =====================================================================
function Start-Pulse {
    <#
      让元素持续明暗呼吸，表示「正在算，还没出结果」。
      用在启动时那十几秒 —— 在这之前那段时间界面是死的，
      用户不知道是在加载还是已经卡死了。
    #>
    param($Element, [double]$Ms = 1100)
    if ($null -eq $Element) { return }
    if (-not (Test-MotionOn)) { return }
    try {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $a.AutoReverse = $true
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    0.35, [Windows.Media.Animation.KeyTime]::FromPercent(1.0), (New-Spline $Script:Ease.InOut)))) | Out-Null
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch { }
}

function Stop-Pulse {
    <# 停掉呼吸，回到不透明 #>
    param($Element)
    if ($null -eq $Element) { return }
    try {
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $Element.Opacity = 1
    } catch { }
}
