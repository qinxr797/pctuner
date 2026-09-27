#Requires -Version 5.1
<#
=====================================================================
  交互引擎（v6.1）
---------------------------------------------------------------------
  一套动效语言，只有两种运动（design.md 5.3）：

    位移 / 缩放  → 一条弹簧（老板在试玩台选的 A3：松手时弹过头约 16% 再回来）
    透明度 / 颜色 → ease-out，不弹

  时长只允许下面 $Script:Dur 里的几个档位。代码里不许写档位以外的数字。

  ★ 为什么弹簧要预先采样成关键帧 ★
    WPF 的 KeySpline 控制点被限制在 0～1，做不出超调；BackEase / ElasticEase
    的曲线形状和试玩台的 A3 对不上。另一条路是 Add-Type 编一个 C# 缓动类，
    但每次启动要多编译一次（慢、杀软爱拦 csc），而且 XAML 里引用不到动态程序集。
    所以按阻尼弹簧公式把 0→1 的曲线采样一遍（16ms 一个点）缓存起来，
    每次动画按「起点 + (终点 - 起点) × 曲线」生成关键帧 —— 纯 PowerShell、结果可复现。

  ★ 全部可打断 ★
    每个动画都从控件**此刻屏幕上的值**起步（GetValue 读到的是动画中的当前值），
    再用 SnapshotAndReplace 接管 —— 快速连点不会跳回起点、不会排队。

  ★ 系统「显示动画」开关不管这里 ★（老板拍板，2026-09-27）
    老板自己的电脑就关着它。想关动画只认「个性化」页里本软件自己的开关。
=====================================================================
#>

# ---------------------------------------------------------------------
#  缓动
# ---------------------------------------------------------------------
$Script:Ease = @{
    # cubic-bezier(.23,1,.32,1) —— 透明度 / 颜色 / 进度的统一 ease-out
    Out   = @(0.23, 1.0, 0.32, 1.0)
    # cubic-bezier(.77,0,.175,1) —— 屏幕内来回移动（目前只有量程条用）
    InOut = @(0.77, 0.0, 0.175, 1.0)
}

# 时长档位（毫秒）。和 design.md 5.3 一一对应，别在调用处写死数字。
$Script:Dur = @{
    Press   = 90     # 按下：缩到位
    Quick   = 120    # 悬停底色、退场
    Base    = 200    # 淡入、颜色、量程条
    Draw    = 260    # 对勾一笔画出、读数刷新
    Spring  = 620    # 弹簧从起步到停稳（体感在 150～250ms 就到位了，后面是余震）
    Count   = 900    # 健康度数字 + 圆环（全应用只此一处，属于「少见时刻」）
    Hold    = 2800   # 提示条停留
    Done    = 1200   # 按钮「完成」状态停留（B3）
    Stagger = 40     # 依次进场的间隔
}
$Script:StaggerMax = 6    # 最多错开 6 个，第 7 个起和第 6 个一起到 —— 不然最后一个要等半天

# ---------------------------------------------------------------------
#  弹簧（A3）
# ---------------------------------------------------------------------
#  阻尼比 0.5、固有频率 22.7 rad/s：
#    超调 = e^(-ζπ/√(1-ζ²)) = 16.3%      —— 对上试玩台 A3 的 linear() 峰值 1.163
#    到顶时间 = π / (ω√(1-ζ²)) = 160ms   —— 对上试玩台峰值在 26% × 620ms 附近
#    620ms 时振幅剩 e^(-ζω×0.62) < 0.1%  —— 停稳
$Script:SpringZeta = 0.5
$Script:SpringOmega = 22.7
$Script:SpringCurve = $null

function Get-SpringCurve {
    <# 0→1 的弹簧曲线，每 16ms 一个采样点，最后一点钉在 1。只算一次。 #>
    if ($Script:SpringCurve) { return $Script:SpringCurve }
    $z = $Script:SpringZeta; $w = $Script:SpringOmega
    $wd = $w * [math]::Sqrt(1 - $z * $z)
    $k = $z / [math]::Sqrt(1 - $z * $z)
    $pts = New-Object System.Collections.ArrayList
    $step = 16
    for ($ms = $step; $ms -lt $Script:Dur.Spring; $ms += $step) {
        $t = $ms / 1000.0
        $y = 1 - [math]::Exp(-$z * $w * $t) * ([math]::Cos($wd * $t) + $k * [math]::Sin($wd * $t))
        [void]$pts.Add(@($ms, $y))
    }
    [void]$pts.Add(@($Script:Dur.Spring, 1.0))
    $Script:SpringCurve = $pts
    return $pts
}

