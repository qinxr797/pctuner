# -*- coding: utf-8 -*-
"""找出代码里用了、但换肤映射表里没有的颜色色号。

   界面代码里写的都是「默认皮肤的色号」，Get-Brush 会按当前皮肤的映射表
   把它换成对应的颜色。但只要有一个色号漏进映射表，它在深色皮肤下就会
   **保持浅色皮肤的原值** —— 轻则「字发灰」，重则「浅字压浅底整行看不见」。

   这类 bug 眼睛很难发现：出问题的那一行往往在某个很少点开的页面里。

   ★ 2026-09-27 这个脚本抓出过 6 个色号、10 处用法 ★
     其中「⚡ 会弹黑框」那个徽章最典型：前景配了深色版、背景没配，
     深色皮肤下变成「浅底 + 提亮过的前景」，整个徽章糊成一团。

   跑法（在项目根目录）：
       py dev\漏网色号自检.py
"""
import io, re, glob, os

theme = io.open(r'D:\ClaudeWork\pctuner\Modules\Theme.ps1', encoding='utf-8-sig').read()

# 1) 可换肤的基准色号 = 默认皮肤「暖灰（默认）」那 20 支画笔 + ExtraColorSlots 的键
m = re.search(r"'暖灰（默认）'\s*=\s*@\{(.*?)\n        \}\n", theme, re.S)
base = set(h.upper() for h in re.findall(r"#[0-9A-Fa-f]{6}", m.group(1))) if m else set()
extra = set(h.upper() for h in re.findall(r"'(#[0-9A-Fa-f]{6})'\s*=\s*'", theme[theme.index('$Script:ExtraColorSlots'):theme.index('$Script:HcBrushMap')]))
# 2) 语义色（故意不换肤的）：SemanticDark 的键，和它们的深色对应值
sem = set(h.upper() for h in re.findall(r"#[0-9A-Fa-f]{6}", theme[theme.index('$Script:SemanticDark'):theme.index('$Script:ExtraColorSlots')]))

known = base | extra | sem
print('可换肤色号 %d 个，语义色 %d 个' % (len(base | extra), len(sem)))

used = {}
for f in [r'D:\ClaudeWork\pctuner\PCTuner.ps1'] + glob.glob(r'D:\ClaudeWork\pctuner\Modules\*.ps1'):
    if f.endswith('Theme.ps1'):
        continue
    for i, line in enumerate(io.open(f, encoding='utf-8-sig').read().split('\n'), 1):
        if line.lstrip().startswith('#'):
            continue
        for h in re.findall(r"'(#[0-9A-Fa-f]{6})'", line):
            used.setdefault(h.upper(), []).append('%s:%d' % (os.path.basename(f), i))

orphan = {h: v for h, v in used.items() if h not in known}
if not orphan:
    print('没有孤儿色号')
else:
    print('\n以下色号既不在换肤表里、也不是语义色 —— 深色皮肤下会保持浅色原值：')
    for h in sorted(orphan, key=lambda x: -len(orphan[x])):
        print('  %s  用了 %2d 处   %s' % (h, len(orphan[h]), ', '.join(orphan[h][:4])))
