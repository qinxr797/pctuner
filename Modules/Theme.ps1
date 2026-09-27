<#
=====================================================================
  Theme.ps1  ——  换肤（v6.0：浅色默认 + 深色备选）
---------------------------------------------------------------------
  一套皮肤 = 一列色槽取值（见 design.md 1.1）。只有两列：浅色、深色。

  ★ 换肤怎么生效的 ★
    1. XAML 里所有中性色都写成 {DynamicResource 槽名}
       → 改 Application.Resources['槽名'] 就整个界面（连同弹窗）跟着变
    2. 代码里画的元素走 Get-Brush '槽名' —— 它按当前皮肤取值，
       换肤之后 Redraw-AllPages 把代码画的页面重画一遍
    3. MDIX（MaterialDesignInXamlToolkit）的控件用它自己的 BaseTheme 切深浅，
       再把它的几支关键画笔（底色、卡片、前景、主色）盖成我们的色槽，
       控件和我们自己画的东西才是同一套颜色
    4. 图片背景额外给窗口铺一层 ImageBrush，并把内容区调成半透明让图透出来

  ★ 哪些颜色不参与换肤 ★
    绿 / 卡其 / 玫瑰红 / 陶那几个**语义色**只换明暗、不换色相 ——
    「高危」永远是红的。这是故意的限制，别为了好看去掉。

  皮肤选择存在 Backup\theme.json，下次启动自动套用。
=====================================================================
#>

# =====================================================================
#  色槽取值。★ 改这里之前先改 design.md 1.1 ★
# =====================================================================
$Script:Palettes = [ordered]@{
    '浅色' = @{
        Canvas = '#F4F5FA'; Sidebar = '#FFFFFF'; Card = '#FFFFFF'; CardHover = '#F7F8FC'
        SurfaceAlt = '#F7F8FC'; SurfaceSunken = '#EEF0F6'
        Stroke = '#ECEEF4'; StrokeMed = '#E2E5EE'; StrokeStrong = '#C9CDE0'
        TextMain = '#1E2046'; TextMid = '#4A4E6D'; TextDim = '#666A88'
        Accent = '#5B5FD6'; AccentHover = '#7478E0'; AccentPressed = '#4B53B8'; AccentTint = '#EEEFFC'; OnAccent = '#FFFFFF'
        HeroFill = '#4B53B8'; OnHero = '#FFFFFF'; OnHeroDim = '#D4D6F7'; OnHeroTrack = '#6B72C9'
    }
    '深色' = @{
        Canvas = '#13141C'; Sidebar = '#1B1D29'; Card = '#1B1D29'; CardHover = '#222534'
        SurfaceAlt = '#222534'; SurfaceSunken = '#0F1017'
        Stroke = '#2A2D3E'; StrokeMed = '#33374A'; StrokeStrong = '#4A4F68'
        TextMain = '#ECEDF6'; TextMid = '#C3C5DA'; TextDim = '#9A9DB6'
        Accent = '#8B8FF0'; AccentHover = '#A3A6F5'; AccentPressed = '#6F73E0'; AccentTint = '#26284A'; OnAccent = '#13141C'
        HeroFill = '#4B53B8'; OnHero = '#FFFFFF'; OnHeroDim = '#D4D6F7'; OnHeroTrack = '#6B72C9'
    }
}

$Script:ThemeDesc = @{
    '浅色' = '浅灰蓝画布上放白色卡片。白天用，默认就是它。'
    '深色' = '深蓝灰底。晚上用眼睛舒服一些，功能完全一样。'
}