function New-SpringAnim {
    <# 一条从 From 弹到 To 的关键帧动画（DoubleAnimationUsingKeyFrames） #>
    param([double]$From, [double]$To, [double]$DelayMs = 0)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Script:Dur.Spring + $DelayMs))
    $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
                $From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))) | Out-Null
    if ($DelayMs -gt 0) {
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
                    $From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($DelayMs))))) | Out-Null
    }
    $d = $To - $From
    foreach ($p in (Get-SpringCurve)) {
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame (
                    ($From + $d * $p[1]), [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($p[0] + $DelayMs))))) | Out-Null
    }
    return $a
}

function Start-Spring {
    <#
      把某个属性用弹簧送到 To。起点 = 此刻屏幕上的值（可打断的关键）。
      动画关了就直接落到终值。
    #>
    param($Target, $Property, [double]$To, [double]$DelayMs = 0, $From = $null)
    if ($null -eq $Target) { return }
    if (-not (Test-MotionOn)) {
        try { $Target.BeginAnimation($Property, $null); $Target.SetValue($Property, [double]$To) } catch { }
        return
    }
    try {
        $cur = if ($null -ne $From) { [double]$From } else { [double]$Target.GetValue($Property) }
        $Target.BeginAnimation($Property, (New-SpringAnim -From $cur -To $To -DelayMs $DelayMs),
            [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
    } catch { }
}

# ---------------------------------------------------------------------
#  ease-out 补间（透明度 / 颜色 / 进度）
# ---------------------------------------------------------------------
function Test-MotionOn {
    <# 动效总开关 = 「个性化」页里本软件自己的开关。系统的「显示动画」不在这里判断。 #>
    return [bool]$Script:AnimEnabled
}

function New-Spline {
    <# 四个控制点 → WPF 的 KeySpline（= CSS cubic-bezier） #>
    param([double[]]$P)
    New-Object System.Windows.Media.Animation.KeySpline (
        (New-Object System.Windows.Point $P[0], $P[1]),
        (New-Object System.Windows.Point $P[2], $P[3]))
}

function New-DoubleTween {
    <# 一条 ease-out（或指定曲线）补间。From 为 $null 时从当前值起步 —— 可打断。 #>
    param($From, [double]$To, [double]$Ms, [double[]]$Curve = $null, [double]$DelayMs = 0)
    if (-not $Curve) { $Curve = $Script:Ease.Out }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms + $DelayMs))
    if ($null -ne $From) {
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
                    [double]$From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))) | Out-Null
        if ($DelayMs -gt 0) {
            $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame (
                        [double]$From, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($DelayMs))))) | Out-Null
        }
    }
    $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                $To, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($Ms + $DelayMs)),
                (New-Spline $Curve)))) | Out-Null
    return $a
}

