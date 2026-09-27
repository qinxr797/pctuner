#Requires -Version 5.1
<#
=====================================================================
  交互引擎（v6.0 扁平版）
---------------------------------------------------------------------
  判断一个动效留不留，只问一句：它在回答用户的一个问题吗？
      · 数字滚上去          → 回答「这是新值」        ✔ 留
      · 读数变了闪一下      → 回答「刚刚变了」        ✔ 留
      · 行悬停底色过渡      → 回答「这一行能点」      ✔ 留（不再上浮）
      · 行按下底色压深      → 回答「点上了吗」        ✔ 留（不再下沉位移）
      · 按钮按下            → 交给 MDIX 的水波纹（压淡），不再额外缩放

  v6.0 删掉的（和扁平风格不搭，见 design.md 5.3）：
      悬停光斑跟随、卡片悬停上浮 1px、行按下下沉 1px + 弹簧回弹、
      按钮按下缩到 0.93、页签下划线滑动、标题逐字淡入、主按钮高光扫过

  切页动画不在这里：用 MDIX 的 TransitioningContent，写在窗口 XAML 里。

  ★ 缓动曲线来自 Emil Kowalski 那套 ★
    WPF 自带的 CubicEase 太软，一律用 KeySpline（= CSS cubic-bezier）。
  ★ 性能 ★
    只动 Opacity / 颜色 / 宽度，全部交给 WPF 的动画时钟；
    用户在「个性化」页关掉动画，所有函数直接落到终值；
    系统关了「显示动画」只去掉位移，淡入和数字滚动照旧（减弱，不是归零）。
=====================================================================
#>

$Script:Ease = @{
    # cubic-bezier(.23,1,.32,1) —— 冲出去然后很快稳住。默认用这个
    Out   = @(0.23, 1.0, 0.32, 1.0)
    # cubic-bezier(.77,0,.175,1) —— 两头慢中间快，用于位置移动
    InOut = @(0.77, 0.0, 0.175, 1.0)
}

# 时长（毫秒）。统一在这里改，别在调用处写死数字。和 design.md 5.3 一致。
$Script:Dur = @{
    Hover = 120    # 悬停底色过渡
    Panel = 200    # 右栏换内容 / 切页
    Count = 240    # 数字补间
    Bar   = 220    # 量程条补间
    Flash = 380    # 数值变化闪一下
}

function Test-MotionOn {
    <#
      动效总开关 = 用户在「个性化」页的开关。

      ★ 系统关了「显示动画」不等于这里关 ★
        那是「减弱」不是「归零」：保留淡入和数字滚动（它们回答「刚才变了什么」），
        只去掉位移（Start-FadeSlideIn 和切页动画里各自判断 $Script:SystemAnimOff）。
        老板自己的电脑就关着系统动画 —— 按「归零」处理的话，他那边整个界面是死的。
    #>
    return [bool]$Script:AnimEnabled
}

function New-Spline {
    <# 把四个控制点变成 WPF 的 KeySpline（= CSS cubic-bezier） #>
    param([double[]]$P)
    New-Object System.Windows.Media.Animation.KeySpline (
        (New-Object System.Windows.Point $P[0], $P[1]),
        (New-Object System.Windows.Point $P[2], $P[3]))
}

function New-DoubleTween {
    <# 造一条 double 动画。Curve 传 $Script:Ease 里的某一条。 #>
    param([double]$From, [double]$To, [double]$Ms, [double[]]$Curve = $null)
    if (-not $Curve) { $Curve = $Script:Ease.Out }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
    # 0 时刻用 Discrete 钉住起点，避免从控件当前值开始插值
    $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
                $From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))) | Out-Null
    $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                $To, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($Ms)),
                (New-Spline $Curve)))) | Out-Null
    return $a
}

