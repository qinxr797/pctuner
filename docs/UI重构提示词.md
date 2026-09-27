# 电脑调优助手 v6.0 界面重构

老板要把电脑调优助手（D:\ClaudeWork\pctuner，PowerShell 5.1 + WPF，当前 v5.1）的界面整体换成「浅色、扁平、干净清爽」的风格，控件库换成 MaterialDesignInXamlToolkit（下面简称 MDIX）。

## 视觉参考

Dribbble「Patient Management Dashboard UI」：https://dribbble.com/shots/15599316
老板喜欢它这几点，逐条照做：
- 浅灰蓝画布，上面放白色卡片；卡片只用 1px 很淡的描边、大圆角（约 12），**不用阴影或只用极淡的阴影**
- 左侧是白色侧边栏：图标加文字的导航，分组小标题用小号大写灰字，当前项用强调色
- 只有一个强调色：靛蓝紫。主按钮、选中态、唯一一张「主角卡」（整张卡填强调色、白字）都用它
- 大读数加小单位（「98 °F」「$9358.20」），标签小而灰，数字大而深
- 留白很足，卡片网格对齐，整页没有杂色

截图估出来的色值如下（只是起点，要按 WCAG AA 调）：
- 画布 `#F4F5FA`
- 卡片 `#FFFFFF`，描边 `#ECEEF4`
- 强调色 `#5B5FD6`，主角卡填色 `#4B53B8`
- 主文字 `#1E2046`，次文字 `#8E91A8`

## 这次改什么，不改什么

**改**：视觉层。包括 PCTuner.ps1 里的 XAML 骨架（约第 1727–2474 行）、各种 New-* 界面构建函数、页面里硬写的色号和字号，还有 Modules\Theme.ps1、Modules\Motion.ps1、design.md、dev\ 下的自检脚本。

**不改**：功能和逻辑。Tweaks / Cleaner / Appx / Engine / Startup / Inspect / SysInfo / Games / Overclock / Maintain / Dash 这些模块里的业务逻辑不动。每个页面的功能、按钮、勾选项、提示文案都要保持和 v5.1 一样，只换长相。功能一条都不许丢。

## 已经拍板的决定（不用再问老板）

1. **默认浅色。** 深色保留成一个备选皮肤，用 MDIX 自带的 BaseTheme 切换，不用再自己维护一套映射表
2. **HandyControl 整个换成 MDIX**，不让两套控件库的隐式样式互相打架。Lib\ 里删掉 HandyControl.dll 和它的许可证，第三方组件说明.txt 同步更新
3. **MDIX 当工具箱用，外观压成扁平。** 卡片 elevation 设 0，改用描边；按钮不要 Material 那种大阴影和全大写；Ripple 水波纹保留，但要淡。目标是「像参考图」，不是「像安卓」
4. 图标统一用 MDIX 的 PackIcon，替换现在的图标写法
5. 字体继续用随包的 MiSans（Fonts\），数字读数用 MiSans Semibold
6. 动效：切页用 MDIX 的 Transitioner / TransitioningContent（淡入加轻微上移，200ms 左右）。现有 Motion.ps1 里的光斑、高光扫过、逐字淡入逐个评估，和扁平风格不搭的删掉，并在报告里列出删了哪些
7. 版本号升到 **v6.0**。design.md 整篇按新风格重写，旧的「量测仪器」深色规范放进 docs\archive\ 存档

## 必须保留的硬约束（出自 design.md、PRODUCT.md 和项目记录）

- `Backup\original-values.json` 的备份和还原逻辑不动
- 语义色不跟着换肤：绿、红、卡其照旧，「高危」永远是红色
- 自带软件卸载的硬黑名单（Modules\Appx.ps1 里的 `$AppxProtected`）不动
- 激进优化默认全不勾、不进任何预设
- 读不到的数据一律显示「—」，绝不编数字
- 超频陪练页一个设置都不改

## 做法：分阶段，每阶段过验收才往下走

**阶段 0：先验证能不能跑（验不过就停下，把情况报给老板）**
- 从 NuGet 下载 MaterialDesignThemes 和 MaterialDesignColors。先确认有 net462 这个目标框架（PowerShell 5.1 跑在 .NET Framework 4.x 上），再把对应的 DLL 放进 Lib\
- 照 HandyControl 现有的加载方式来：Add-Type，先 new 一个 Application，再合并 ResourceDictionary（BundledTheme 加 MaterialDesign3.Defaults 或 MaterialDesign2.Defaults，选哪个在报告里写明理由）
- 用 **powershell.exe（5.1）** 起一个测试窗口，里面放一张 Card、一个 Button、一个 PackIcon 和一个切页动画，截图确认样式确实生效了
- 顺便测一种情况：DLL 带着「从网上下载」的标记（微信传过去的 zip 解压出来就是这样）时还能不能加载。不能加载的话，给 exe 启动壳加上 Unblock

**阶段 1：设计规范**
重写 design.md，写明新的色板、字号阶梯、间距阶梯（4 的倍数）、圆角、描边、动效时长。之后代码里出现的每个值都必须在规范里查得到。

**阶段 2：骨架**
做窗口、侧边栏、顶栏、页面容器和切页动效，外加换肤入口。

**阶段 3：逐页迁移**
一共 10 个页面：概览 / 性能优化 / 垃圾清理 / 日常维护 / 弹窗排查 / 启动项管理 / 自带软件 / 个性化 / 系统体检 / 操作日志，按实际页签为准。每迁完一页都要：真启动、截图、和参考图放在一起看，再对照 v5.1 截图，确认功能没有少。概览页照参考图的卡片网格来排，主角卡留给健康度。

**阶段 4：收尾**
- 更新三个自检脚本，全部跑通：`powershell.exe -File PCTuner.ps1 -SelfTest`、`dev\对比度自检.ps1`、`py dev\漏网色号自检.py`
- 用 dev\打包.ps1 重新打包到桌面，剔除 Backup / dev / Launcher / docs / .git，Fonts 和 Lib 要带上
- 每个阶段一个 git commit

## 验证时的坑（以前踩过）

- 含中文的 .ps1 必须是 UTF-8 with BOM，而且只在 powershell.exe 5.1 下才会出问题，PS7 验不出来
- 往 WPF 资源字典里放画笔，要显式转成 `[Brush]`，不然 ShowDialog 的时候直接崩
- PrintWindow 截不到 RenderTransform，缩放和位移类的动效只能在程序里读属性来验证
- TabControl 只给当前页建可视树，挂事件要用 RegisterClassHandler
- 自检通过不等于能用：每一页都必须真启动、真切页签、截图看过才算完成

## 汇报

每个阶段做完用几句话报一次：做了什么、截图在哪、删了或改了哪些原有效果、有没有自作主张的地方（有就放在第一句说）。最后给出新旧界面各页的对比截图。