function Start-Prop {
    <# 把一条补间挂到某个属性上。From 给 $null = 从当前值起步。 #>
    param($Element, $Property, $From, [double]$To, [double]$Ms, [double[]]$Curve = $null, [double]$DelayMs = 0)
    if ($null -eq $Element) { return }
    if (-not (Test-MotionOn)) {
        try { $Element.BeginAnimation($Property, $null); $Element.SetValue($Property, [double]$To) } catch { }
        return
    }
    try {
        $Element.BeginAnimation($Property, (New-DoubleTween -From $From -To $To -Ms $Ms -Curve $Curve -DelayMs $DelayMs),
            [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
    } catch { }
}

function Start-Fade {
    <# 透明度到 To，ease-out，从当前值起步 #>
    param($Element, [double]$To, [double]$Ms = 0, [double]$DelayMs = 0, $From = $null)
    if ($Ms -le 0) { $Ms = $Script:Dur.Base }
    Start-Prop $Element ([System.Windows.UIElement]::OpacityProperty) $From $To $Ms $Script:Ease.Out $DelayMs
}

function Get-TranslateOf {
    <# 拿到（必要时装上）元素的 TranslateTransform。已有 TransformGroup 就在里面找。 #>
    param($Element)
    $rt = $Element.RenderTransform
    if ($rt -is [System.Windows.Media.TranslateTransform] -and -not $rt.IsFrozen) { return $rt }
    if ($rt -is [System.Windows.Media.TransformGroup] -and -not $rt.IsFrozen) {
        foreach ($c in $rt.Children) { if ($c -is [System.Windows.Media.TranslateTransform]) { return $c } }
    }
    $tt = New-Object System.Windows.Media.TranslateTransform 0, 0
    $Element.RenderTransform = $tt
    return $tt
}

function Start-EnterIn {
    <#
      一块内容进场：透明度 0→1（ease-out, Base）+ 从下方 $Rise 像素弹到位（弹簧）。
      行程压小（8～12px），弹簧的 16% 超调只剩一两个像素 —— 看起来是「稳稳落位」，不是弹跳。
    #>
    param($Element, [double]$DelayMs = 0, [double]$Rise = 12)
    if ($null -eq $Element) { return }
    if (-not (Test-MotionOn)) {
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $Element.Opacity = 1
        try { $tt0 = Get-TranslateOf $Element; $tt0.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null); $tt0.Y = 0 } catch { }
        return
    }
    Start-Fade $Element 1 $Script:Dur.Base $DelayMs 0
    $tt = Get-TranslateOf $Element
    Start-Spring $tt ([System.Windows.Media.TranslateTransform]::YProperty) 0 $DelayMs $Rise
}

function Start-StaggerIn {
    <#
      一组内容依次进场（design.md 5.3）：每个比前一个晚 40ms，最多错开 6 个。
      只在「内容刚换了」的时候用（切页、列表重建、结果出来），纯页面刷新不用。
    #>
    param($Elements, [double]$Rise = 12, [double]$StartMs = 0)
    $i = 0
    foreach ($e in @($Elements)) {
        if ($null -eq $e) { continue }
        Start-EnterIn $e ($StartMs + [math]::Min($i, $Script:StaggerMax - 1) * $Script:Dur.Stagger) $Rise
        $i++
    }
}

# =====================================================================
#  数字滚动
# =====================================================================
function Start-CountUp {
    <#
      数字从当前值滚到目标值 —— 回答「这是刚测出来的新值」。
      WPF 补不了 TextBlock.Text（字符串），用 16ms 计时器按 ease-out 算中间值。
      OnFrame 每帧拿到当前值（健康度圆环靠它和数字同步）。
      ★ 先掐掉这个元素上还没跑完的上一轮 ★ 两个计时器同时写，数字会来回跳。
    #>
    param($Target, [double]$To, [int]$Decimals = 0, [string]$Suffix = '', [double]$Ms = 0, $OnFrame = $null, $From = $null)
    if ($null -eq $Target) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Draw }
    $fromV = 0.0
    if ($null -ne $From) { $fromV = [double]$From }
    else {
        $cur = "$($Target.Text)" -replace '[^\d.\-]', ''
        if ($cur -and [double]::TryParse($cur, [ref]$null)) { $fromV = [double]$cur }
    }
    $fmt = if ($Decimals -gt 0) { "F$Decimals" } else { 'F0' }
    try { if ($Target.Tag -is [System.Windows.Threading.DispatcherTimer]) { $Target.Tag.Stop() } } catch { }

    if (-not (Test-MotionOn) -or [math]::Abs($To - $fromV) -lt ([math]::Pow(10, -$Decimals) * 2)) {
        $Target.Text = $To.ToString($fmt) + $Suffix
        if ($OnFrame) { & $OnFrame $To }
        return
    }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(16)
    $timer.Tag = @{ T = $Target; From = $fromV; To = $To; Ms = $Ms; Fmt = $fmt; Suffix = $Suffix; F = $OnFrame
        Sw = [Diagnostics.Stopwatch]::StartNew(); Sp = (New-Spline $Script:Ease.Out) }
    $timer.Add_Tick({
            $st = $this.Tag
            $p = [math]::Min(1.0, $st.Sw.Elapsed.TotalMilliseconds / $st.Ms)
            $v = $st.From + ($st.To - $st.From) * $st.Sp.GetSplineProgress($p)
            $st.T.Text = $v.ToString($st.Fmt) + $st.Suffix
            if ($st.F) { try { & $st.F $v } catch { } }
            if ($p -ge 1) { $st.T.Text = $st.To.ToString($st.Fmt) + $st.Suffix; $this.Stop() }
        })
    $Target.Tag = $timer
    $timer.Start()
}

