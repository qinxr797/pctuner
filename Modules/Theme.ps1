<#
=====================================================================
  Theme.ps1  ——  换肤
---------------------------------------------------------------------
  一套皮肤 = 20 个「中性色 + 主色」的取值。

  ★ 哪些颜色参与换肤，哪些不参与 ★
    参与：窗口底色、卡片底色、边框、文字、滚动条、主色
    不参与：绿 / 红 / 卡其 / 玫瑰那几个**语义色**
            —— 「高危」永远是红的，不能因为换了皮肤变成绿的。
            这是故意的限制，别为了好看去掉。

  换肤怎么生效的：
    1. XAML 里所有中性色都写成 {DynamicResource XXX}
       → 改 Window.Resources['XXX'] 就整个界面跟着变
    2. 代码里的 Get-Brush '#色号' 走 $Script:ColorRemap 映射表
       → 换肤时重建映射表，然后重绘各页
    3. 图片皮肤额外给窗口铺一层 ImageBrush，
       并把各个面板调成半透明让图透出来

  皮肤选择存在 Backup\theme.json，下次启动自动套用。
=====================================================================
#>

# 默认皮肤的色号 —— 也就是代码里 Get-Brush 写死的那些值。
# 换肤时用它当「键」，去新皮肤里查对应的新色号。
$Script:ThemeBaseKeys = @(
    'WindowBg', 'PanelBg', 'CardBg', 'CardHover', 'SurfaceAlt', 'SurfaceSunken', 'NeutralTint',
    'TextMain', 'TextDim', 'TextMid', 'OnAccent',
    'BorderSoft', 'BorderMed', 'BorderStrong',
    'ScrollThumbBg', 'ScrollThumbHover', 'ScrollThumbDrag',
    'Accent', 'AccentDark', 'AccentLight', 'AccentTint'
)

# =====================================================================
#  语义色在深色皮肤下的替身
# ---------------------------------------------------------------------
#  之前的原则是「语义色一律不换肤」—— 方向对，但做得太死，
#  结果深色皮肤下出了一批看不见的字：
#    · 浅色的状态卡片底 + 跟着变白的标题 = 白字浅底，整行消失
#    · 深卡其色的提示文字压在深色面板上 = 深字深底，也看不见
#
#  正确的做法是分清两件事：
#    **色相**（红=危险、绿=安全、卡其=注意）必须保持，不能换
#    **明度**（这个颜色多深多浅）必须跟着皮肤走
#
#  所以这里按「前景 / 背景成对」替换：深色皮肤下前景提亮、背景压暗，
#  两边一起动，徽章（自带前景+背景）和裸文字就都还是可读的。
#
#  ★ 成对是关键 ★ 只换前景不换背景，或者反过来，都会炸。
# =====================================================================
$Script:SemanticDark = @{
    # ---- 灰绿：良好 / 必做 / 低风险 ----
    '#556B54' = '#9CC49D'      # 前景：提亮成浅鼠尾草
    '#E7EBE4' = '#2E3A2F'      # 背景：压成深绿灰
    '#E2E7E0' = '#2E3A2F'
    '#DCE8DA' = '#2E3A2F'
    # ---- 灰卡其：需实测 / 中风险 / 可疑 ----
    '#7A6B45' = '#DCC68C'
    '#EDE7D9' = '#3B3529'
    '#F0EADC' = '#3B3529'
    # ---- 灰玫瑰：高危 / 高风险 ----
    '#8A5750' = '#E4A69E'
    '#EDE0DD' = '#3E2D2A'
    '#EFE3E0' = '#3E2D2A'
    # ---- 灰陶：会弹黑框 ----
    '#89694F' = '#D6AB85'
}

# 代码里 Get-Brush 用到的、但不在上面 20 个里的中性色，
# 也要跟着皮肤走，否则换深色皮肤时卡片还是浅色的。
# 左边是「默认皮肤里的色号」，右边是「它属于哪个语义槽」。
$Script:ExtraColorSlots = @{
    '#F6F5F2' = 'CardBg'
    '#FBFAF8' = 'PanelBg'
    '#6E6B63' = 'TextDim'
    '#E0DED8' = 'BorderSoft'
    '#EAE9E3' = 'SurfaceAlt'
    '#E8E7E2' = 'NeutralTint'
    '#DDDBD5' = 'BorderSoft'
    '#2B2A26' = 'TextMain'
    '#4A4842' = 'TextMid'
    '#565349' = 'TextMid'
    '#8A877F' = 'TextDim'
    '#E4E3DE' = 'WindowBg'
    '#55606F' = 'Accent'
    '#F0EFEB' = 'CardHover'   # 卡片悬停色（$Script:CARD_HOVER）——
    # 漏了这一条的后果：深色皮肤下鼠标一放上去，
    # 悬停底色还是浅的、标题字却是白的 → 整行看不见
}

