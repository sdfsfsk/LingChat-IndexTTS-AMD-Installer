Set-StrictMode -Version Latest

function Resolve-LingChatBin {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$LingChatPath
    )

    if ([string]::IsNullOrWhiteSpace($LingChatPath)) {
        $nearbyCandidates = @(
            (Join-Path $PSScriptRoot '..\..\LingChat-rust\bin'),
            (Join-Path $PSScriptRoot '..\bin'),
            (Join-Path (Get-Location) 'bin'),
            (Get-Location).Path
        )
        foreach ($candidate in $nearbyCandidates) {
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                $resolvedCandidate = (Resolve-Path -LiteralPath $candidate).Path
                if (
                    (Test-Path -LiteralPath (Join-Path $resolvedCandidate 'ling_chat.exe')) -or
                    (Test-Path -LiteralPath (Join-Path $resolvedCandidate 'LingChat.exe')) -or
                    (Test-Path -LiteralPath (Join-Path $resolvedCandidate 'engine'))
                ) {
                    return $resolvedCandidate
                }
            }
        }

        $LingChatPath = Read-Host '请输入 LingChat 安装目录（可填写根目录或 bin 目录）'
    }

    if ([string]::IsNullOrWhiteSpace($LingChatPath)) {
        throw '没有提供 LingChat 安装目录。'
    }

    $resolved = (Resolve-Path -LiteralPath $LingChatPath -ErrorAction Stop).Path
    $binCandidate = Join-Path $resolved 'bin'
    if (Test-Path -LiteralPath $binCandidate -PathType Container) {
        $resolved = (Resolve-Path -LiteralPath $binCandidate).Path
    }

    $hasExecutable =
        (Test-Path -LiteralPath (Join-Path $resolved 'ling_chat.exe')) -or
        (Test-Path -LiteralPath (Join-Path $resolved 'LingChat.exe')) -or
        (Test-Path -LiteralPath (Join-Path $resolved 'LingChat.exe.exe'))
    $hasLayout =
        (Test-Path -LiteralPath (Join-Path $resolved 'engine')) -or
        (Test-Path -LiteralPath (Join-Path $resolved 'data'))

    if (-not $hasExecutable -and -not $hasLayout) {
        throw "目录不像 LingChat 的 bin 目录：$resolved"
    }

    return $resolved
}

function Assert-FreeSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [long]$RequiredBytes
    )

    $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).Path)
    $drive = [System.IO.DriveInfo]::new($root)
    if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
        $requiredGiB = [Math]::Ceiling($RequiredBytes / 1GB)
        $availableGiB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 2)
        throw "磁盘空间不足：至少需要 ${requiredGiB} GiB，当前只剩 ${availableGiB} GiB。"
    }
}

function Invoke-CheckedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter()]
        [string[]]$ArgumentList = @(),
        [Parameter()]
        [string]$Description = $FilePath
    )

    Write-Host ">> $Description" -ForegroundColor Cyan
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$Description 失败，退出代码：$LASTEXITCODE"
    }
}

function Invoke-ResumableDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [Parameter(Mandatory)]
        [string]$Destination,
        [long]$ExpectedSize = 0
    )

    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw '没有找到 Windows curl.exe。请更新 Windows，或手动安装 curl 后重试。'
    }

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $partial = "$Destination.part"
    if ((Test-Path -LiteralPath $Destination) -and $ExpectedSize -gt 0) {
        if ((Get-Item -LiteralPath $Destination).Length -eq $ExpectedSize) {
            return
        }
    }

    $arguments = @(
        '--location',
        '--fail',
        '--retry', '5',
        '--retry-delay', '3',
        '--connect-timeout', '30',
        '--ssl-revoke-best-effort',
        '--continue-at', '-',
        '--output', $partial,
        $Uri
    )
    Invoke-CheckedCommand -FilePath $curl.Source -ArgumentList $arguments -Description "下载 $(Split-Path -Leaf $Destination)"

    if ($ExpectedSize -gt 0) {
        $actualSize = (Get-Item -LiteralPath $partial).Length
        if ($actualSize -ne $ExpectedSize) {
            throw "文件大小不正确：$(Split-Path -Leaf $Destination)，预期 $ExpectedSize，实际 $actualSize。"
        }
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function ConvertTo-UrlPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $encoded = $Path -split '/' | ForEach-Object {
        [Uri]::EscapeDataString($_)
    }
    return ($encoded -join '/')
}
