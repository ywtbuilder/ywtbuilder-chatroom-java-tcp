param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$ForceByPort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $PathValue))
}

function Get-ListeningSockets {
    param([Parameter(Mandatory = $true)][int[]]$TargetPorts)

    $results = @()

    if (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $rows = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $TargetPorts -contains $_.LocalPort }
            foreach ($row in $rows) {
                $results += [pscustomobject]@{
                    LocalAddress  = [string]$row.LocalAddress
                    LocalPort     = [int]$row.LocalPort
                    OwningProcess = [int]$row.OwningProcess
                }
            }
        } catch {
            # netstat fallback below
        }
    }

    if ($results.Count -eq 0) {
        $pattern = ":((" + (($TargetPorts | Sort-Object -Unique) -join "|") + "))\s+.*LISTENING"
        $lines = netstat -ano -p tcp | Select-String -Pattern $pattern
        foreach ($line in $lines) {
            $parts = ($line.ToString().Trim() -split "\s+")
            if ($parts.Count -lt 5) {
                continue
            }

            $localEndpoint = $parts[1]
            $pidText = $parts[-1]
            $localPortText = ($localEndpoint -split ":")[-1]
            $localAddress = ($localEndpoint -replace ":\d+$", "")

            if ($pidText -as [int] -and $localPortText -as [int]) {
                $results += [pscustomobject]@{
                    LocalAddress  = $localAddress
                    LocalPort     = [int]$localPortText
                    OwningProcess = [int]$pidText
                }
            }
        }
    }

    return $results | Sort-Object LocalPort, OwningProcess -Unique
}

function Get-ChatroomJavaProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$ClassName
    )

    $outNormalized = ($OutDir -replace "/", "\").ToLowerInvariant()
    $classNormalized = $ClassName.ToLowerInvariant()
    $results = @()

    $javaProcesses = @()
    $javaProcesses += @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue)
    $javaProcesses += @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe'" -ErrorAction SilentlyContinue)

    foreach ($proc in $javaProcesses) {
        $cmd = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            continue
        }

        $cmdNormalized = ($cmd -replace "/", "\").ToLowerInvariant()
        if (-not $cmdNormalized.Contains($outNormalized)) {
            continue
        }
        if (-not $cmdNormalized.Contains($classNormalized)) {
            continue
        }

        $results += [pscustomobject]@{
            pid        = [int]$proc.ProcessId
            className  = $ClassName
            commandLine = $cmd
        }
    }

    return $results
}

