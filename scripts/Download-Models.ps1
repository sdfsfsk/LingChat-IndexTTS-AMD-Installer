[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$LingChatPath = '',
    [string]$Revision = 'main',
    [switch]$Force,
    [switch]$SkipHashVerification
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$modelRepo = 'IndexTeam/IndexTTS-2'
$binDir = Resolve-LingChatBin -LingChatPath $LingChatPath
$dataDir = Join-Path $binDir 'data\third_party\IndexTTS-AMD'
$checkpointDir = Join-Path $dataDir 'checkpoints'
$voicesDir = Join-Path $dataDir 'voices'
New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
New-Item -ItemType Directory -Path $voicesDir -Force | Out-Null

$headers = @{
    'User-Agent' = 'LingChat-IndexTTS-AMD-Installer/1.0'
}
$modelApi = "https://huggingface.co/api/models/$modelRepo/revision/$Revision"
Write-Host "读取官方模型清单：$modelRepo@$Revision" -ForegroundColor Cyan
$modelInfo = Invoke-RestMethod -Uri $modelApi -Headers $headers
$resolvedRevision = [string]$modelInfo.sha
if ([string]::IsNullOrWhiteSpace($resolvedRevision)) {
    throw 'Hugging Face 没有返回模型提交号。'
}

$treeApi = "https://huggingface.co/api/models/$modelRepo/tree/$resolvedRevision" +
    '?recursive=true&expand=true'
$tree = Invoke-RestMethod -Uri $treeApi -Headers $headers
$files = @($tree | Where-Object {
    $_.type -eq 'file' -and $_.path -ne '.gitattributes'
})
if ($files.Count -eq 0) {
    throw '官方模型清单为空。'
}

$requiredBytes = 0L
$remainingBytes = 0L
foreach ($listedFile in $files) {
    $listedSize = [long]$listedFile.size
    $requiredBytes += $listedSize
    $candidate = Join-Path $checkpointDir ([string]$listedFile.path).Replace('/', '\')
    if (
        $Force -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
        (Get-Item -LiteralPath $candidate).Length -ne $listedSize
    ) {
        $remainingBytes += $listedSize
    }
}
Assert-FreeSpace -Path $checkpointDir -RequiredBytes ($remainingBytes + 1GB)

Write-Host "已锁定官方提交：$resolvedRevision" -ForegroundColor Green
Write-Host ("下载体积：{0:N2} GiB，共 {1} 个文件。" -f ($requiredBytes / 1GB), $files.Count) -ForegroundColor Green
Write-Host ("本次最多还需下载：{0:N2} GiB。" -f ($remainingBytes / 1GB)) -ForegroundColor Green

$completed = 0
foreach ($file in $files) {
    $relativePath = [string]$file.path
    $target = Join-Path $checkpointDir ($relativePath.Replace('/', '\'))
    $expectedSize = [long]$file.size
    $expectedSha256 = $null
    if ($file.PSObject.Properties.Name -contains 'lfs' -and $null -ne $file.lfs) {
        $expectedSha256 = [string]$file.lfs.oid
    }

    $valid = $false
    if (-not $Force -and (Test-Path -LiteralPath $target)) {
        $valid = (Get-Item -LiteralPath $target).Length -eq $expectedSize
        if ($valid -and $expectedSha256 -and -not $SkipHashVerification) {
            Write-Host "校验已有文件：$relativePath" -ForegroundColor DarkCyan
            $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            $valid = $actualHash -eq $expectedSha256.ToLowerInvariant()
        }
    }

    if (-not $valid) {
        $encodedPath = ConvertTo-UrlPath -Path $relativePath
        $downloadUrl = "https://huggingface.co/$modelRepo/resolve/$resolvedRevision/$encodedPath" +
            '?download=true'
        Write-Host "[$($completed + 1)/$($files.Count)] $relativePath" -ForegroundColor Cyan
        Invoke-ResumableDownload -Uri $downloadUrl -Destination $target -ExpectedSize $expectedSize

        if ($expectedSha256 -and -not $SkipHashVerification) {
            Write-Host "SHA-256：$relativePath" -ForegroundColor DarkCyan
            $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedSha256.ToLowerInvariant()) {
                throw "SHA-256 校验失败：$relativePath"
            }
        }
    } else {
        Write-Host "[$($completed + 1)/$($files.Count)] 已存在：$relativePath" -ForegroundColor DarkGray
    }
    $completed++
}

$requiredFiles = @(
    'config.yaml',
    'bpe.model',
    'gpt.pth',
    's2mel.pth',
    'wav2vec2bert_stats.pt',
    'qwen0.6bemo4-merge\model.safetensors'
)
foreach ($requiredFile in $requiredFiles) {
    $requiredPath = Join-Path $checkpointDir $requiredFile
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "缺少必要模型文件：$requiredFile"
    }
}

$fileManifest = foreach ($file in $files) {
    $lfsSha = $null
    if ($file.PSObject.Properties.Name -contains 'lfs' -and $null -ne $file.lfs) {
        $lfsSha = [string]$file.lfs.oid
    }
    [ordered]@{
        path = [string]$file.path
        size = [long]$file.size
        sha256 = $lfsSha
    }
}
$manifest = [ordered]@{
    schema = 1
    installed_at = (Get-Date).ToUniversalTime().ToString('o')
    model_repo = $modelRepo
    requested_revision = $Revision
    resolved_revision = $resolvedRevision
    files = @($fileManifest)
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dataDir 'install-manifest.json') -Encoding UTF8

Write-Host ''
Write-Host "IndexTTS2 官方模型安装完成：$checkpointDir" -ForegroundColor Green
Write-Host "模型提交：$resolvedRevision" -ForegroundColor Green
Write-Host "音色目录：$voicesDir" -ForegroundColor Green
Write-Host '请在 LingChat 高级设置中上传你有权使用的参考音频。' -ForegroundColor Yellow