function Start-ValueFlash {
    <# 读数变了，极短暂地变淡一下再回来。★ 最后一帧必须回到 1.0 ★ 否则越刷越暗。 #>
    param($Element)
    if (-not (Test-MotionOn) -or $null -eq $Element) { return }
    try {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $a.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Script:Dur.Draw))
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    0.72, [Windows.Media.Animation.KeyTime]::FromPercent(0.2), (New-Spline $Script:Ease.Out)))) | Out-Null
        $a.KeyFrames.Add((New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame (
                    1.0, [Windows.Media.Animation.KeyTime]::FromPercent(1.0), (New-Spline $Script:Ease.Out)))) | Out-Null
        $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch { }
}

function Start-ColorFade {
    <#
      背景色平滑过渡（悬停）。ColorAnimation 从当前实际颜色出发，来回扫不会闪。
      资源里的画笔是 Frozen 的，不能直接做动画 —— 每次换一支独立画笔。
    #>
    param($Element, [string]$To, [double]$Ms = 0)
    if ($null -eq $Element) { return }
    if ($Ms -le 0) { $Ms = $Script:Dur.Quick }
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
        悬停  底色过渡到 BgHover（Quick 120ms），不位移
        按下  底色瞬时压到 SurfaceSunken，松开回悬停色
      行不缩放：一整行横着缩，旁边那一列看起来在抖（v5 实测过）。

      ★ 绝对不能用 $Border.Tag 存配置 ★ Tag 是「这一行背后的那条数据」。
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

# =====================================================================
#  按钮按下（A3 手感）
# ---------------------------------------------------------------------
#  按下 90ms 缩到 0.97（ease-out，立刻到位），松手 / 移出用弹簧弹回 1。
#  回答「点上了吗」—— 老板原话「点按钮没有动画」就是缺这个。
#  MDIX 的水波纹还在（压淡），两者是一回事的两个面：缩放说「按下了」，波纹说「按在哪」。
#
#  ★ 类级注册，不遍历可视树 ★
#    TabControl 只给当前页建可视树，启动时遍历只挂得上概览页的按钮（v5 踩过）。
#    给 Button 这个类型注册一次，之后创建的每个按钮都自动带上。
#  ★ 只挂 Button ★ 勾选框、开关有自己的动效；滚动条里的 RepeatButton 不该缩。
# =====================================================================
function Get-PressScale {
    <# 拿到（必要时装上）按钮的 ScaleTransform，缩放中心在正中 —— 默认左上角缩会往左上跑 #>
    param($Ctrl)
    if ($Ctrl.RenderTransform -is [System.Windows.Media.ScaleTransform] -and -not $Ctrl.RenderTransform.IsFrozen) { return $Ctrl.RenderTransform }
    $Ctrl.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $sc = New-Object System.Windows.Media.ScaleTransform 1, 1
    $Ctrl.RenderTransform = $sc
    return $sc
}

function Set-PressScale {
    param($Ctrl, [bool]$Down)
    if (-not $Ctrl.IsEnabled) { return }
    $sc = Get-PressScale $Ctrl
    foreach ($prop in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
        if ($Down) { Start-Prop $sc $prop $null 0.97 $Script:Dur.Press $Script:Ease.Out }
        else { Start-Spring $sc $prop 1.0 }
    }
}

function Install-PressFeedback {
    if ($Script:PressInstalled) { return }
    try {
        $down = [System.Windows.Input.MouseButtonEventHandler] { param($s, $e) Set-PressScale $s $true }
        $up = [System.Windows.Input.MouseButtonEventHandler] { param($s, $e) Set-PressScale $s $false }
        $leave = [System.Windows.Input.MouseEventHandler] {
            param($s, $e)
            $sc = $s.RenderTransform
            if ($sc -is [System.Windows.Media.ScaleTransform] -and $sc.ScaleX -lt 0.999) { Set-PressScale $s $false }
        }
        $t = [System.Windows.Controls.Button]
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent, $down, $true)
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent, $up, $true)
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.UIElement]::MouseLeaveEvent, $leave, $true)
        $Script:PressInstalled = $true
    } catch { $Script:PressError = "$($_.Exception.Message)" }
}

