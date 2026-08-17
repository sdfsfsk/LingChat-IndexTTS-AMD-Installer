[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$LingChatPath = '',
    # 上游 index-tts 锁定提交（v2.5.0 时代码线，AMD 补丁锚点以它为准）
    [string]$RepoRevision = '4f8792ff120cd3ea470dd511e997a17c86cddd10',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$binDir = Resolve-LingChatBin -LingChatPath $LingChatPath
$dataDir = Resolve-IndexTtsDataDir -BinDir $binDir
$runtimeDir = Join-Path $dataDir 'runtime'
$pythonExe = Join-Path $runtimeDir 'python.exe'
$repoDir = Join-Path $dataDir 'repo'
$repoPatchScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Apply-RepoAmdCompat.py')).Path
$serverDir = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\server')).Path
$serverManifestPath = Join-Path $dataDir 'server-manifest.json'

if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
    throw "没有找到服务器 Python 运行时（$runtimeDir）。请先运行 Install-Runtime.ps1。"
}

Write-Host "服务器目录：$dataDir" -ForegroundColor Green
Write-Host "上游源码提交：$RepoRevision" -ForegroundColor Green

# ---- 上游 indextts 包（zip 快照，不含 .git） ----
$installedRevision = $null
if (Test-Path -LiteralPath $serverManifestPath -PathType Leaf) {
    try {
        $installedRevision = (Get-Content -LiteralPath $serverManifestPath -Raw | ConvertFrom-Json).upstream_revision
    } catch {
        Write-Warning "无法读取旧服务端清单，将重新安装上游源码：$($_.Exception.Message)"
    }
}
$needRepo =
    $Force -or
    -not (Test-Path -LiteralPath (Join-Path $repoDir 'indextts\infer_v2_5.py') -PathType Leaf) -or
    $installedRevision -ne $RepoRevision
if ($needRepo) {
    $cacheDir = Join-Path $env:TEMP 'LingChat-IndexTTS-Installer'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $zipPath = Join-Path $cacheDir "index-tts-$RepoRevision.zip"
    $zipUrl = "https://codeload.github.com/index-tts/index-tts/zip/$RepoRevision"

    Write-Host '下载 index-tts 上游源码快照……' -ForegroundColor Cyan
    # codeload 不支持断点续传，直接整体下载（约 36 MB）
    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw '没有找到 Windows curl.exe。请更新 Windows，或手动安装 curl 后重试。'
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Invoke-CheckedCommand -FilePath $curl.Source -ArgumentList @(
        '--location', '--fail', '--retry', '5', '--retry-delay', '3',
        '--connect-timeout', '30', '--ssl-revoke-best-effort',
        '--output', $zipPath, $zipUrl
    ) -Description '下载 index-tts 源码 zip'

    $extractDir = Join-Path $cacheDir "index-tts-$RepoRevision"
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $cacheDir -Force

    $packageSrc = Join-Path $extractDir 'indextts'
    if (-not (Test-Path -LiteralPath (Join-Path $packageSrc 'infer_v2_5.py') -PathType Leaf)) {
        throw "源码快照中缺少 indextts\infer_v2_5.py，提交号可能有误：$RepoRevision"
    }

    if (Test-Path -LiteralPath $repoDir) {
        Remove-Item -LiteralPath $repoDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
    Copy-Item -LiteralPath $packageSrc -Destination $repoDir -Recurse -Force
} else {
    Write-Host '上游源码已存在，跳过下载（-Force 可强制刷新）。' -ForegroundColor DarkGray
}

Invoke-CheckedCommand -FilePath $pythonExe -ArgumentList @($repoPatchScript, $repoDir) -Description '应用 AMD 上游源码兼容补丁'

# ---- 服务端脚本（本仓库自带，随 LingChat 的 HTTP indextts2 适配器契约实现） ----
$serverFiles = @(
    'server_indextts.py',
    'cleanup-indextts-port.ps1',
    '启动-IndexTTS-AMD.bat',
    '停止-IndexTTS-AMD.bat'
)
foreach ($name in $serverFiles) {
    Copy-Item -LiteralPath (Join-Path $serverDir $name) -Destination (Join-Path $dataDir $name) -Force
}
foreach ($name in @('voices', 'outputs', 'miopen\db_infer', 'miopen\cache_infer')) {
    New-Item -ItemType Directory -Path (Join-Path $dataDir $name) -Force | Out-Null
}

$manifest = [ordered]@{
    schema = 1
    installed_at = (Get-Date).ToUniversalTime().ToString('o')
    upstream_repo = 'index-tts/index-tts'
    upstream_revision = $RepoRevision
    amd_patch = 'repo + site-packages（见 scripts/Apply-*.py）'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $serverManifestPath -Encoding UTF8

Write-Host ''
Write-Host '服务端安装完成。' -ForegroundColor Green
Write-Host "启动脚本：$(Join-Path $dataDir '启动-IndexTTS-AMD.bat')" -ForegroundColor Green