function Get-BuiltinThemes {
    <#
      内置皮肤。每套都是自己配的低饱和度组合，
      正文色都验过对比度（正文 ≥ 4.5:1，符合 WCAG AA）。
    #>
    [ordered]@{

        '暖灰（默认）' = @{
            Desc = '原来那一套。暖调中性灰，久看不累。'
            Swatch = @('#E4E3DE', '#FBFAF8', '#55606F')
            Colors = @{
                WindowBg = '#E4E3DE'; PanelBg = '#FBFAF8'; CardBg = '#F6F5F2'; CardHover = '#EFEEEA'
                SurfaceAlt = '#EDECE8'; SurfaceSunken = '#E5E3DC'; NeutralTint = '#E8E7E2'
                TextMain = '#2B2A26'; TextDim = '#6E6B63'; TextMid = '#4A4842'; OnAccent = '#FFFFFF'
                BorderSoft = '#DDDBD5'; BorderMed = '#D2D0C9'; BorderStrong = '#C6C4BC'
                ScrollThumbBg = '#CBC9C1'; ScrollThumbHover = '#B5B2A9'; ScrollThumbDrag = '#9E9B91'
                Accent = '#55606F'; AccentDark = '#39424E'; AccentLight = '#7F8A99'; AccentTint = '#E4E7EC'
            }
        }

        '雾霾蓝' = @{
            Desc = '冷调灰蓝。偏安静，适合长时间盯着看。'
            Swatch = @('#DFE3E6', '#F8FAFB', '#4F6577')
            Colors = @{
                WindowBg = '#DFE3E6'; PanelBg = '#F8FAFB'; CardBg = '#F1F4F6'; CardHover = '#E9EDF0'
                SurfaceAlt = '#E8ECEF'; SurfaceSunken = '#DFE4E8'; NeutralTint = '#E5E9EC'
                TextMain = '#23292E'; TextDim = '#65707A'; TextMid = '#414B54'; OnAccent = '#FFFFFF'
                BorderSoft = '#D3D9DE'; BorderMed = '#C5CCD2'; BorderStrong = '#B3BBC2'
                ScrollThumbBg = '#C2C9CF'; ScrollThumbHover = '#ACB4BB'; ScrollThumbDrag = '#949DA5'
                Accent = '#4F6577'; AccentDark = '#354654'; AccentLight = '#7A8D9C'; AccentTint = '#DFE7ED'
            }
        }

        '鼠尾草绿' = @{
            Desc = '低饱和的灰绿。柔和，不刺眼。'
            Swatch = @('#E1E5DF', '#F9FBF8', '#566B58')
            Colors = @{
                WindowBg = '#E1E5DF'; PanelBg = '#F9FBF8'; CardBg = '#F2F5F0'; CardHover = '#EAEEE8'
                SurfaceAlt = '#E9EDE7'; SurfaceSunken = '#E0E5DE'; NeutralTint = '#E6EAE4'
                TextMain = '#242822'; TextDim = '#667064'; TextMid = '#414A3F'; OnAccent = '#FFFFFF'
                BorderSoft = '#D5DAD3'; BorderMed = '#C7CDC5'; BorderStrong = '#B5BCB3'
                ScrollThumbBg = '#C4CAC2'; ScrollThumbHover = '#AEB5AC'; ScrollThumbDrag = '#969E94'
                Accent = '#566B58'; AccentDark = '#3A4A3C'; AccentLight = '#7F927F'; AccentTint = '#E2EAE1'
            }
        }

        '奶茶棕' = @{
            Desc = '暖棕米色。偏温暖，像纸。'
            Swatch = @('#E8E2DA', '#FCFAF7', '#6B5844')
            Colors = @{
                WindowBg = '#E8E2DA'; PanelBg = '#FCFAF7'; CardBg = '#F7F3EE'; CardHover = '#F0ECE6'
                SurfaceAlt = '#F0EBE4'; SurfaceSunken = '#E7E1D9'; NeutralTint = '#EDE8E1'
                TextMain = '#2B2620'; TextDim = '#726860'; TextMid = '#4C443B'; OnAccent = '#FFFFFF'
                BorderSoft = '#DED7CD'; BorderMed = '#D0C8BC'; BorderStrong = '#BEB5A8'
                ScrollThumbBg = '#CEC6BA'; ScrollThumbHover = '#B8AFA2'; ScrollThumbDrag = '#A0978A'
                Accent = '#6B5844'; AccentDark = '#4B3D2E'; AccentLight = '#94816C'; AccentTint = '#EDE5DA'
            }
        }

        '石墨深色' = @{
            Desc = '深色模式。晚上用眼睛舒服很多。'
            Swatch = @('#22242A', '#2C2F36', '#8FA3BA')
            Colors = @{
                WindowBg = '#22242A'; PanelBg = '#2C2F36'; CardBg = '#31353D'; CardHover = '#3A3F48'
                SurfaceAlt = '#383C45'; SurfaceSunken = '#1C1E23'; NeutralTint = '#3A3E47'
                TextMain = '#E8EAED'; TextDim = '#A2A8B2'; TextMid = '#C6CAD1'; OnAccent = '#1B1D21'
                BorderSoft = '#3D414A'; BorderMed = '#4A4F59'; BorderStrong = '#5A606B'
                ScrollThumbBg = '#4A4F59'; ScrollThumbHover = '#5D636E'; ScrollThumbDrag = '#727986'
                Accent = '#8FA3BA'; AccentDark = '#6E8299'; AccentLight = '#AABBCE'; AccentTint = '#343B45'
            }
        }

        '午夜蓝' = @{
            Desc = '偏蓝的深色。比石墨更有颜色一点。'
            Swatch = @('#1B2230', '#242D3D', '#8AA6C8')
            Colors = @{
                WindowBg = '#1B2230'; PanelBg = '#242D3D'; CardBg = '#2A3447'; CardHover = '#333E52'
                SurfaceAlt = '#313C51'; SurfaceSunken = '#161C27'; NeutralTint = '#323D52'
                TextMain = '#E6EBF2'; TextDim = '#9FACBF'; TextMid = '#C3CCD9'; OnAccent = '#141A24'
                BorderSoft = '#354054'; BorderMed = '#414E65'; BorderStrong = '#526178'
                ScrollThumbBg = '#414E65'; ScrollThumbHover = '#546279'; ScrollThumbDrag = '#6B798F'
                Accent = '#8AA6C8'; AccentDark = '#6684A8'; AccentLight = '#A6BCD6'; AccentTint = '#2C3849'
            }
        }
    }
}

