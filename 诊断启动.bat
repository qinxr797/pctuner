@echo off
chcp 936 >nul
title PCTuner 诊断启动
cd /d "%~dp0"
echo.
echo   这个版本不会隐藏窗口，出错信息会留在屏幕上。
echo   如果需要管理员权限，请右键这个文件 -^> 以管理员身份运行。
echo.
echo   ---- 环境检查 ----
where powershell
echo.
echo   ---- 开始运行 ----
powershell -NoProfile -STA -ExecutionPolicy Bypass -NoExit -File "%~dp0PCTuner.ps1"
echo.
echo   ---- 已退出，错误码 %errorlevel% ----
pause