# =====================================================================
#  语义色：色相固定，只按皮肤换明暗（前景 / 底成对）
# ---------------------------------------------------------------------
#  左边是代码里写的色号（也是 Games.ps1 的 Get-VerdictColor 返回的），
#  右边 @(浅色, 深色)。值以 '@' 开头的表示「借一个色槽」。
#  ★ 成对是关键 ★ 只换前景不换底，或者反过来，都会糊成一团。
# =====================================================================
$Script:SemanticColors = @{
    # ---- 绿：良好 / 必做 / 低风险 ----
    '#556B54' = @('#556B54', '#9CC49D')
    '#E7EBE4' = @('#E7EBE4', '#1D2A20')
    '#E2E7E0' = @('#E7EBE4', '#1D2A20')     # 旧的底色别名
    '#DCE8DA' = @('#E7EBE4', '#1D2A20')
    # ---- 卡其：需实测 / 中风险 / 可疑 ----
    '#7A6B45' = @('#7A6B45', '#DCC68C')
    '#EDE7D9' = @('#F4F0E7', '#2B2619')     # 浅色底比 v5 提亮一档：#EDE7D9 上卡其字只有 4.24:1
    '#F0EADC' = @('#F4F0E7', '#2B2619')
    # ---- 玫瑰红：高危 / 高风险 ----
    '#8A5750' = @('#8A5750', '#E4A69E')
    '#EDE0DD' = @('#EDE0DD', '#2E1E1C')
    '#EFE3E0' = @('#EDE0DD', '#2E1E1C')
    # ---- 陶：会弹黑框 ----
    '#89694F' = @('#89694F', '#D6AB85')
    '#EDE2D6' = @('#F8F4EF', '#2B2117')     # 同上：#EDE2D6 上陶色字只有 3.92:1
    # ---- 结论里的「中性」「推荐」：不是状态，借中性色槽 ----
    '#66635B' = @('@TextDim', '@TextDim')
    '#55606F' = @('@TextMid', '@TextMid')
    '#E8E7E2' = @('@SurfaceSunken', '@SurfaceSunken')
    '#E4E7EC' = @('@SurfaceSunken', '@SurfaceSunken')
}

# =====================================================================
#  我们的色槽 -> MDIX 的画笔键
# ---------------------------------------------------------------------
#  MDIX 控件模板里引用的是这些键。盖成我们的色，勾选框、输入框、
#  滑块、滚动条才和我们自己画的卡片是同一套颜色。
#  写进 Application.Resources 自己的键 —— 它优先于合并进来的 MDIX 字典。
# =====================================================================
$Script:MdBrushMap = @{
    Canvas       = @('MaterialDesign.Brush.Background', 'MaterialDesignPaper', 'MaterialDesignBackground')
    Card         = @('MaterialDesign.Brush.Card.Background', 'MaterialDesignCardBackground', 'MaterialDesign.Brush.ToolTip.Background')
    Stroke       = @('MaterialDesign.Brush.Card.Border', 'MaterialDesign.Brush.Separator.Background', 'MaterialDesignDivider')
    StrokeMed    = @('MaterialDesign.Brush.TextBox.OutlineInactiveBorder', 'MaterialDesign.Brush.ComboBox.OutlineInactiveBorder')
    StrokeStrong = @('MaterialDesign.Brush.TextBox.Border', 'MaterialDesign.Brush.TextBox.OutlineBorder', 'MaterialDesign.Brush.TextBox.HoverBorder', 'MaterialDesign.Brush.ScrollBar.Foreground', 'MaterialDesignTextBoxBorder')
    TextMain     = @('MaterialDesign.Brush.Foreground', 'MaterialDesignBody')
    TextDim      = @('MaterialDesign.Brush.ForegroundLight', 'MaterialDesignBodyLight', 'MaterialDesign.Brush.CheckBox.Off', 'MaterialDesign.Brush.CheckBox.UncheckedBorder', 'MaterialDesignCheckBoxOff')
    Accent       = @('MaterialDesign.Brush.Primary', 'MaterialDesign.Brush.Secondary')
    AccentHover  = @('MaterialDesign.Brush.Primary.Light', 'MaterialDesign.Brush.Secondary.Light')
    AccentPressed = @('MaterialDesign.Brush.Primary.Dark', 'MaterialDesign.Brush.Secondary.Dark')
    OnAccent     = @('MaterialDesign.Brush.Primary.Foreground', 'MaterialDesign.Brush.Secondary.Foreground', 'MaterialDesign.Brush.Primary.Light.Foreground', 'MaterialDesign.Brush.Primary.Dark.Foreground')
    CardHover    = @('MaterialDesign.Brush.TextBox.HoverBackground', 'MaterialDesign.Brush.ListView.Hover')
    SurfaceAlt   = @('MaterialDesign.Brush.TextBox.FilledBackground')
}

function Get-BuiltinThemes {
    <# 内置皮肤。个性化页按这个顺序画色样。 #>
    $out = [ordered]@{}
    foreach ($n in $Script:Palettes.Keys) {
        $c = $Script:Palettes[$n]
        $out[$n] = @{ Desc = $Script:ThemeDesc[$n]; Swatch = @($c.Canvas, $c.Card, $c.Accent); Colors = $c }
    }
    return $out
}

