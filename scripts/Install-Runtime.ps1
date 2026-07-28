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
$engineDir = Join-Path $binDir 'engine'
$runtimeDir = Join-Path $engineDir 'runtime'
$pythonExe = Join-Path $runtimeDir 'python.exe'
$pythonDll = Join-Path $runtimeDir 'python310.dll'
$requirements = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\requirements-runtime.txt')).Path

New-Item -ItemType Directory -Path $engineDir -Force | Out-Null
Assert-FreeSpace -Path $engineDir -RequiredBytes 10GB

Write-Host "LingChat bin：$binDir" -ForegroundColor Green
Write-Host "AMD wheel：$AmdWheelIndex" -ForegroundColor Green

$installPython = $Force -or -not (Test-Path -LiteralPath $pythonExe) -or -not (Test-Path -LiteralPath $pythonDll)
if ($installPython) {
    $pythonUrl = 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe'
    $cacheDir = Join-Path $env:TEMP 'LingChat-IndexTTS-Installer'
    $pythonInstaller = Join-Path $cacheDir 'python-3.10.11-amd64.exe'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

    Write-Host '下载 Python 3.10.11 官方安装程序……' -ForegroundColor Cyan
    Invoke-ResumableDownload -Uri $pythonUrl -Destination $pythonInstaller -ExpectedSize 29037240

    $signature = Get-AuthenticodeSignature -LiteralPath $pythonInstaller
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Python 安装程序数字签名无效：$($signature.Status) / $($signature.StatusMessage)"
    }

    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $installArguments = @(
        '/quiet',
        'InstallAllUsers=0',
        "TargetDir=$runtimeDir",
        'Include_launcher=0',
        'Include_test=0',
        'Include_doc=0',
        'Include_tcltk=0',
        'Include_pip=1',
        'PrependPath=0',
        'Shortcuts=0',
        'AssociateFiles=0'
    )
    $process = Start-Process -FilePath $pythonInstaller -ArgumentList $installArguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Python 3.10.11 安装失败，退出代码：$($process.ExitCode)"
    }
}

if (-not (Test-Path -LiteralPath $pythonExe) -or -not (Test-Path -LiteralPath $pythonDll)) {
    throw "Python 运行时不完整：$runtimeDir"
}

$pythonVersion = (& $pythonExe -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor)+'.'+str(sys.version_info.micro))").Trim()
if (-not $pythonVersion.StartsWith('3.10.')) {
    throw "LingChat 内嵌接口要求 Python 3.10，当前运行时是 $pythonVersion。"
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
) -Description '安装 IndexTTS2 Python 依赖'

$probe = & $pythonExe -c @'
import json
import torch
import torchaudio
import librosa
import transformers
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
