@echo off
chcp 65001 >nul
cd /d %~dp0
if not defined INDEXTTS_PORT set "INDEXTTS_PORT=9880"
echo Stopping IndexTTS2 server (port %INDEXTTS_PORT%)...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup-indextts-port.ps1" ^
    -Port "%INDEXTTS_PORT%" ^
    -ExpectedServerScript "%~dp0server_indextts.py" ^
    -LauncherScript "%~dp0启动-IndexTTS-AMD.bat"
if errorlevel 1 (
    echo Stop failed. The port may belong to another program.
    pause
    exit /b 1
)
echo done.
timeout /t 2 >nul