function Start-Prop {
    <# 把一条 double 动画挂到某个元素的某个属性上跑起来 #>
    param($Element, $Property, [double]$From, [double]$To, [double]$Ms, [double[]]$Curve = $null)
    if ($null -eq $Element) { return }
    try { $Element.BeginAnimation($Property, (New-DoubleTween -From $From -To $To -Ms $Ms -Curve $Curve)) } catch { }
}

# =====================================================================
#  数字滚动
# =====================================================================
function Start-CountUp {
    <#
      让一个数字从当前值**滚**到目标值，而不是啪地换掉。
      「92」直接出现，用户不确定它是不是刚算出来的；从旧值滚过去，过程本身就在说「刚测完」。

      WPF 没法补间 TextBlock.Text（字符串），所以用一个 16ms 的计时器按 KeySpline 算中间值。
      这是全模块唯一一处逐帧回调，时长压在 240ms。
    #>
    param($Target, [double]$To, [int]$Decimals = 0, [string]$Suffix = '', [double]$Ms = 0)
    if ($null -eq $Target) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Count }

    $from = 0.0
    $cur = "$($Target.Text)" -replace '[^\d.\-]', ''
    if ($cur -and [double]::TryParse($cur, [ref]$null)) { $from = [double]$cur }
    $fmt = if ($Decimals -gt 0) { "F$Decimals" } else { 'F0' }

    if (-not (Test-MotionOn)) { $Target.Text = $To.ToString($fmt) + $Suffix; return }
    # 差得太小不值得动（占用率 21 → 22），直接写，省得一直在抖
    if ([math]::Abs($To - $from) -lt ([math]::Pow(10, -$Decimals) * 2)) {
        $Target.Text = $To.ToString($fmt) + $Suffix
        return
    }

    # ★ 先掐掉这个元素上还没跑完的上一轮补间 ★
    #   两个计时器同时往一个 TextBlock 里写，数字会来回跳 ——
    #   这个工具最不能出现的就是「数字看起来不可信」。
    try { if ($Target.Tag -is [System.Windows.Threading.DispatcherTimer]) { $Target.Tag.Stop() } } catch { }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(16)
    $timer.Tag = @{ T = $Target; From = $from; To = $To; Ms = $Ms; Fmt = $fmt; Suffix = $Suffix
        Sw = [Diagnostics.Stopwatch]::StartNew(); Sp = (New-Spline $Script:Ease.Out) }
    $timer.Add_Tick({
            $st = $this.Tag
            $p = $st.Sw.Elapsed.TotalMilliseconds / $st.Ms
            if ($p -ge 1) {
                $st.T.Text = $st.To.ToString($st.Fmt) + $st.Suffix
                $this.Stop()
                return
            }
            $v = $st.From + ($st.To - $st.From) * $st.Sp.GetSplineProgress($p)
            $st.T.Text = $v.ToString($st.Fmt) + $st.Suffix
        })
    $Target.Tag = $timer
    $timer.Start()
}

function Start-ValueFlash {
    <#
      读数变了，极短暂地变淡一下再回来 —— 回答「这个数刚变了还是我眼花」。
      ★ 最后一帧必须回到 1.0 ★ 否则每闪一次就停在半透明，越刷越暗。
    #>
    param($Element)
    if (-not (Test-MotionOn) -or $null -eq $Element) { return }
    try {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Script:Dur.Flash))
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    0.72, [Windows.Media.Animation.KeyTime]::FromPercent(0.14), (New-Spline $Script:Ease.Out)))) | Out-Null
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    1.0, [Windows.Media.Animation.KeyTime]::FromPercent(1.0), (New-Spline $Script:Ease.Out)))) | Out-Null
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch { }
}

function Start-BarTo {
    <# 量程条平滑滑到目标宽度。直接设 Width 是瞬间跳变，看不出「涨了还是跌了」。 #>
    param($Bar, [double]$ToWidth, [double]$Ms = 0)
    if ($null -eq $Bar) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Bar }
    if (-not (Test-MotionOn)) {
        $Bar.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $null)
        $Bar.Width = $ToWidth
        return
    }
    $from = if ([double]::IsNaN($Bar.ActualWidth)) { 0 } else { [double]$Bar.ActualWidth }
    Start-Prop $Bar ([System.Windows.FrameworkElement]::WidthProperty) $from $ToWidth $Ms $Script:Ease.Out
}