# =====================================================================
#  勾选框（D2 画勾）和开关（D1 弹簧开关）
# ---------------------------------------------------------------------
#  两者都是 CheckBox，模板在全局样式字典里（默认勾选框 / SwitchBox）。这里只管动。
#    勾选框 勾上：底色淡入（Base）、方框从 0.85 弹回 1（弹簧）、对勾 40ms 后一笔画出（Draw）
#           取消：底色和对勾一起退掉（Quick），不弹 —— 取消是「收」，不值得庆祝
#    开关   开 / 关：圆点弹簧滑到另一头，轨道颜色淡入淡出（Base）
#           按住：圆点拉长 4px（Press），松手缩回；开着的时候往左长，右边缘不动
#
#  ★ 类级注册 Checked / Unchecked ★ 程序里批量改 IsChecked（「勾选推荐项」）也会播，
#    因为那也是「状态变了」；还没显示过的控件（别的页）在首次排版时直接落到终态，不播。
# =====================================================================
function Get-TplPart { param($Ctrl, [string]$Name) try { return $Ctrl.Template.FindName($Name, $Ctrl) } catch { return $null } }

function Set-ToggleVisual {
    <# 把勾选框 / 开关的外观对齐到 IsChecked。Animate = $false 时瞬间到位 #>
    param($Cb, [bool]$Animate)
    $on = [bool]$Cb.IsChecked
    $knob = Get-TplPart $Cb 'KnobX'
    if ($knob) {
        $trackOn = Get-TplPart $Cb 'TrackOn'
        $x = if ($on) { 16.0 } else { 0.0 }
        if ($Animate -and $Cb.IsLoaded) {
            Start-Spring $knob ([System.Windows.Media.TranslateTransform]::XProperty) $x
            Start-Fade $trackOn $(if ($on) { 1 } else { 0 }) $Script:Dur.Base
        } else {
            $knob.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null); $knob.X = $x
            $trackOn.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $trackOn.Opacity = $(if ($on) { 1 } else { 0 })
        }
        return
    }
    $tick = Get-TplPart $Cb 'Tick'
    if ($null -eq $tick) { return }
    $fill = Get-TplPart $Cb 'Fill'
    $scale = Get-TplPart $Cb 'BoxScale'
    $dashP = [System.Windows.Shapes.Shape]::StrokeDashOffsetProperty
    if ($Animate -and $Cb.IsLoaded -and (Test-MotionOn)) {
        if ($on) {
            Start-Fade $fill 1 $Script:Dur.Base
            foreach ($prop in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
                Start-Spring $scale $prop 1.0 0 0.85
            }
            Start-Prop $tick $dashP $null 0 $Script:Dur.Draw $Script:Ease.Out $Script:Dur.Stagger
        } else {
            Start-Fade $fill 0 $Script:Dur.Quick
            Start-Prop $tick $dashP $null 6 $Script:Dur.Quick $Script:Ease.Out
        }
    } else {
        $fill.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $fill.Opacity = $(if ($on) { 1 } else { 0 })
        $tick.BeginAnimation($dashP, $null); $tick.StrokeDashOffset = $(if ($on) { 0 } else { 6 })
    }
}

