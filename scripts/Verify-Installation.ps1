[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$LingChatPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$binDir = Resolve-LingChatBin -LingChatPath $LingChatPath
$dataDir = Resolve-IndexTtsDataDir -BinDir $binDir
$runtimeDir = Join-Path $dataDir 'runtime'
$pythonExe = Join-Path $runtimeDir 'python.exe'
$repoDir = Join-Path $dataDir 'repo'
$checkpointDir25 = Join-Path $dataDir 'checkpoints-2.5'
$checkpointDir2 = Join-Path $dataDir 'checkpoints'
$voicesDir = Join-Path $dataDir 'voices'

$failures = [System.Collections.Generic.List[string]]::new()
function Test-RequiredFile {
    param([string]$Path, [string]$Label)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $size = (Get-Item -LiteralPath $Path).Length
        Write-Host "[OK] $Label ($size bytes)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[缺失] $Label" -ForegroundColor Red
        $failures.Add($Label)
        return $false
    }
}

function Test-FileContains {
    param([string]$Path, [string]$Marker, [string]$Label)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $hit = Select-String -LiteralPath $Path -Pattern $Marker -SimpleMatch -Quiet
        if ($hit) {
            Write-Host "[OK] $Label" -ForegroundColor Green
            return $true
        }
    }
    Write-Host "[缺失] $Label" -ForegroundColor Red
    $failures.Add($Label)
    return $false
}

Write-Host "校验 LingChat：$binDir" -ForegroundColor Cyan
Test-RequiredFile -Path $pythonExe -Label 'runtime\python.exe' | Out-Null

Write-Host '校验服务端文件……' -ForegroundColor Cyan
foreach ($name in @('server_indextts.py', 'cleanup-indextts-port.ps1', '启动-IndexTTS-AMD.bat', '停止-IndexTTS-AMD.bat')) {
    Test-RequiredFile -Path (Join-Path $dataDir $name) -Label $name | Out-Null
}

Write-Host '校验上游源码与 AMD 补丁……' -ForegroundColor Cyan
$infer25 = Join-Path $repoDir 'indextts\infer_v2_5.py'
Test-RequiredFile -Path $infer25 -Label 'repo\indextts\infer_v2_5.py' | Out-Null
Test-FileContains -Path $infer25 -Marker 'use_vocoder_fp16' -Label 'infer_v2_5.py AMD 补丁' | Out-Null
$infer2 = Join-Path $repoDir 'indextts\infer_v2.py'
Test-RequiredFile -Path $infer2 -Label 'repo\indextts\infer_v2.py' | Out-Null
Test-FileContains -Path $infer2 -Marker 'use_vocoder_fp16' -Label 'infer_v2.py AMD 补丁' | Out-Null
$transformersFile = Join-Path $runtimeDir 'Lib\site-packages\transformers\modeling_utils.py'
$audiotoolsFile = Join-Path $runtimeDir 'Lib\site-packages\audiotools\ml\decorators.py'
Test-FileContains -Path $transformersFile -Marker 'import torch.distributed.tensor  # noqa: F401' -Label 'transformers AMD 补丁' | Out-Null
Test-FileContains -Path $audiotoolsFile -Marker '_REDUCE_OP_AVG' -Label 'audiotools AMD 补丁' | Out-Null

Write-Host '校验 IndexTTS-2.5 模型……' -ForegroundColor Cyan
$model25Files = @(
    'config.yaml',
    'codec.pth',
    'feat1.pt',
    'feat2.pt',
    'gpt.pth',
    's2mel.pth',
    'wav2vec2bert_stats.pt',
    'multilingual_zh_ja_yue_char_del.tiktoken',
    'qwen0.6bemo4-merge\model.safetensors'
)
$found25 = 0
foreach ($relativePath in $model25Files) {
    if (Test-RequiredFile -Path (Join-Path $checkpointDir25 $relativePath) -Label "checkpoints-2.5\$relativePath") {
        $found25++
    }
}

if ($found25 -eq 0) {
    # 完全没有 2.5 时，看看是不是只装了旧版 v2 回退
    $failures.Clear()
    Write-Host '没有发现 2.5 模型，检查旧版 IndexTTS-2 回退……' -ForegroundColor Yellow
    $model2Files = @(
        'config.yaml',
        'bpe.model',
        'gpt.pth',
        's2mel.pth',
        'wav2vec2bert_stats.pt',
        'qwen0.6bemo4-merge\model.safetensors'
    )
    foreach ($relativePath in $model2Files) {
        Test-RequiredFile -Path (Join-Path $checkpointDir2 $relativePath) -Label "checkpoints\$relativePath" | Out-Null
    }
    if ($failures.Count -eq 0) {
        Write-Warning '只安装了旧版 IndexTTS-2。启动服务器前需要 set INDEXTTS_VERSION=2。'
    }
}

if (Test-Path -LiteralPath $pythonExe -PathType Leaf) {
    Write-Host '校验服务端 Python 语法……' -ForegroundColor Cyan
    & $pythonExe -m py_compile (Join-Path $dataDir 'server_indextts.py')
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('server_indextts.py 语法')
    }

    Write-Host '校验 Python 与 AMD PyTorch……' -ForegroundColor Cyan
    & $pythonExe -c @'
import json
import sys
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
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.wav', '.mp3', '.flac', '.ogg') }
    ).Count
}
if ($voiceCount -eq 0) {
    Write-Warning "没有发现音色文件。请把你有权使用的参考音频放进 $voicesDir。"
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
Write-Host 'IndexTTS-AMD 独立服务器资源校验通过。' -ForegroundColor Green
Write-Host "双击 $(Join-Path $dataDir '启动-IndexTTS-AMD.bat') 启动服务，健康检查：http://127.0.0.1:9880/health" -ForegroundColor Green

