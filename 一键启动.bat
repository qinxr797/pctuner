@echo off
title 电脑调优助手
cd /d "%~dp0"
echo.
echo   ============================================
echo      电脑调优助手  正在启动...
echo   ============================================
echo.
echo   接下来会弹出「用户账户控制」授权窗口，
echo   请点「是」—— 修改系统设置需要管理员权限。
echo.
rem 先解除「网络来源」锁定：微信/QQ 传来的压缩包解压出来的文件都带这个
rem 标记，PowerShell 读它会报「对路径的访问被拒绝」。这一步必须在
rem 主程序之前跑，因为主程序自己也可能被锁住。
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File" >nul 2>&1

powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0PCTuner.ps1"
if errorlevel 1 (
  echo.
  echo   启动失败，请把上面的错误信息截图保留。
  pause
)
exit