function Install-ToggleMotion {
    if ($Script:ToggleInstalled) { return }
    try {
        $t = [System.Windows.Controls.CheckBox]
        $chg = [System.Windows.RoutedEventHandler] { param($s, $e) if ($e.OriginalSource -eq $s) { Set-ToggleVisual $s $true } }
        # ★ 首次排版时对齐一次，用 SizeChanged 不用 Loaded ★
        #   Loaded 是广播出来的，不走类级处理器 —— 注册了也收不到（实测 0 次）。
        #   SizeChanged 是普通路由事件，首次排版必触发；每个控件只对齐一次。
        $load = [System.Windows.SizeChangedEventHandler] {
            param($s, $e)
            if ($s.Resources['__tsync'] -eq $true) { return }
            $s.Resources['__tsync'] = $true
            Set-ToggleVisual $s $false
        }
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $chg, $true)
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $chg, $true)
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.FrameworkElement]::SizeChangedEvent, $load, $true)
        # 开关按住拉长
        $down = [System.Windows.Input.MouseButtonEventHandler] {
            param($s, $e)
            $k = Get-TplPart $s 'Knob'; $kx = Get-TplPart $s 'KnobX'
            if ($null -eq $k -or -not $s.IsEnabled) { return }
            Start-Prop $k ([System.Windows.FrameworkElement]::WidthProperty) $null 18 $Script:Dur.Press $Script:Ease.Out
            if ($s.IsChecked) { Start-Prop $kx ([System.Windows.Media.TranslateTransform]::XProperty) $null 12 $Script:Dur.Press $Script:Ease.Out }
        }
        $up = [System.Windows.Input.MouseEventHandler] {
            param($s, $e)
            $k = Get-TplPart $s 'Knob'
            if ($null -eq $k -or $k.ActualWidth -le 14.01) { return }
            Start-Prop $k ([System.Windows.FrameworkElement]::WidthProperty) $null 14 $Script:Dur.Press $Script:Ease.Out
            # 松手没切换（拖出去再松）也要回到原位
            $kx = Get-TplPart $s 'KnobX'
            if ($kx) { Start-Spring $kx ([System.Windows.Media.TranslateTransform]::XProperty) $(if ($s.IsChecked) { 16.0 } else { 0.0 }) }
        }
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent, $down, $true)
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.UIElement]::MouseLeaveEvent, $up, $true)
        [System.Windows.EventManager]::RegisterClassHandler($t, [System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent,
            [System.Windows.Input.MouseButtonEventHandler] { param($s, $e) $k = Get-TplPart $s 'Knob'; if ($k) { Start-Prop $k ([System.Windows.FrameworkElement]::WidthProperty) $null 14 $Script:Dur.Press $Script:Ease.Out } }, $true)
        $Script:ToggleInstalled = $true
    } catch { $Script:ToggleError = "$($_.Exception.Message)" }
}

# =====================================================================
#  选中描边 + 对勾徽章（C4）
# ---------------------------------------------------------------------
#  只放在预设卡上（按用途选 / 受检类别 / 竞技射击 / 浏览器瘦身）。
#  徽章 18px 强调色圆 + 白勾，压在卡片右上角外沿。
#    选中：从 0.6 弹到 1（弹簧）+ 淡入（Base），勾在 Quick 之后一笔画出（Draw）
#    取消：缩回 0.6 + 淡出（Quick），不弹
#  ★ 从 0.6 起，不从 0 起 ★ 没有东西是从「无」里长出来的。
# =====================================================================
function New-CheckBadge {
    $host_ = New-Object System.Windows.Controls.Grid
    $host_.Width = 18; $host_.Height = 18
    $host_.HorizontalAlignment = 'Right'; $host_.VerticalAlignment = 'Top'
    $host_.Margin = New-Object System.Windows.Thickness 0, -12, -16, 0
    $host_.IsHitTestVisible = $false
    $host_.Opacity = 0
    $host_.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $sc = New-Object System.Windows.Media.ScaleTransform 0.6, 0.6
    $host_.RenderTransform = $sc
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Fill = Get-Brush 'Accent'
    $host_.Children.Add($dot) | Out-Null
    $tick = New-Object System.Windows.Shapes.Path
    $tick.Data = [System.Windows.Media.Geometry]::Parse('M 5,9.2 L 7.8,11.9 L 13,6.3')
    $tick.Stroke = Get-Brush 'OnAccent'
    $tick.StrokeThickness = 2
    $tick.StrokeStartLineCap = 'Round'; $tick.StrokeEndLineCap = 'Round'; $tick.StrokeLineJoin = 'Round'
    $tick.StrokeDashCap = 'Flat'
    # 路径长 ~11.5px / 线宽 2 = 虚线单位 6
    $dash = New-Object System.Windows.Media.DoubleCollection
    $dash.Add(6); $dash.Add(6)
    $tick.StrokeDashArray = $dash
    $tick.StrokeDashOffset = 6
    $host_.Children.Add($tick) | Out-Null
    return @{ Host = $host_; Scale = $sc; Tick = $tick }
}

