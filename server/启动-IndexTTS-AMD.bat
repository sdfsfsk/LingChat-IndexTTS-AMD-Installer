@echo off
chcp 65001 >nul
cd /d %~dp0

rem ===== base env =====
set PYTHONUTF8=1
set HF_HOME=%~dp0.hf-cache
set MODELSCOPE_CACHE=%~dp0.ms-cache
if not defined INDEXTTS_PORT set "INDEXTTS_PORT=9880"
title IndexTTS2 AMD ROCm Server (port %INDEXTTS_PORT%)

rem ===== stop only an old IndexTTS instance found through the configured port =====
rem The cleanup script verifies the listener command line before stopping it.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup-indextts-port.ps1" ^
    -Port "%INDEXTTS_PORT%" ^
    -ExpectedServerScript "%~dp0server_indextts.py" ^
    -LauncherScript "%~f0"
if errorlevel 1 (
    echo [startup] Port cleanup failed. IndexTTS was not started.
    pause
    exit /b 1
)

rem ===== ROCm / MIOpen tuning =====
set MIOPEN_FIND_MODE=2
set MIOPEN_USER_DB_PATH=%~dp0miopen\db_infer
set MIOPEN_CUSTOM_CACHE_DIR=%~dp0miopen\cache_infer
set MIOPEN_ENABLE_LOGGING=0
set MIOPEN_ENABLE_LOGGING_CMD=0
set MIOPEN_LOG_LEVEL=1

rem ===== model version: 2.5 (default) / 2 (legacy fallback) =====
if not defined INDEXTTS_VERSION set "INDEXTTS_VERSION=2.5"

rem ===== emotion mode: blend / qwen / auto =====
if not defined INDEXTTS_EMO_MODE set "INDEXTTS_EMO_MODE=qwen"

rem ===== fast inference on RDNA4 (set 0 to revert to fp32) =====
set INDEXTTS_FP16=1
set INDEXTTS_VOCODER_FP16=1

rem ===== speed profile (quality fallback: beams=3, diffusion=25) =====
set INDEXTTS_NUM_BEAMS=1
set INDEXTTS_DIFFUSION_STEPS=16

if not exist "%~dp0miopen\db_infer" mkdir "%~dp0miopen\db_infer"
if not exist "%~dp0miopen\cache_infer" mkdir "%~dp0miopen\cache_infer"

rem ===== server writes its own UTF-8 server.log (console shows everything too) =====
"%~dp0runtime\python.exe" "%~dp0server_indextts.py"
set "INDEXTTS_EXIT_CODE=%ERRORLEVEL%"
if not "%INDEXTTS_EXIT_CODE%"=="0" (
    echo [startup] IndexTTS exited abnormally, code=%INDEXTTS_EXIT_CODE%.
    pause
)
exit /b %INDEXTTS_EXIT_CODE%
