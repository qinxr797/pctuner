# -*- coding: utf-8 -*-
"""找出代码里漏网的色号字面量。

   v6.0 起界面代码里一律写**色槽名**（'TextMain'、'Card'、'Stroke'……，见 design.md 1.1），
   只有语义色（绿 / 卡其 / 玫瑰红 / 陶，见 design.md 1.3）允许以色号出现 ——
   Get-Brush 认得它们，深色皮肤下自动换成提亮版。

   其余任何色号出现在代码里，都是漏网：它不跟皮肤走，
   深色皮肤下保持浅色原值，轻则「字发灰」，重则「浅字压浅底整行看不见」。

   ★ 2026-09-27 这个脚本抓出过 6 个色号、10 处用法 ★

   例外：
     · Modules\Theme.ps1 —— 色值本来就定义在那儿
     · XAML 里 SolidColorBrush 和 CustomColorTheme 的默认值 —— 那是启动前的占位，Set-AppTheme 会整体覆盖
     · 注释行

   跑法（在项目根目录）：
       py dev\\漏网色号自检.py
"""
import io, re, glob, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
theme = io.open(os.path.join(root, 'Modules', 'Theme.ps1'), encoding='utf-8-sig').read()

sem_block = theme[theme.index('$Script:SemanticColors'):theme.index('$Script:MdBrushMap')]
semantic = set(h.upper() for h in re.findall(r"'(#[0-9A-Fa-f]{6})'\s*=", sem_block))
# 纯白：危险按钮上的字、按钮水波纹 —— 两套皮肤都是白，不属于中性色
allowed = semantic | {'#FFFFFF'}
print('允许作为字面量的色号 %d 个（语义色 + 纯白）' % len(allowed))

orphan = {}
for f in [os.path.join(root, 'PCTuner.ps1')] + glob.glob(os.path.join(root, 'Modules', '*.ps1')):
    if f.endswith('Theme.ps1'):
        continue
    in_xaml = False
    for i, line in enumerate(io.open(f, encoding='utf-8-sig').read().split('\n'), 1):
        st = line.strip()
        if st.startswith('#') or st.startswith('<!--'):
            continue
        # XAML 块里 SolidColorBrush 的占位默认值不算
        if re.search(r"<SolidColorBrush x:Key=|<md:CustomColorTheme ", line):
            continue
        for h in re.findall(r"['\"](#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)['\"]", line):
            H = h.upper()
            if H in allowed:
                continue
            orphan.setdefault(H, []).append('%s:%d' % (os.path.basename(f), i))

if not orphan:
    print('没有漏网色号')
    sys.exit(0)
print('\n以下色号既不是色槽名、也不是语义色 —— 不跟皮肤走：')
for h in sorted(orphan, key=lambda x: -len(orphan[x])):
    print('  %s  用了 %2d 处   %s' % (h, len(orphan[h]), ', '.join(orphan[h][:4])))
sys.exit(1)