function Resolve-ThemeName {
    <#
      把存下来的皮肤名归到现在的两套里。
      v5 的七套皮肤（暖灰 / 雾霾蓝 / 检验单 / 石墨深色……）升级上来时，
      深色的归「深色」，其余归「浅色」 —— 不能因为升级让用户一打开就换了深浅。
    #>
    param([string]$Name)
    if ($Script:Palettes.Contains($Name)) { return $Name }
    if ($Name -in @('检验单', '石墨深色', '午夜蓝', '仪表灰')) { return '深色' }
    return '浅色'
}

function Test-ThemeIsDark {
    param([string]$Name)
    return ((Resolve-ThemeName $Name) -eq '深色')
}

# =====================================================================
#  取色
# =====================================================================
function Get-ThemeHex {
    <#
      一个色槽名或语义色号，在当前皮肤下的实际色号。
      查不到的原样返回（Transparent、#00000000 这种）。
    #>
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return '#00000000' }
    $pal = $Script:Palettes[$(if ($Script:ThemeName) { $Script:ThemeName } else { '浅色' })]
    if ($pal.ContainsKey($Key)) { return $pal[$Key] }
    $up = $Key.ToUpper()
    if ($Script:SemanticColors.ContainsKey($up)) {
        $v = $Script:SemanticColors[$up][$(if ($Script:ThemeIsDark) { 1 } else { 0 })]
        if ($v.StartsWith('@')) { return $pal[$v.Substring(1)] }
        return $v
    }
    return $Key
}

# =====================================================================
#  皮肤设置的存取
# =====================================================================
function Get-ThemeFile { Join-Path $Script:BackupDir 'theme.json' }

function Get-ThemeSetting {
    <# 返回 @{ Name; Image; Opacity; Anim; Frost } —— 读不到就给默认值 #>
    $def = @{ Name = '浅色'; Image = ''; Opacity = 0.88; Anim = $true; Frost = $true }
    try {
        $f = Get-ThemeFile
        if (-not (Test-Path -LiteralPath $f)) { return $def }
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{
            Name    = if ($j.Name) { Resolve-ThemeName "$($j.Name)" } else { $def.Name }
            Image   = if ($j.Image) { "$($j.Image)" } else { '' }
            Opacity = if ($j.Opacity) { [double]$j.Opacity } else { $def.Opacity }
            # ★ 必须用 $null -ne 判断 ★ 用户关掉存的是 false，
            #   写成 if ($j.Anim) 的话 false 会被当成「没设置过」，下次启动又开回来
            Anim    = if ($null -ne $j.Anim) { [bool]$j.Anim } else { $true }
            Frost   = if ($null -ne $j.Frost) { [bool]$j.Frost } else { $true }
        }
    } catch { return $def }
}

function Save-ThemeSetting {
    param([string]$Name, [string]$Image = '', [double]$Opacity = 0.88, [bool]$Anim = $true, [bool]$Frost = $true)
    try {
        $o = [PSCustomObject]@{ Name = $Name; Image = $Image; Opacity = $Opacity; Anim = $Anim; Frost = $Frost }
        $o | ConvertTo-Json | Set-Content -LiteralPath (Get-ThemeFile) -Encoding UTF8
    } catch { Write-Log "保存皮肤设置失败：$($_.Exception.Message)" '警告' }
}

function New-FrozenBrush {
    <#
      ★ 必须显式转成 [Brush] 再塞进资源字典 ★
        直接存 New-Object 的结果，进去的是 PowerShell 包了一层的 PSObject。
        平时读 .Color 看不出毛病，WPF 解析 {DynamicResource} 的那一刻才抛
        「无法把 PSObject 转成 Brush」—— 窗口在 ShowDialog 瞬间崩，用户看到的是「双击没反应」。
    #>
    param([string]$Hex)
    $br = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $br.Freeze()
    return [System.Windows.Media.Brush]$br
}

