param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutDir,
    [int[]]$Ports = @(6666, 6667, 6668),
    [bool]$KillConflicts = $true,
    [int]$ClientDelayMs = 500,
    [switch]$NoCompile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

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

function Escape-SingleQuotedString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace "'", "''")
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

try {
    Assert-Command -Name "pwsh"
    Assert-Command -Name "java"
    if (-not $NoCompile) {
        Assert-Command -Name "javac"
    }

    $ProjectRoot = Resolve-NormalizedPath -PathValue $ProjectRoot -BasePath (Get-Location).Path
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw "ProjectRoot does not exist: $ProjectRoot"
    }

    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $OutDir = Join-Path -Path $ProjectRoot -ChildPath "out"
    } else {
        $OutDir = Resolve-NormalizedPath -PathValue $OutDir -BasePath $ProjectRoot
    }

    $portsUnique = @($Ports | Sort-Object -Unique)
    if ($portsUnique.Count -eq 0) {
        throw "At least one port must be provided."
    }

    $srcRoot = Join-Path -Path $ProjectRoot -ChildPath "src"
    if (-not (Test-Path -LiteralPath $srcRoot -PathType Container)) {
        throw "Source directory not found: $srcRoot"
    }

    $scriptsRoot = Join-Path -Path $ProjectRoot -ChildPath "scripts"
    if (-not (Test-Path -LiteralPath $scriptsRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
    }

    $runtimeLogsDir = Join-Path -Path $ProjectRoot -ChildPath "runtime-logs"
    if (-not (Test-Path -LiteralPath $runtimeLogsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runtimeLogsDir -Force | Out-Null
    }
    $pidStateFile = Join-Path -Path $runtimeLogsDir -ChildPath "chatroom-pids.json"

    $listeners = @(Get-ListeningSockets -TargetPorts $portsUnique)
    if ($listeners.Count -gt 0) {
        if (-not $KillConflicts) {
            $text = $listeners | ForEach-Object { "port=$($_.LocalPort), pid=$($_.OwningProcess)" }
            throw ("Ports are occupied and KillConflicts is disabled: " + ($text -join "; "))
        }

        $listenerPids = $listeners | Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($listenerPid in $listenerPids) {
            if ($listenerPid -eq $PID) {
                continue
            }

            try {
                Stop-Process -Id $listenerPid -Force -ErrorAction Stop
                Write-Host ("[PortCleanup] Stopped PID {0}" -f $listenerPid)
            } catch {
                Write-Warning ("[PortCleanup] Failed to stop PID {0}: {1}" -f $listenerPid, $_.Exception.Message)
            }
        }

        Start-Sleep -Milliseconds 600
        $remainingListeners = @(Get-ListeningSockets -TargetPorts $portsUnique)
        if ($remainingListeners.Count -gt 0) {
            $text = $remainingListeners | ForEach-Object { "port=$($_.LocalPort), pid=$($_.OwningProcess)" }
            throw ("Ports still occupied after cleanup: " + ($text -join "; "))
        }
    }

    if (-not $NoCompile) {
        if (Test-Path -LiteralPath $OutDir) {
            Remove-Item -LiteralPath $OutDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

        $javaFiles = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter "*.java" |
                Select-Object -ExpandProperty FullName)
        if ($javaFiles.Count -eq 0) {
            throw "No Java source files were found under $srcRoot"
        }

        & javac -encoding UTF-8 -d $OutDir $javaFiles
        if ($LASTEXITCODE -ne 0) {
            throw "Compilation failed, javac exit code: $LASTEXITCODE"
        }
        Write-Host ("[Compile] Success. Output directory: {0}" -f $OutDir)
    } else {
        if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
            throw "OutDir does not exist while -NoCompile is set: $OutDir"
        }
        Write-Host ("[Compile] Skipped. Using existing output: {0}" -f $OutDir)
    }

    $pwshPath = (Get-Command -Name "pwsh" -ErrorAction Stop).Source
    $escapedProjectRoot = Escape-SingleQuotedString -Value $ProjectRoot
    $escapedOutDir = Escape-SingleQuotedString -Value $OutDir

    $targets = @(
        [pscustomobject]@{ Role = "server"; ClassName = "server.serverDemo"; WindowTitle = "ChatRoom-Server" },
        [pscustomobject]@{ Role = "client1"; ClassName = "client.client_1"; WindowTitle = "ChatRoom-Client-1" },
        [pscustomobject]@{ Role = "client2"; ClassName = "client.client_2"; WindowTitle = "ChatRoom-Client-2" },
        [pscustomobject]@{ Role = "client3"; ClassName = "client.client_3"; WindowTitle = "ChatRoom-Client-3" }
    )

    $startedProcesses = @()
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $target = $targets[$i]
        if ($i -gt 0 -and $ClientDelayMs -gt 0) {
            Start-Sleep -Milliseconds $ClientDelayMs
        }

        $escapedTitle = Escape-SingleQuotedString -Value $target.WindowTitle
        $launchCommand = "Set-Location -LiteralPath '$escapedProjectRoot'; " +
            "`$Host.UI.RawUI.WindowTitle = '$escapedTitle'; " +
            "java -cp '$escapedOutDir' $($target.ClassName)"

        $childArgs = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            $launchCommand
        )

        $proc = Start-Process -FilePath $pwshPath -ArgumentList $childArgs -WorkingDirectory $ProjectRoot -PassThru
        $startTimeUtc = $null
        try {
            $startTimeUtc = $proc.StartTime.ToUniversalTime().ToString("o")
        } catch {
            $startTimeUtc = $null
        }

        $startedProcesses += [pscustomobject]@{
            role         = $target.Role
            className    = $target.ClassName
            pid          = [int]$proc.Id
            startTimeUtc = $startTimeUtc
            processName  = $proc.ProcessName
            windowTitle  = $target.WindowTitle
        }

        Write-Host ("[Start] {0} launched, PID={1}" -f $target.ClassName, $proc.Id)
    }

    Start-Sleep -Milliseconds 800
    $portState = @(Get-ListeningSockets -TargetPorts $portsUnique)

    $state = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        projectRoot    = $ProjectRoot
        outDir         = $OutDir
        ports          = $portsUnique
        processes      = $startedProcesses
    }

    $stateJson = $state | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $pidStateFile -Encoding UTF8 -Value $stateJson

    Write-Host ""
    Write-Host "=== Chatroom Startup Summary ==="
    Write-Host ("ProjectRoot : {0}" -f $ProjectRoot)
    Write-Host ("OutDir      : {0}" -f $OutDir)
    Write-Host ("State File  : {0}" -f $pidStateFile)
    Write-Host "Started Processes:"
    $startedProcesses | Format-Table role, className, pid, startTimeUtc -AutoSize
    Write-Host "Listening Ports:"
    if ($portState.Count -gt 0) {
        $portState | Format-Table LocalAddress, LocalPort, OwningProcess -AutoSize
    } else {
        Write-Host "  (none)"
    }
} catch {
    Write-Error ("[start-chatroom] {0}" -f $_.Exception.Message)
    exit 1
}