# =====================================================================
#  皮肤设置的存取
# =====================================================================
function Get-ThemeFile { Join-Path $Script:BackupDir 'theme.json' }

function Get-ThemeSetting {
    <# 返回 @{ Name; Image; Opacity } —— 读不到就给默认值 #>
    $def = @{ Name = '暖灰（默认）'; Image = ''; Opacity = 0.88 }
    try {
        $f = Get-ThemeFile
        if (-not (Test-Path -LiteralPath $f)) { return $def }
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{
            Name    = if ($j.Name) { "$($j.Name)" } else { $def.Name }
            Image   = if ($j.Image) { "$($j.Image)" } else { '' }
            Opacity = if ($j.Opacity) { [double]$j.Opacity } else { $def.Opacity }
        }
    } catch { return $def }
}

function Save-ThemeSetting {
    param([string]$Name, [string]$Image = '', [double]$Opacity = 0.88)
    try {
        $o = [PSCustomObject]@{ Name = $Name; Image = $Image; Opacity = $Opacity }
        $o | ConvertTo-Json | Set-Content -LiteralPath (Get-ThemeFile) -Encoding UTF8
    } catch { Write-Log "保存皮肤设置失败：$($_.Exception.Message)" '警告' }
}

# =====================================================================
#  应用皮肤
# =====================================================================
function Set-AppTheme {
    <#
      把一套皮肤套到窗口上。
      Name    —— 内置皮肤名
      Image   —— 背景图路径，空字符串表示纯色
      Opacity —— 有背景图时，各面板的不透明度（越小越透，图越明显）
    #>
    param(
        [string]$Name = '暖灰（默认）',
        [string]$Image = '',
        [double]$Opacity = 0.88
    )

    $themes = Get-BuiltinThemes
    if (-not $themes.Contains($Name)) { $Name = '暖灰（默认）' }
    $colors = $themes[$Name].Colors

    # ---- 1. 换掉 Window.Resources 里那 20 支画笔 ----
    #
    # ★★ 这里有个坑，踩过一次，代价是整个程序打不开 ★★
    #   直接写 $Script:Window.Resources[$k] = New-Object ...SolidColorBrush(...)
    #   存进去的是一个被 PowerShell 包了一层的 PSObject，不是真正的 Brush。
    #   平时看不出来（读 .Color 照样能读到值），
    #   但 WPF 真正渲染、解析 {DynamicResource} 的那一刻会抛：
    #       Unable to cast object of type 'System.Management.Automation.PSObject'
    #       to type 'System.Windows.Media.Brush'
    #   结果就是窗口在 ShowDialog 的瞬间崩掉 —— 用户看到的是「双击没反应」。
    #
    #   显式转成 [Brush] 会强制 PowerShell 把壳扒掉，存进去真东西。
    #   Freeze() 是顺手做的：画笔不再改动，跨线程访问和渲染都更快。
    foreach ($k in $Script:ThemeBaseKeys) {
        if (-not $colors.ContainsKey($k)) { continue }
        try {
            $br = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString($colors[$k]))
            $br.Freeze()
            $Script:Window.Resources[$k] = [System.Windows.Media.Brush]$br
        } catch { }
    }

    # ---- 2. 重建 Get-Brush 的映射表 ----
    # 默认皮肤的色号 -> 当前皮肤同一个语义槽的色号
    $defaults = $themes['暖灰（默认）'].Colors
    $remap = @{}
    foreach ($k in $Script:ThemeBaseKeys) {
        if (-not $defaults.ContainsKey($k) -or -not $colors.ContainsKey($k)) { continue }
        $remap[$defaults[$k].ToUpper()] = $colors[$k]
    }
    # 代码里那些「不在 20 支画笔里」的中性色，按语义槽跟着换
    foreach ($hex in $Script:ExtraColorSlots.Keys) {
        $slot = $Script:ExtraColorSlots[$hex]
        if ($colors.ContainsKey($slot)) { $remap[$hex.ToUpper()] = $colors[$slot] }
    }

    # 深色皮肤：语义色换成提亮版前景 + 压暗版背景（成对换，见文件开头说明）
    # 浅色皮肤不动，语义色保持原样。
    if (Test-ThemeIsDark $Name) {
        foreach ($hex in $Script:SemanticDark.Keys) {
            $remap[$hex.ToUpper()] = $Script:SemanticDark[$hex]
        }
    }
    $Script:ColorRemap = $remap

    # ---- 3. 背景图 ----
    $Script:ThemeImage = $Image
    $Script:ThemeOpacity = $Opacity
    try {
        if ($Image -and (Test-Path -LiteralPath $Image)) {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = New-Object System.Uri $Image
            # CacheOption=OnLoad：一次性读进内存再放手，
            # 否则文件会被一直占着，用户想删想换那张图都删不掉
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $ib = New-Object System.Windows.Media.ImageBrush $bmp
            $ib.Stretch = 'UniformToFill'
            $ib.AlignmentX = 'Center'
            $ib.AlignmentY = 'Center'
            $Script:Window.Background = [System.Windows.Media.Brush]$ib
        } else {
            # 同上：从字典里读回来的也要显式转一次，不能直接赋给 Background
            $Script:Window.Background = [System.Windows.Media.Brush]$Script:Window.Resources['WindowBg']
        }
    } catch {
        Write-Log "背景图加载失败：$($_.Exception.Message)" '警告'
        $Script:Window.Background = [System.Windows.Media.Brush]$Script:Window.Resources['WindowBg']
    }

    Save-ThemeSetting -Name $Name -Image $Image -Opacity $Opacity
}

