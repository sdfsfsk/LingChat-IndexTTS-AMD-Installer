[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$LingChatPath = '',
    [string]$AmdWheelIndex = 'https://repo.amd.com/rocm/whl/gfx120X-all',
    [string]$ModelRevision = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$binDir = Resolve-LingChatBin -LingChatPath $LingChatPath

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ' LingChat IndexTTS-AMD 完整安装' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host "目标目录：$binDir"
Write-Host ''

& (Join-Path $PSScriptRoot 'Install-Runtime.ps1') `
    -LingChatPath $binDir `
    -AmdWheelIndex $AmdWheelIndex
if ($LASTEXITCODE -ne 0) {
    throw "AMD 运行时安装失败，退出代码：$LASTEXITCODE"
}

& (Join-Path $PSScriptRoot 'Download-Models.ps1') `
    -LingChatPath $binDir `
    -Revision $ModelRevision
if ($LASTEXITCODE -ne 0) {
    throw "模型下载失败，退出代码：$LASTEXITCODE"
}

& (Join-Path $PSScriptRoot 'Verify-Installation.ps1') -LingChatPath $binDir
if ($LASTEXITCODE -ne 0) {
    throw "安装校验失败，退出代码：$LASTEXITCODE"
}