# =====================================================================
#  应用皮肤
# =====================================================================
function Set-AppTheme {
    <#
      Name    —— '浅色' / '深色'（旧皮肤名会被归过来）
      Image   —— 背景图路径，空字符串 = 纯色
      Opacity —— 有背景图时内容区的不透明度
      Frost   —— 背景图铺模糊副本
    #>
    param(
        [string]$Name = '浅色',
        [string]$Image = '',
        [bool]$Frost = $true,
        [double]$Opacity = 0.88,
        # 自检里切深浅验证用：只换色、不写 theme.json —— 自检不该改用户的设置
        [switch]$NoSave
    )
    $Name = Resolve-ThemeName $Name
    $pal = $Script:Palettes[$Name]
    $Script:ThemeName = $Name
    $Script:ThemeIsDark = ($Name -eq '深色')

    $res = $null
    try { $res = [System.Windows.Application]::Current.Resources } catch { }
    if ($res) {
        # ---- 1. MDIX 自己切深浅 ----
        #   ★ 必须用 set_BaseTheme() ★ 写成 $t.BaseTheme = … 会被 PowerShell
        #     当成往字典里塞一个叫 BaseTheme 的键（它是 ResourceDictionary），什么都没切。
        if ($Script:MdTheme) {
            try {
                $bt = if ($Script:ThemeIsDark) { [MaterialDesignThemes.Wpf.BaseTheme]::Dark } else { [MaterialDesignThemes.Wpf.BaseTheme]::Light }
                $Script:MdTheme.set_BaseTheme($bt)
                $Script:MdTheme.set_PrimaryColor([System.Windows.Media.ColorConverter]::ConvertFromString($pal.Accent))
                $Script:MdTheme.set_SecondaryColor([System.Windows.Media.ColorConverter]::ConvertFromString($pal.Accent))
            } catch { }
        }

        # ---- 2. 我们自己的色槽 ----
        foreach ($k in $pal.Keys) {
            try { $res[$k] = New-FrozenBrush $pal[$k] } catch { }
        }
        # 语义色也放一份进资源（XAML 里偶尔要用），键名用 Sem 前缀
        foreach ($pair in @(@('SemOk', '#556B54'), @('SemOkBg', '#E7EBE4'), @('SemWarn', '#7A6B45'), @('SemWarnBg', '#EDE7D9'),
                @('SemBad', '#8A5750'), @('SemBadBg', '#EDE0DD'), @('SemFlash', '#89694F'), @('SemFlashBg', '#EDE2D6'))) {
            try { $res[$pair[0]] = New-FrozenBrush (Get-ThemeHex $pair[1]) } catch { }
        }
        # 危险按钮上的字：浅色皮肤白字压深玫瑰；深色皮肤的玫瑰红是提亮版，白字压上去只有 2:1，换深字
        try { $res['OnSemBad'] = New-FrozenBrush $(if ($Script:ThemeIsDark) { $pal.Canvas } else { '#FFFFFF' }) } catch { }

        # ---- 3. 把 MDIX 的关键画笔盖成我们的色 ----
        foreach ($slot in $Script:MdBrushMap.Keys) {
            if (-not $pal.ContainsKey($slot)) { continue }
            try {
                $br = New-FrozenBrush $pal[$slot]
                foreach ($mk in $Script:MdBrushMap[$slot]) { $res[$mk] = $br }
            } catch { }
        }
        # 水波纹压淡：主按钮上是白色 18%，其余按钮上是强调色 16%
        try {
            $res['MaterialDesign.Brush.Button.Ripple'] = New-FrozenBrush '#2EFFFFFF'
            $a = $pal.Accent.TrimStart('#')
            $res['MaterialDesign.Brush.Button.FlatRipple'] = New-FrozenBrush ('#29' + $a)
        } catch { }

    }
    if ($Script:Window) {
        # ---- 4. 文字渲染跟着深浅走 ----
        #   ClearType 在深底浅字时子像素会露出来，中文笔画挂一圈红绿紫边
        try {
            $mode = if ($Script:ThemeIsDark) { 'Grayscale' } else { 'ClearType' }
            [System.Windows.Media.TextOptions]::SetTextRenderingMode($Script:Window, $mode)
        } catch { }
    }

    # ---- 5. 背景图 ----
    $Script:ThemeImage = $Image
    $Script:ThemeOpacity = $Opacity
    $Script:ThemeFrost = $Frost
    if ($Script:Window) {
        try {
            if ($Image -and (Test-Path -LiteralPath $Image)) {
                # 开了磨砂就铺模糊副本；算不出来就退回原图 —— 不能因为没磨成就白屏
                $src = $Image
                if ($Frost) {
                    $fp = Get-FrostedPath $Image
                    if ($fp) { $src = $fp }
                }
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.UriSource = New-Object System.Uri $src
                # OnLoad：一次性读进内存再放手，否则文件一直被占着删不掉
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.EndInit()
                $ib = New-Object System.Windows.Media.ImageBrush $bmp
                $ib.Stretch = 'UniformToFill'
                $ib.AlignmentX = 'Center'
                $ib.AlignmentY = 'Center'
                $Script:Window.Background = [System.Windows.Media.Brush]$ib
            } else {
                $Script:Window.Background = New-FrozenBrush $pal.Canvas
            }
        } catch {
            Write-Log "背景图加载失败：$($_.Exception.Message)" '警告'
            $Script:Window.Background = New-FrozenBrush $pal.Canvas
        }
    }

    if (-not $NoSave) { Save-ThemeSetting -Name $Name -Image $Image -Opacity $Opacity -Anim ([bool]$Script:AnimEnabled) -Frost $Frost }
}

