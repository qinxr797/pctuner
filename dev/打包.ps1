# =====================================================================
#  打包给别人用的 zip
#
#  ★ Fonts 必须带上 ★
#    随包字体是整套界面的地基。不带的话对方那边会静默退回系统默认字
#    （微软雅黑），字重、字距、数字宽度全变 —— 而且不报错，
#    只有打开的人觉得「怎么有点糙」，说不出哪儿糙。
#    v5.0 的桌面包就漏了它，23MB 的体积不是省它的理由。
#
#  ★ 不带的东西 ★
#    Backup   —— 本机的原始值备份和日志，带走等于把自己的机器状态发出去
#    dev      —— 自检脚本，用户用不上
#    Launcher —— exe 的源码和构建脚本，exe 本身已经在包里
#    docs     —— README 的截图，GitHub 上看
#    .git     —— 不解释
# =====================================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $env:TEMP ('pctuner-pack-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) '电脑调优助手.zip'

$skipDirs = @('Backup', 'dev', 'Launcher', 'docs', '.git')
$skipFiles = @('design.md', 'PRODUCT.md', 'CLAUDE.md')

$dest = Join-Path $stage 'PCTuner'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

Get-ChildItem -LiteralPath $root -Force | ForEach-Object {
    if ($_.PSIsContainer) {
        if ($skipDirs -contains $_.Name) { return }
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
    } else {
        if ($skipFiles -contains $_.Name) { return }
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

# 把关：字体在不在、exe 在不在。不在就别打这个包。
$must = @('Fonts\MiSans-Regular.ttf', 'Fonts\MiSans-Light.ttf', 'Fonts\MiSans-Semibold.ttf',
    '电脑调优助手.exe', 'PCTuner.ps1',
    'Lib\MaterialDesignThemes.Wpf.dll', 'Lib\MaterialDesignColors.dll', 'Lib\Microsoft.Xaml.Behaviors.dll',
    'Lib\LibreHardwareMonitorLib.dll', 'Lib\HidSharp.dll')
$missing = @($must | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dest $_)) })
if ($missing.Count -gt 0) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('打包中止：少了这些文件' + [Environment]::NewLine + '  ' + ($missing -join ([Environment]::NewLine + '  '))) -ForegroundColor Red
    exit 1
}

if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $out,
    [System.IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

$fi = Get-Item -LiteralPath $out
$ver = (Select-String -LiteralPath (Join-Path $root 'PCTuner.ps1') -Pattern "AppVersion\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
Write-Host ("打好了 v{0}  {1}  {2:N1} MB" -f $ver, $fi.Name, ($fi.Length / 1MB))
