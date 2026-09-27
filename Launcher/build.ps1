#Requires -Version 5.1
<#
    把 Launcher.cs 编译成根目录的「电脑调优助手.exe」。

    用的是 Windows 自带的 C# 编译器（.NET Framework 4 随系统装好的），
    不需要装 Visual Studio、不需要装 SDK、不需要联网。

    改了 Launcher.cs 或 app.manifest 之后跑一下这个脚本就行。
#>
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$out = Join-Path $root '电脑调优助手.exe'
$icon = Join-Path $here 'app.ico'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) {
    throw "找不到 csc.exe（应该随 .NET Framework 4 装在 $env:WINDIR\Microsoft.NET 下）"
}

if (-not (Test-Path $icon)) {
    Write-Host '图标不存在，先生成……'
    & (Join-Path $here 'make-icon.ps1')
}

# /target:winexe = 不带控制台窗口；/win32manifest 把 UAC 清单嵌进去
$args = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    "/out:$out"
    "/win32icon:$icon"
    "/win32manifest:$(Join-Path $here 'app.manifest')"
    '/reference:System.dll'
    '/reference:System.Windows.Forms.dll'
    '/reference:System.Drawing.dll'
    (Join-Path $here 'Launcher.cs')
)

& $csc @args
if ($LASTEXITCODE -ne 0) { throw "编译失败（csc 退出码 $LASTEXITCODE）" }

$kb = [int]((Get-Item $out).Length / 1KB)
Write-Host "编译完成：$out（$kb KB）"