function Set-CheckBadge {
    param($B, [bool]$On)
    if ($null -eq $B) { return }
    $sx = [System.Windows.Media.ScaleTransform]::ScaleXProperty
    $sy = [System.Windows.Media.ScaleTransform]::ScaleYProperty
    $dashP = [System.Windows.Shapes.Shape]::StrokeDashOffsetProperty
    if ($On) {
        Start-Fade $B.Host 1 $Script:Dur.Base
        Start-Spring $B.Scale $sx 1.0
        Start-Spring $B.Scale $sy 1.0
        Start-Prop $B.Tick $dashP 6 0 $Script:Dur.Draw $Script:Ease.Out $Script:Dur.Quick
    } else {
        Start-Fade $B.Host 0 $Script:Dur.Quick
        Start-Prop $B.Scale $sx $null 0.6 $Script:Dur.Quick $Script:Ease.Out
        Start-Prop $B.Scale $sy $null 0.6 $Script:Dur.Quick $Script:Ease.Out
        Start-Prop $B.Tick $dashP $null 6 $Script:Dur.Quick $Script:Ease.Out
    }
}

# =====================================================================
#  图标微动（D7）
# ---------------------------------------------------------------------
#  只放在侧边栏图标和刷新类按钮上（design.md 5.3），悬停时播一次，全部是弹簧：
#    Wiggle   清理 / 维护 / 体检：从 -12° 弹回 0（弹簧自带的一次回摆就是「晃一下」）
#    Zap      性能优化的火箭：从上方 3px、1.12 倍弹回原位（「跳一下」）
#    Pop      其余：从 1.12 倍弹回 1
#    Refresh  刷新按钮：在当前角度上再转半圈
#  幅度都压在 12° / 1.12 倍以内 —— 侧边栏一天要扫过几十次，大了就吵。
# =====================================================================
function Get-NudgeTransforms {
    param($Icon)
    $n = $Icon.Resources['__nudge']
    if ($n) { return $n }
    $Icon.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $tg = New-Object System.Windows.Media.TransformGroup
    $sc = New-Object System.Windows.Media.ScaleTransform 1, 1
    $rt = New-Object System.Windows.Media.RotateTransform 0
    $tt = New-Object System.Windows.Media.TranslateTransform 0, 0
    $tg.Children.Add($sc); $tg.Children.Add($rt); $tg.Children.Add($tt)
    $Icon.RenderTransform = $tg
    $n = @{ S = $sc; R = $rt; T = $tt }
    $Icon.Resources['__nudge'] = $n
    return $n
}

function Start-IconNudge {
    param($Icon, [string]$Style = 'Pop')
    if ($null -eq $Icon -or -not (Test-MotionOn)) { return }
    $n = Get-NudgeTransforms $Icon
    $sx = [System.Windows.Media.ScaleTransform]::ScaleXProperty
    $sy = [System.Windows.Media.ScaleTransform]::ScaleYProperty
    $ang = [System.Windows.Media.RotateTransform]::AngleProperty
    switch ($Style) {
        'Wiggle'  { Start-Spring $n.R $ang 0 0 -12 }
        'Zap'     { Start-Spring $n.T ([System.Windows.Media.TranslateTransform]::YProperty) 0 0 -3; Start-Spring $n.S $sx 1 0 1.12; Start-Spring $n.S $sy 1 0 1.12 }
        'Refresh' { Start-Spring $n.R $ang ([double]$n.R.Angle + 180) }
        default   { Start-Spring $n.S $sx 1 0 1.12; Start-Spring $n.S $sy 1 0 1.12 }
    }
}

