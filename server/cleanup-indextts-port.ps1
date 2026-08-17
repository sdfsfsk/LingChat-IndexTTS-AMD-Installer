[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedServerScript,

    [string]$LauncherScript = "",

    [ValidateRange(1, 30)]
    [int]$WaitSeconds = 8
)

$ErrorActionPreference = "Stop"
$expectedServer = [IO.Path]::GetFullPath($ExpectedServerScript)
$expectedLauncher = if ($LauncherScript) {
    [IO.Path]::GetFullPath($LauncherScript)
} else {
    ""
}

function Test-CommandLineContains {
    param(
        [string]$CommandLine,
        [string]$ExpectedPath
    )

    return -not [string]::IsNullOrWhiteSpace($CommandLine) -and
        $CommandLine.IndexOf($ExpectedPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

$listeners = @(
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Sort-Object -Property OwningProcess -Unique
)

if ($listeners.Count -eq 0) {
    Write-Host "[port-check] Port $Port is free."
    exit 0
}

foreach ($listener in $listeners) {
    $ownerPid = [int]$listener.OwningProcess
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue

    if (-not $owner) {
        continue
    }

    if (-not (Test-CommandLineContains -CommandLine $owner.CommandLine -ExpectedPath $expectedServer)) {
        [Console]::Error.WriteLine((
            "Port {0} belongs to another program; refusing to stop it. PID={1}, executable={2}, command={3}" -f
            $Port, $ownerPid, $owner.ExecutablePath, $owner.CommandLine
        ))
        exit 2
    }

    $parentPid = [int]$owner.ParentProcessId
    $parent = if ($parentPid -gt 0) {
        Get-CimInstance Win32_Process -Filter "ProcessId = $parentPid" -ErrorAction SilentlyContinue
    }

    Write-Host "[port-check] Stopping old IndexTTS server: port=$Port PID=$ownerPid"
    Stop-Process -Id $ownerPid -Force -ErrorAction Stop

    # Close only a cmd process that explicitly launched the old batch file.
    # An unrelated interactive terminal is never stopped.
    if ($parent -and $expectedLauncher -and
        (Test-CommandLineContains -CommandLine $parent.CommandLine -ExpectedPath $expectedLauncher)) {
        Start-Sleep -Milliseconds 200
        Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
do {
    $remaining = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Write-Host "[port-check] Port $Port has been released."
        exit 0
    }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)

[Console]::Error.WriteLine("Port $Port is still occupied after $WaitSeconds seconds; startup cancelled.")
exit 3