function Start-ColorFade {
    <#
      背景色平滑过渡（行 / 卡悬停）。
      用 ColorAnimation 而不是关键帧：鼠标快速扫过时动画被反复打断，
      ColorAnimation 从「当前实际颜色」重新出发，关键帧每次从头播会闪。
      资源里的画笔是 Frozen 的，不能直接做动画 —— 每次换一支独立画笔。
    #>
    param($Element, [string]$To, [double]$Ms = 0)
    if ($null -eq $Element) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Hover }
    $toC = [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex $To))
    if (-not (Test-MotionOn)) {
        $Element.Background = New-Object System.Windows.Media.SolidColorBrush $toC
        return
    }
    try {
        $cur = $Element.Background
        if ($cur -isnot [System.Windows.Media.SolidColorBrush] -or $cur.IsFrozen) {
            $start = if ($cur -is [System.Windows.Media.SolidColorBrush]) { $cur.Color } else { $toC }
            $cur = New-Object System.Windows.Media.SolidColorBrush $start
            $Element.Background = $cur
        }
        $anim = New-Object System.Windows.Media.Animation.ColorAnimation
        $anim.To = $toC
        $anim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
        $ez = New-Object System.Windows.Media.Animation.CubicEase
        $ez.EasingMode = 'EaseOut'
        $anim.EasingFunction = $ez
        $cur.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
    } catch {
        $Element.Background = New-Object System.Windows.Media.SolidColorBrush $toC
    }
}

# =====================================================================
#  可交互的行 / 卡：悬停 + 按下
# =====================================================================
function Add-Interactive {
    <#
      给任意 Border 挂上悬停 / 按下反馈。所有可点的行和卡都走这个，别各写各的。
        悬停  底色过渡到 BgHover（120ms），不位移
        按下  底色瞬时压到 SurfaceSunken，松开回悬停色

      BgNormal / BgHover 传色槽名（'Card'、'CardHover'、'Transparent'）。

      ★ 绝对不能用 $Border.Tag 存配置 ★
        Tag 是「这一行背后的那条数据」（预设 / 优化项 / 清理项），
        覆盖掉之后点行就把一个 hashtable 当数据传下去 —— 表现是「点了没反应」。
        配置存在元素自己的 Resources 里。
    #>
    param($Border, [string]$BgNormal = 'Transparent', [string]$BgHover = 'CardHover')
    if ($null -eq $Border) { return }
    $Border.Resources['__motion'] = @{ BgN = $BgNormal; BgH = $BgHover }

    $Border.Add_MouseEnter({
            if (Test-IsSelectedRow $this) { return }
            Start-ColorFade $this $this.Resources['__motion'].BgH
        })
    $Border.Add_MouseLeave({
            if (Test-IsSelectedRow $this) { return }
            Start-ColorFade $this $this.Resources['__motion'].BgN
        })
    $Border.Add_PreviewMouseLeftButtonDown({
            if (Test-IsSelectedRow $this) { return }
            try { $this.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex 'SurfaceSunken'))) } catch { }
        })
    $Border.Add_PreviewMouseLeftButtonUp({
            if (Test-IsSelectedRow $this) { return }
            try { $this.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex $this.Resources['__motion'].BgH))) } catch { }
        })
}

function Test-IsSelectedRow {
    <# 当前选中的行 / 预设不吃悬停反馈，免得鼠标一扫就把选中底色洗掉 #>
    param($Border)
    if ($Border.Resources['__sel'] -eq $true) { return $true }
    return ($Script:SelectedCard -eq $Border -or $Script:SelectedPresetCard -eq $Border)
}