function New-FrostedImage {
    <#
      把一张图模糊一份存到 DestPath。导入背景图时算一次，之后一直用这张。

      ★ 先缩到最长边 1600 再模糊 ★ 4K 原图卷一遍要好几秒，模糊之后细节本来就没了。
      ★ 画的时候往外扩一圈再裁回来 ★ 否则四边会把透明吸进来，一圈发白发虚的边。
    #>
    # 半径 56 是试出来的：26 只能把边缘磨柔，56 以上细节干净消失、大块颜色还在
    param([string]$SourcePath, [string]$DestPath, [double]$Radius = 56)
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = 'OnLoad'
        $bmp.UriSource = New-Object System.Uri $SourcePath
        $bmp.EndInit()
        $bmp.Freeze()

        $w = [double]$bmp.PixelWidth
        $h = [double]$bmp.PixelHeight
        if ($w -le 0 -or $h -le 0) { return $null }
        $maxSide = 1600.0
        $scale = [math]::Min(1.0, $maxSide / [math]::Max($w, $h))
        $ow = [int][math]::Max(1, [math]::Round($w * $scale))
        $oh = [int][math]::Max(1, [math]::Round($h * $scale))

        $vis = New-Object System.Windows.Media.DrawingVisual
        $dc = $vis.RenderOpen()
        $pad = $Radius * 1.6
        $rect = New-Object System.Windows.Rect (-$pad), (-$pad), ($ow + 2 * $pad), ($oh + 2 * $pad)
        $dc.DrawImage($bmp, $rect)
        $dc.Close()

        $fx = New-Object System.Windows.Media.Effects.BlurEffect
        $fx.Radius = $Radius
        $fx.KernelType = 'Gaussian'
        $fx.RenderingBias = 'Quality'
        $vis.Effect = $fx

        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $ow, $oh, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($vis)

        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb)) | Out-Null
        $fs = [System.IO.File]::Create($DestPath)
        $enc.Save($fs)
        $fs.Close()
        return $DestPath
    } catch {
        Write-Log "生成磨砂背景失败：$($_.Exception.Message)" '警告'
        return $null
    }
}

function Get-FrostedPath {
    <# 某张背景图对应的磨砂副本该放哪儿。没有就现生成一张。 #>
    param([string]$ImagePath)
    if (-not $ImagePath -or -not (Test-Path -LiteralPath $ImagePath)) { return $null }
    try {
        $dir = Split-Path -Parent $ImagePath
        $dest = Join-Path $dir 'background-frost.png'
        if (Test-Path -LiteralPath $dest) {
            # 原图比磨砂副本新 = 换过图了，重算
            $a = (Get-Item -LiteralPath $ImagePath).LastWriteTimeUtc
            $b = (Get-Item -LiteralPath $dest).LastWriteTimeUtc
            if ($b -ge $a) { return $dest }
        }
        return (New-FrostedImage -SourcePath $ImagePath -DestPath $dest)
    } catch { return $null }
}

function Copy-ThemeImage {
    <#
      把用户选的图片**复制**到 Backup\skin\ 下面再用。
      用户很可能从「下载」或 U 盘里选图，那些地方随时会被清理 / 拔掉。
    #>
    param([string]$SourcePath)
    try {
        $dir = Join-Path $Script:BackupDir 'skin'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ext = [System.IO.Path]::GetExtension($SourcePath)
        if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.png' }
        $dest = Join-Path $dir ('background' + $ext)
        Get-ChildItem -LiteralPath $dir -Filter 'background.*' -ErrorAction SilentlyContinue |
            ForEach-Object { try { [System.IO.File]::Delete($_.FullName) } catch { } }
        $oldFrost = Join-Path $dir 'background-frost.png'
        if (Test-Path -LiteralPath $oldFrost) { try { [System.IO.File]::Delete($oldFrost) } catch { } }
        Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
        # 现在就把磨砂副本算好（一两秒），别等用户勾选时再卡一下
        try { New-FrostedImage -SourcePath $dest -DestPath (Join-Path $dir 'background-frost.png') | Out-Null } catch { }
        return $dest
    } catch {
        Write-Log "复制背景图失败：$($_.Exception.Message)" '警告'
        return $SourcePath
    }
}