function Test-ThemeIsDark {
    <# 当前皮肤是不是深色的 —— 用窗口底色的亮度判断 #>
    param([string]$Name)
    $themes = Get-BuiltinThemes
    if (-not $themes.Contains($Name)) { return $false }
    $hex = $themes[$Name].Colors.WindowBg
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    # 感知亮度（Rec.709），低于 128 算深色
    $lum = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
    return ($lum -lt 128)
}

function Copy-ThemeImage {
    <#
      把用户选的图片**复制**到 Backup\skin\ 下面再用。

      ★ 为什么要复制而不是直接引用原路径 ★
        用户很可能从「下载」文件夹或者 U 盘里选图，
        那些地方的文件随时会被清理/拔掉，
        下次启动就变成白板还报错。复制一份进来最省事。
    #>
    param([string]$SourcePath)
    try {
        $dir = Join-Path $Script:BackupDir 'skin'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ext = [System.IO.Path]::GetExtension($SourcePath)
        if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.png' }
        $dest = Join-Path $dir ('background' + $ext)
        # 先把旧的皮肤图清掉，免得攒一堆
        Get-ChildItem -LiteralPath $dir -Filter 'background.*' -ErrorAction SilentlyContinue |
            ForEach-Object { try { [System.IO.File]::Delete($_.FullName) } catch { } }
        Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
        return $dest
    } catch {
        Write-Log "复制背景图失败：$($_.Exception.Message)" '警告'
        return $SourcePath
    }
}
