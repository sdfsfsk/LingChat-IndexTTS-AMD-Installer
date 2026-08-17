[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$LingChatPath = '',
    [string]$AmdWheelIndex = 'https://repo.amd.com/rocm/whl/gfx120X-all',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$binDir = Resolve-LingChatBin -LingChatPath $LingChatPath
$dataDir = Resolve-IndexTtsDataDir -BinDir $binDir
$runtimeDir = Join-Path $dataDir 'runtime'
$pythonExe = Join-Path $runtimeDir 'python.exe'
$requirements = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\requirements-runtime.txt')).Path
$patchScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Apply-AmdCompatPatches.py')).Path

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
Assert-FreeSpace -Path $dataDir -RequiredBytes 10GB

Write-Host "LingChat bin：$binDir" -ForegroundColor Green
Write-Host "服务器目录：$dataDir" -ForegroundColor Green
Write-Host "AMD wheel：$AmdWheelIndex" -ForegroundColor Green

$installPython = $Force -or -not (Test-Path -LiteralPath $pythonExe)
if ($installPython) {
    $pythonZipUrl = 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip'
    $pythonZipSha256 = '608619f8619075629c9c69f361352a0da6ed7e62f83a0e19c63e0ea32eb7629d'
    $cacheDir = Join-Path $env:TEMP 'LingChat-IndexTTS-Installer'
    $pythonZip = Join-Path $cacheDir 'python-3.10.11-embed-amd64.zip'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    Write-Host '下载 Python 3.10.11 嵌入式包……' -ForegroundColor Cyan
    Invoke-ResumableDownload -Uri $pythonZipUrl -Destination $pythonZip -ExpectedSize 8629277

    $actualHash = (Get-FileHash -LiteralPath $pythonZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $pythonZipSha256) {
        throw "Python 嵌入式包 SHA-256 校验失败：预期 $pythonZipSha256，实际 $actualHash。"
    }

    if (Test-Path -LiteralPath $runtimeDir) {
        Remove-Item -LiteralPath $runtimeDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    Expand-Archive -LiteralPath $pythonZip -DestinationPath $runtimeDir -Force

    # 嵌入式发行版默认不启用 site 也不含 Lib\site-packages，需要改写 ._pth
    $pthPath = Join-Path $runtimeDir 'python310._pth'
    @(
        'python310.zip',
        '.',
        'Lib\site-packages',
        'import site'
    ) | Set-Content -LiteralPath $pthPath -Encoding ASCII

    Write-Host '引导 pip……' -ForegroundColor Cyan
    $getPip = Join-Path $cacheDir 'get-pip.py'
    Invoke-ResumableDownload -Uri 'https://bootstrap.pypa.io/get-pip.py' -Destination $getPip
    Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @($getPip) -Description '安装 pip'
}

if (-not (Test-Path -LiteralPath $pythonExe)) {
    throw "Python 运行时不完整：$runtimeDir"
}

$pythonVersion = (& $pythonExe -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor)+'.'+str(sys.version_info.micro))").Trim()
if (-not $pythonVersion.StartsWith('3.10.')) {
    throw "服务器要求 Python 3.10，当前运行时是 $pythonVersion。"
}

$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @(
    '-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel'
) -Description '更新 pip 基础工具'

Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @(
    '-m', 'pip', 'install',
    '--index-url', $AmdWheelIndex,
    '--extra-index-url', 'https://pypi.org/simple',
    'torch==2.11.0+rocm7.13.0',
    'torchvision==0.26.0+rocm7.13.0',
    'torchaudio==2.11.0+rocm7.13.0'
) -Description '安装 AMD ROCm PyTorch'

Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @(
    '-m', 'pip', 'install', '--requirement', $requirements
) -Description '安装 IndexTTS Python 依赖'

# openai-whisper 的传递依赖含 triton（Windows 无可用 wheel），只装本体；
# 运行所需的 tiktoken / more-itertools / tqdm 已在 requirements-runtime.txt 中。
Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @(
    '-m', 'pip', 'install', '--no-deps', 'openai-whisper==20250625'
) -Description '安装 openai-whisper（--no-deps）'

Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @($patchScript) -Description '应用 AMD site-packages 兼容补丁'

$probe = & $pythonExe -c @'
import json
import torch
import torchaudio
import librosa
import transformers
import fastapi
import uvicorn
import tiktoken
import fugashi
import whisper
import soundfile
print(json.dumps({
    'python': __import__('sys').version.split()[0],
    'torch': torch.__version__,
    'hip': getattr(torch.version, 'hip', None),
    'gpu_available': bool(torch.cuda.is_available()),
    'gpu': torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
}, ensure_ascii=False))
'@
if ($LASTEXITCODE -ne 0) {
    throw 'Python 依赖导入测试失败。'
}

$runtimeInfo = $probe | Select-Object -Last 1 | ConvertFrom-Json
if (-not $runtimeInfo.gpu_available) {
    Write-Warning '运行时安装完成，但 PyTorch 当前没有检测到 AMD GPU。请检查显卡型号、驱动和 wheel 架构。'
}

$manifest = [ordered]@{
    schema = 1
    installed_at = (Get-Date).ToUniversalTime().ToString('o')
    python = $runtimeInfo.python
    torch = $runtimeInfo.torch
    hip = $runtimeInfo.hip
    gpu_available = $runtimeInfo.gpu_available
    gpu = $runtimeInfo.gpu
    amd_wheel_index = $AmdWheelIndex
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runtimeDir 'lingchat-runtime.json') -Encoding UTF8

Write-Host ''
Write-Host 'AMD 运行时安装完成。' -ForegroundColor Green
Write-Host ($manifest | ConvertTo-Json -Depth 5)
