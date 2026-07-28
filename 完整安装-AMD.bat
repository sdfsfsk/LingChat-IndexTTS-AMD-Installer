@echo off
setlocal
chcp 65001 >nul
title LingChat IndexTTS-AMD 完整安装

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-All.ps1" -LingChatPath "%~1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo [失败] 安装没有完成，请保留窗口中的错误信息。
) else (
  echo [完成] IndexTTS-AMD 运行时和官方模型已经就绪。
)
pause
exit /b %EXIT_CODE%
