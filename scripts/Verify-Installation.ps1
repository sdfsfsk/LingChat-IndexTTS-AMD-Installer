[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$LingChatPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$binDir = Resolve-LingChatBin -LingChatPath $LingChatPath
$runtimeDir = Join-Path $binDir 'engine\runtime'
$pythonExe = Join-Path $runtimeDir 'python.exe'
$pythonDll = Join-Path $runtimeDir 'python310.dll'
$dataDir = Join-Path $binDir 'data\third_party\IndexTTS-AMD'
$checkpointDir = Join-Path $dataDir 'checkpoints'
$voicesDir = Join-Path $dataDir 'voices'

$failures = [System.Collections.Generic.List[string]]::new()
function Test-RequiredFile {
    param([string]$Path, [string]$Label)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $size = (Get-Item -LiteralPath $Path).Length
        Write-Host "[OK] $Label ($size bytes)" -ForegroundColor Green
    } else {
        Write-Host "[缺失] $Label" -ForegroundColor Red
        $failures.Add($Label)
    }
}

Write-Host "校验 LingChat：$binDir" -ForegroundColor Cyan
Test-RequiredFile -Path $pythonExe -Label 'engine\runtime\python.exe'
Test-RequiredFile -Path $pythonDll -Label 'engine\runtime\python310.dll'

$modelFiles = @(
    'config.yaml',
    'bpe.model',
    'gpt.pth',
    's2mel.pth',
    'wav2vec2bert_stats.pt',
    'qwen0.6bemo4-merge\model.safetensors'
)
foreach ($relativePath in $modelFiles) {
    Test-RequiredFile -Path (Join-Path $checkpointDir $relativePath) -Label "checkpoints\$relativePath"
}

if (Test-Path -LiteralPath $pythonExe -PathType Leaf) {
    Write-Host '校验 Python 与 AMD PyTorch……' -ForegroundColor Cyan
    & $pythonExe -c @'
import json
import sys
import torch
import torchaudio
import librosa
import transformers
print(json.dumps({
    'python': sys.version.split()[0],
    'torch': torch.__version__,
    'hip': getattr(torch.version, 'hip', None),
    'gpu_available': bool(torch.cuda.is_available()),
    'gpu': torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
}, ensure_ascii=False))
'@
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('Python/AMD PyTorch 导入')
    }
}

$voiceCount = 0
if (Test-Path -LiteralPath $voicesDir -PathType Container) {
    $voiceCount = @(
        Get-ChildItem -LiteralPath $voicesDir -File |
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.wav', '.mp3', '.flac', '.m4a', '.ogg') }
    ).Count
}
if ($voiceCount -eq 0) {
    Write-Warning '没有发现音色文件。请在 LingChat 高级设置中上传参考音频。'
} else {
    Write-Host "[OK] 音色文件：$voiceCount 个" -ForegroundColor Green
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "校验失败，共 $($failures.Count) 项：" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'IndexTTS-AMD 资源校验通过。' -ForegroundColor Green
