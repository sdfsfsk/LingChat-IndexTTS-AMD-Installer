@echo off
setlocal
chcp 65001 >nul
title LingChat IndexTTS 官方模型下载

set "VERSION_ARG="
if not "%~2"=="" set "VERSION_ARG=-ModelVersion %~2"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Download-Models.ps1" -LingChatPath "%~1" %VERSION_ARG%
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo [失败] 模型下载没有完成，重新运行可从 .part 文件继续。
) else (
  echo [完成] IndexTTS 官方模型已经下载并校验。
)
pause
exit /b %EXIT_CODE%