try {
    $ports = @(6666, 6667, 6668)
    $ProjectRoot = Resolve-NormalizedPath -PathValue $ProjectRoot -BasePath (Get-Location).Path
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw "ProjectRoot does not exist: $ProjectRoot"
    }

    $runtimeLogsDir = Join-Path -Path $ProjectRoot -ChildPath "runtime-logs"
    if (-not (Test-Path -LiteralPath $runtimeLogsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runtimeLogsDir -Force | Out-Null
    }
    $pidStateFile = Join-Path -Path $runtimeLogsDir -ChildPath "chatroom-pids.json"

    $trackedProcesses = @()
    $stateOutDir = Join-Path -Path $ProjectRoot -ChildPath "out"
    if (Test-Path -LiteralPath $pidStateFile -PathType Leaf) {
        $rawJson = Get-Content -LiteralPath $pidStateFile -Raw
        if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
            try {
                $stateObject = $rawJson | ConvertFrom-Json -ErrorAction Stop
                if ($stateObject -and $stateObject.PSObject.Properties.Name -contains "outDir" -and -not [string]::IsNullOrWhiteSpace([string]$stateObject.outDir)) {
                    $stateOutDir = [string]$stateObject.outDir
                }
                if ($stateObject -and $stateObject.processes) {
                    $trackedProcesses = @($stateObject.processes)
                }
            } catch {
                Write-Warning ("Unable to parse state file, will continue with empty tracked list: {0}" -f $_.Exception.Message)
            }
        }
    }

    $stopped = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[object]

    foreach ($item in $trackedProcesses) {
        if (-not $item.pid) {
            continue
        }

        $targetPid = [int]$item.pid
        $targetClass = [string]$item.className
        $expectedStartTime = $null
        if ($item.PSObject.Properties.Name -contains "startTimeUtc") {
            $expectedStartTime = [string]$item.startTimeUtc
        }

        $proc = $null
        $stoppedByPid = $false
        try {
            $proc = Get-Process -Id $targetPid -ErrorAction Stop
        } catch {
            $missing.Add([pscustomobject]@{ pid = $targetPid; className = $targetClass; reason = "not running" }) | Out-Null
        }

        if ($proc -ne $null) {
            if (-not [string]::IsNullOrWhiteSpace($expectedStartTime)) {
                try {
                    $actualStartTime = $proc.StartTime.ToUniversalTime().ToString("o")
                    if ($actualStartTime -ne $expectedStartTime) {
                        $skipped.Add([pscustomobject]@{
                                pid = $targetPid
                                className = $targetClass
                                reason = "pid reused (startTime mismatch)"
                            }) | Out-Null
                    } else {
                        try {
                            Stop-Process -Id $targetPid -Force -ErrorAction Stop
                            $stopped.Add([pscustomobject]@{ pid = $targetPid; className = $targetClass; source = "state-file" }) | Out-Null
                            $stoppedByPid = $true
                        } catch {
                            $skipped.Add([pscustomobject]@{
                                    pid = $targetPid
                                    className = $targetClass
                                    reason = ("stop failed: {0}" -f $_.Exception.Message)
                                }) | Out-Null
                        }
                    }
                } catch {
                    $skipped.Add([pscustomobject]@{
                            pid = $targetPid
                            className = $targetClass
                            reason = "cannot verify start time"
                        }) | Out-Null
                }
            } else {
                try {
                    Stop-Process -Id $targetPid -Force -ErrorAction Stop
                    $stopped.Add([pscustomobject]@{ pid = $targetPid; className = $targetClass; source = "state-file(no-start-time)" }) | Out-Null
                    $stoppedByPid = $true
                } catch {
                    $skipped.Add([pscustomobject]@{
                            pid = $targetPid
                            className = $targetClass
                            reason = ("stop failed: {0}" -f $_.Exception.Message)
                        }) | Out-Null
                }
            }
        }

        if ($stoppedByPid) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($targetClass)) {
            $classMatches = @(Get-ChatroomJavaProcesses -OutDir $stateOutDir -ClassName $targetClass)
            foreach ($match in $classMatches) {
                if ($match.pid -eq $PID) {
                    continue
                }
                if (@($stopped | Where-Object { $_.pid -eq $match.pid }).Count -gt 0) {
                    continue
                }

                try {
                    Stop-Process -Id $match.pid -Force -ErrorAction Stop
                    $stopped.Add([pscustomobject]@{ pid = $match.pid; className = $targetClass; source = "class-scan" }) | Out-Null
                } catch {
                    $skipped.Add([pscustomobject]@{
                            pid = $match.pid
                            className = $targetClass
                            reason = ("class-scan stop failed: {0}" -f $_.Exception.Message)
                        }) | Out-Null
                }
            }
        }
    }

    if ($ForceByPort) {
        $listeners = @(Get-ListeningSockets -TargetPorts $ports)
        $listenerPids = $listeners | Select-Object -ExpandProperty OwningProcess -Unique

        foreach ($listenerPid in $listenerPids) {
            if ($listenerPid -eq $PID) {
                continue
            }

            if (@($stopped | Where-Object { $_.pid -eq $listenerPid }).Count -gt 0) {
                continue
            }

            $proc = $null
            try {
                $proc = Get-Process -Id $listenerPid -ErrorAction Stop
            } catch {
                continue
            }

            if ($proc.ProcessName -notmatch "^javaw?$") {
                $skipped.Add([pscustomobject]@{
                        pid = $listenerPid
                        className = "(unknown)"
                        reason = "port listener is not java/javaw"
                    }) | Out-Null
                continue
            }

            try {
                Stop-Process -Id $listenerPid -Force -ErrorAction Stop
                $stopped.Add([pscustomobject]@{ pid = $listenerPid; className = "(by-port)"; source = "force-by-port" }) | Out-Null
            } catch {
                $skipped.Add([pscustomobject]@{
                        pid = $listenerPid
                        className = "(unknown)"
                        reason = ("force-by-port stop failed: {0}" -f $_.Exception.Message)
                    }) | Out-Null
            }
        }
    }

    $remainingTracked = @()
    foreach ($item in $trackedProcesses) {
        if (-not $item.pid) {
            continue
        }

        $targetPid = [int]$item.pid
        try {
            $proc = Get-Process -Id $targetPid -ErrorAction Stop
            $isMatch = $true
            if ($item.PSObject.Properties.Name -contains "startTimeUtc" -and -not [string]::IsNullOrWhiteSpace([string]$item.startTimeUtc)) {
                try {
                    $actualStartTime = $proc.StartTime.ToUniversalTime().ToString("o")
                    if ($actualStartTime -ne [string]$item.startTimeUtc) {
                        $isMatch = $false
                    }
                } catch {
                    $isMatch = $false
                }
            }

            if ($isMatch) {
                $remainingTracked += $item
            }
        } catch {
            # already stopped or missing
        }
    }

    $newState = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        projectRoot    = $ProjectRoot
        outDir         = (Join-Path -Path $ProjectRoot -ChildPath "out")
        ports          = $ports
        processes      = $remainingTracked
    }
    $newStateJson = $newState | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $pidStateFile -Encoding UTF8 -Value $newStateJson

    $remainingListeners = @(Get-ListeningSockets -TargetPorts $ports)

    Write-Host ""
    Write-Host "=== Chatroom Stop Summary ==="
    Write-Host ("ProjectRoot : {0}" -f $ProjectRoot)
    Write-Host ("State File  : {0}" -f $pidStateFile)
    Write-Host ("Stopped     : {0}" -f $stopped.Count)
    Write-Host ("Skipped     : {0}" -f $skipped.Count)
    Write-Host ("Missing     : {0}" -f $missing.Count)
    Write-Host ("Remaining Tracked Processes: {0}" -f $remainingTracked.Count)

    if ($stopped.Count -gt 0) {
        Write-Host "Stopped Items:"
        $stopped | Format-Table pid, className, source -AutoSize
    }
    if ($skipped.Count -gt 0) {
        Write-Host "Skipped Items:"
        $skipped | Format-Table pid, className, reason -AutoSize
    }
    if ($missing.Count -gt 0) {
        Write-Host "Missing Items:"
        $missing | Format-Table pid, className, reason -AutoSize
    }

    Write-Host "Current Listening Ports (6666/6667/6668):"
    if ($remainingListeners.Count -gt 0) {
        $remainingListeners | Format-Table LocalAddress, LocalPort, OwningProcess -AutoSize
    } else {
        Write-Host "  (none)"
    }
} catch {
    Write-Error ("[stop-chatroom] {0}" -f $_.Exception.Message)
    exit 1
}