function Set-RefreshButton {
    <# 给刷新类按钮前面加一个刷新图标，悬停时转半圈 #>
    param($Button)
    if ($null -eq $Button) { return }
    $text = "$($Button.Content)"
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $ic = New-Object MaterialDesignThemes.Wpf.PackIcon
    $ic.Kind = 'Refresh'
    $ic.Width = 16; $ic.Height = 16
    $ic.VerticalAlignment = 'Center'
    $ic.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $sp.Children.Add($ic) | Out-Null
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.VerticalAlignment = 'Center'
    $sp.Children.Add($tb) | Out-Null
    $Button.Content = $sp
    $Button.Resources['__icon'] = $ic
    $Button.Add_MouseEnter({ Start-IconNudge $this.Resources['__icon'] 'Refresh' })
}

# =====================================================================
#  完成变绿勾（B3，改着做）
# ---------------------------------------------------------------------
#  只挂在三个要等的主按钮上：应用选中的优化 / 开始清理选中项 / 开始维护。
#    确认之后  按钮写「处理中…」并禁用（顺带防止活还没干完又点一次）
#    做完之后  底色换成 ok 绿、对勾从 0.6 弹到 1 +「完成」，停 Done（1200ms）后恢复
#    取消 / 出错  直接恢复，不播
#
#  ★ 不转圈 ★ 这些活是在界面线程上一项一项做的（功能不动），每做一项界面才喘一口气，
#    转圈会一顿一顿地跳 —— 比不转更廉价。所以试玩台 B3 的「转圈」那一半砍了，只留「变绿勾」。
# =====================================================================
function Enter-ActionBusy {
    <# 在动作函数里、用户点了「确定」之后调：按钮进入「处理中…」。没有挂按钮（比如「只应用这一项」）就什么都不做 #>
    $b = $Script:ActiveButton
    if ($null -eq $b) { return }
    $b.Resources['__busyContent'] = $b.Content
    $b.Resources['__busyEnabled'] = $b.IsEnabled
    $b.Content = '处理中…'
    $b.IsEnabled = $false
}

function Invoke-WithDone {
    param($Button, [scriptblock]$Action)
    $Script:ActiveButton = $Button
    $Script:LastActionDone = $false
    try { & $Action }
    finally {
        $Script:ActiveButton = $null
        if ($Button.Resources.Contains('__busyContent')) {
            $Button.Content = $Button.Resources['__busyContent']
            $Button.IsEnabled = [bool]$Button.Resources['__busyEnabled']
            $Button.Resources.Remove('__busyContent')
            $Button.Resources.Remove('__busyEnabled')
        }
    }
    if ($Script:LastActionDone) { Start-DoneMorph $Button }
}

function Start-DoneMorph {
    param($Button)
    if ($null -eq $Button) { return }
    $orig = $Button.Content
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $ic = New-Object MaterialDesignThemes.Wpf.PackIcon
    $ic.Kind = 'Check'
    $ic.Width = 16; $ic.Height = 16
    $ic.VerticalAlignment = 'Center'
    $ic.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $ic.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $sc = New-Object System.Windows.Media.ScaleTransform 0.6, 0.6
    $ic.RenderTransform = $sc
    $sp.Children.Add($ic) | Out-Null
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = '完成'
    $tb.VerticalAlignment = 'Center'
    $sp.Children.Add($tb) | Out-Null
    $Button.Content = $sp
    $Button.IsHitTestVisible = $false
    # 语义色：成功用 ok 绿（深色皮肤下自动提亮），字色跟着换，保证对比度
    Start-ColorFade $Button '#556B54' $Script:Dur.Base
    try { $Button.Foreground = [System.Windows.Media.Brush][System.Windows.Application]::Current.Resources['OnSemOk'] } catch { }
    Start-Spring $sc ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1.0
    Start-Spring $sc ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1.0
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($Script:Dur.Done)
    $t.Tag = @{ B = $Button; C = $orig }
    $t.Add_Tick({
            $this.Stop()
            $st = $this.Tag
            $st.B.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
            $st.B.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
            $st.B.Content = $st.C
            $st.B.IsHitTestVisible = $true
        })
    $t.Start()
}
