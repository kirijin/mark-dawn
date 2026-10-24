function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateSet("Debug", "Info", "Warn", "Error")]
        [string]$Level,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$Message,
        [switch]$NoConsole
    )
    $levelMap = @{ "Debug" = 0; "Info" = 1; "Warn" = 2; "Error" = 3 }
    if ($levelMap[$Level] -lt $Script:_logLevelNum) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logLine = "[$timestamp] [$Level] $Message"

    if (-not $NoConsole) {
        $colorMap = @{ "Debug" = "DarkGray"; "Info" = "White"; "Warn" = "Yellow"; "Error" = "Red" }
        $prefix = @{ "Debug" = "DBG"; "Info" = "   "; "Warn" = "WRN"; "Error" = "ERR" }
        Write-Host "[$($prefix[$Level])] " -ForegroundColor $colorMap[$Level] -NoNewline
        Write-Host $Message
    }

    try {
        if ($Script:_installLog) {
            $logLine | Out-File -FilePath $Script:_installLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Write-Step {
    param([string]$n, [string]$m)
    Write-Host "[$n] " -ForegroundColor Cyan -NoNewline
    Write-Host $m
    try {
        if ($Script:_installLog) {
            "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))] [STEP] [$n] $m" | Out-File -FilePath $Script:_installLog -Append -Encoding utf8 -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Write-OK   { param([string]$m) Write-Host "OK: $m" -ForegroundColor Green; Write-Log "Info" "OK: $m" -NoConsole }

function Write-Info { param([string]$m) Write-Host ">> $m" -ForegroundColor Yellow; Write-Log "Info" ">> $m" -NoConsole }

function Write-Fail {
    param([string]$m)
    Write-Host "FAIL: $m" -ForegroundColor Red
    Write-Log "Error" "FAIL: $m"
    exit 1
}

function Assert-PathSafe {
    param([string]$Path)
    if ($Path.Length -gt 200) {
        throw "Path exceeds 200 characters (use short paths): $Path"
    }
    if ($Path -match '["<>|]') {
        throw "Path contains invalid characters: $Path"
    }
    return $true
}

function Join-PathSafe {
    param([string]$Parent, [string]$Child)
    return [System.IO.Path]::Combine($Parent, $Child)
}

function Ensure-Directory {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
        }
        Write-Log "Debug" "Directory ready: $Path" -NoConsole
    } catch {
        throw "Cannot create directory '$Path': $_"
    }
}

function Remove-DirectorySafe {
    param([string]$Path, [switch]$Force)
    try {
        if (Test-Path $Path -PathType Container) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Debug" "Removed directory: $Path" -NoConsole
        }
    } catch {
        Write-Log "Warn" "Could not remove directory '$Path': $_" -NoConsole
    }
}

function Test-Sha256 {
    param([string]$FilePath, [string]$ExpectedHash)
    if (-not $ExpectedHash) { return $true }
    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Log "Debug" "File not found for hash check: $FilePath" -NoConsole
        return $false
    }
    try {
        $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
        $expected = $ExpectedHash.ToLower()
        $match = ($actual -eq $expected)
        if (-not $match) {
            Write-Log "Warn" "SHA256 mismatch for '$FilePath': expected=$expected actual=$actual" -NoConsole
        }
        return $match
    } catch {
        Write-Log "Warn" "SHA256 computation failed for '$FilePath': $_" -NoConsole
        return $false
    }
}

function Invoke-DownloadWithRetry {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = 300,
        [string]$ExpectedHash = "",
        [switch]$Force
    )
    if (-not $Force -and (Test-Path $OutFile -PathType Leaf)) {
        if ($ExpectedHash) {
            if (Test-Sha256 -FilePath $OutFile -ExpectedHash $ExpectedHash) {
                Write-Log "Info" "Using cached download: $OutFile" -NoConsole
                return
            } else {
                Write-Log "Warn" "Cached file hash mismatch, re-downloading: $OutFile" -NoConsole
            }
        } else {
            Write-Log "Info" "Using cached download (no hash check): $OutFile" -NoConsole
            return
        }
    }

    $tempFile = "$OutFile.tmp"
    # Clean up stale temp file from interrupted download
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    $attempt = 0
    $backoff = 2
    $usedBits = $false

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    while ($attempt -lt ($MaxRetries + 1)) {
        $attempt++
        try {
            Write-Log "Info" "Downloading (attempt $attempt/$MaxRetries): $Url" -NoConsole
            Write-Info "Downloading $(Split-Path $Url -Leaf) (may take a few minutes)..."
            if (-not $usedBits) {
                $params = @{
                    Uri             = $Url
                    OutFile         = $tempFile
                    UseBasicParsing = $true
                    ErrorAction     = "Stop"
                    TimeoutSec      = 900
                    MaximumRedirection = 10
                }
                Invoke-WebRequest @params
            } else {
                Start-BitsTransfer -Source $Url -Destination $tempFile -ErrorAction Stop
            }

            $fileInfo = Get-Item $tempFile -ErrorAction Stop
            if ($fileInfo.Length -eq 0) {
                throw "Downloaded file is empty"
            }

            if ($ExpectedHash) {
                if (-not (Test-Sha256 -FilePath $tempFile -ExpectedHash $ExpectedHash)) {
                    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                    throw "SHA256 hash mismatch"
                }
            }

            if (Test-Path $OutFile -PathType Leaf) {
                Remove-Item -Path $OutFile -Force -ErrorAction Stop
            }
            Rename-Item -Path $tempFile -NewName (Split-Path $OutFile -Leaf) -ErrorAction Stop
            Write-Log "Info" "Download complete: $OutFile" -NoConsole
            return

        } catch {
            Write-Log "Warn" "Download attempt $attempt failed: $_" -NoConsole
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            if ($attempt -ge $MaxRetries) {
                throw "Download failed after $MaxRetries attempts: $_"
            }
            # On first failure, retry with BITS (more resilient for large files)
            if (-not $usedBits -and $attempt -lt $MaxRetries) {
                Write-Log "Info" "Retrying with BITS transfer..." -NoConsole
                $usedBits = $true
                continue
            }
            Write-Log "Info" "Retrying in ${backoff}s..." -NoConsole
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, 60)
        }
    }
}

function Get-InstallState {
    if (-not (Test-Path $Script:_stateFile -PathType Leaf)) {
        return @{ version = ""; completed = @{}; errors = @() }
    }
    try {
        $json = Get-Content -Path $Script:_stateFile -Raw -Encoding utf8 -ErrorAction Stop
        $state = $json | ConvertFrom-Json -ErrorAction Stop

        $completed = @{}
        if ($state.completed) {
            foreach ($prop in $state.completed.PSObject.Properties) {
                $completed[$prop.Name] = @{
                    status    = $prop.Value.status
                    timestamp = $prop.Value.timestamp
                }
            }
        }

        $errors = @()
        if ($state.errors) {
            foreach ($err in $state.errors) {
                $errors += @{
                    step      = $err.step
                    error     = $err.error
                    timestamp = $err.timestamp
                }
            }
        }

        return @{
            version   = $state.version
            completed = $completed
            errors    = $errors
        }
    } catch {
        Write-Log "Warn" "Could not read state file, starting fresh: $_" -NoConsole
        return @{ version = ""; completed = @{}; errors = @() }
    }
}

function Set-InstallState {
    param(
        [string]$Step,
        [string]$Status,
        [string]$ErrorMsg = ""
    )
    try {
        $state = Get-InstallState
        $state.version = $Script:_installVersion
        if (-not $state.completed) { $state.completed = @{} }
        if (-not $state.errors)    { $state.errors = @() }

        if ($Step) {
            $state.completed[$Step] = @{ status = $Status; timestamp = (Get-Date -Format "o") }
        }
        if ($ErrorMsg) {
            $state.errors += @{ step = $Step; error = $ErrorMsg; timestamp = (Get-Date -Format "o") }
        }

        $json = @{
            version   = $state.version
            completed = $state.completed
            errors    = $state.errors
        } | ConvertTo-Json -Compress

        $tempState = "$($Script:_stateFile).tmp"
        $json | Out-File -FilePath $tempState -Encoding utf8 -Force -ErrorAction Stop
        Rename-Item -Path $tempState -NewName (Split-Path $Script:_stateFile -Leaf) -Force -ErrorAction Stop
    } catch {
        Write-Log "Warn" "Could not write state file: $_" -NoConsole
    }
}

function Test-StepCompleted {
    param([string]$Step)
    $state = Get-InstallState
    if ($state.version -ne $Script:_installVersion) { return $false }
    if (-not $state.completed) { return $false }
    return ($state.completed[$Step] -and $state.completed[$Step].status -eq "ok")
}

function Clear-InstallState {
    try {
        if (Test-Path $Script:_stateFile -PathType Leaf) {
            Remove-Item -Path $Script:_stateFile -Force -ErrorAction Stop
        }
    } catch {
        Write-Log "Warn" "Could not clear state file: $_" -NoConsole
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Fail "This operation requires Administrator privileges.`nPlease run PowerShell as Administrator and try again."
    }
}

function Invoke-Python {
    param(
        [string[]]$ArgumentList,
        [int[]]$ExpectedExitCodes = @(0),
        [switch]$PassThru
    )
    if (-not (Test-Path $Script:_pythonExe -PathType Leaf)) {
        throw "Python not found at: $Script:_pythonExe"
    }
    $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    if ($ExpectedExitCodes -and ($ExpectedExitCodes -notcontains $proc.ExitCode)) {
        throw "Python exited with code $($proc.ExitCode) (expected $ExpectedExitCodes): $($ArgumentList -join ' ')"
    }
    if ($PassThru) { return $proc.ExitCode }
}

function Invoke-Msys2Bash {
    param(
        [string]$Msys2Dir,
        [string]$Command,
        [int[]]$ExpectedExitCodes = @(0),
        [switch]$PassThru
    )
    $bashPath = Join-PathSafe $Msys2Dir "usr\bin\bash.exe"
    if (-not (Test-Path $bashPath -PathType Leaf)) {
        throw "MSYS2 bash not found at: $bashPath"
    }

    $envBackup = @{}
    $envBackup.MSYSTEM = $env:MSYSTEM
    $envBackup.PATH = $env:PATH
    $envBackup.LC_ALL = $env:LC_ALL
    $env:MSYSTEM = "MINGW64"
    $env:LC_ALL = "C"
    # Ensure MSYS2 binaries are on PATH so loader can find cygwin DLLs
    $env:PATH = "$(Join-PathSafe $Msys2Dir 'usr\bin');$(Join-PathSafe $Msys2Dir 'mingw64\bin');$env:PATH"

    try {
        # Write command to temp script (handles multi-line + embedded quotes correctly)
        $tempScript = [System.IO.Path]::GetTempFileName() + ".sh"
        [System.IO.File]::WriteAllText($tempScript, $Command)
        try {
            $proc = Start-Process -FilePath $bashPath -ArgumentList @("-l", $tempScript) -Wait -PassThru -NoNewWindow
        } finally {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
        if ($ExpectedExitCodes -and ($ExpectedExitCodes -notcontains $proc.ExitCode)) {
            throw "Command exited with code $($proc.ExitCode) (expected $ExpectedExitCodes): $Command"
        }
        if ($PassThru) { return $proc.ExitCode }
    } finally {
        $env:MSYSTEM = $envBackup.MSYSTEM
        $env:PATH = $envBackup.PATH
        $env:LC_ALL = $envBackup.LC_ALL
    }
}

function Set-Msys2Mirror {
    param([string]$BaseUrl)
    $arch = "x86_64"
    $mingwList = Join-PathSafe $Script:_msys2Dir "etc\pacman.d\mirrorlist.mingw64"
    $msysList  = Join-PathSafe $Script:_msys2Dir "etc\pacman.d\mirrorlist.msys"
    try {
        Ensure-Directory (Split-Path $mingwList -Parent)
        @("Server = $BaseUrl/mingw/mingw64/") | Out-File $mingwList -Encoding ascii -Force
        @("Server = $BaseUrl/msys/$arch/")    | Out-File $msysList  -Encoding ascii -Force
        Write-Log "Debug" "Set MSYS2 mirror: $BaseUrl" -NoConsole
        return $true
    } catch {
        Write-Log "Warn" "Failed to set mirror ${BaseUrl}: $_" -NoConsole
        return $false
    }
}

function Select-FastestMirror {
    if ($Script:_selectedMsys2Mirror) {
        Write-Log "Debug" "Using previously selected mirror: $($Script:_selectedMsys2Mirror)" -NoConsole
        return Set-Msys2Mirror -BaseUrl $Script:_selectedMsys2Mirror
    }

    $mirrors = $Script:MSYS2_MIRRORS
    if ($Script:_msys2MirrorOverride) {
        Write-Info "Probing user-specified mirror: $($Script:_msys2MirrorOverride)..."
        if (Set-Msys2Mirror -BaseUrl $Script:_msys2MirrorOverride) {
            $Script:_selectedMsys2Mirror = $Script:_msys2MirrorOverride
            return $true
        }
        Write-Log "Warn" "User mirror unreachable, falling back to auto-select" -NoConsole
    }

    # Remove previously failed mirrors from candidates
    $candidates = $mirrors | Where-Object { $_.Base -notin $Script:_failedMsys2Mirrors }
    if ($candidates.Count -eq 0) {
        Write-Log "Warn" "All mirrors have failed, resetting blacklist and retrying all" -NoConsole
        $Script:_failedMsys2Mirrors = @()
        $candidates = $mirrors
    }

    Write-Info "Probing $($candidates.Count) MSYS2 mirrors for fastest response..."
    $probeTimeout = [Math]::Min(5, $Script:TimeoutSec)
    $probeScript = {
        param($Name, $BaseUrl, $TimeoutSec)
        $hostname = ($BaseUrl -replace 'https://', '').Split('/')[0]
        $testPath = "$BaseUrl/msys/x86_64/msys.db"  # ~500KB test file
        try {
            # Step 1: TCP connect to filter unreachable mirrors
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $tcp = New-Object System.Net.Sockets.TcpClient
            $conn = $tcp.BeginConnect($hostname, 443, $null, $null)
            if (-not $conn.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec), $false)) {
                $tcp.Close()
                return $null
            }
            $tcp.EndConnect($conn)
            $tcp.Close()
            $tcpMs = $sw.ElapsedMilliseconds

            # Step 2: download speed test -- fetch the db file header
            $req = [System.Net.HttpWebRequest]::Create($testPath)
            $req.Method = "GET"
            $req.Timeout = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            try {
                $resp = $req.GetResponse()
                $body = $resp.GetResponseStream()
                $buf = New-Object byte[] 40960  # read first 40KB
                $totalRead = 0
                $readSw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($totalRead -lt $buf.Length -and $readSw.ElapsedMilliseconds -lt 3000) {
                    $read = $body.Read($buf, $totalRead, $buf.Length - $totalRead)
                    if ($read -le 0) { break }
                    $totalRead += $read
                }
                $readSw.Stop()
                $body.Close()
                $resp.Close()
                $speedKbps = if ($readSw.ElapsedMilliseconds -gt 0) {
                    [Math]::Round($totalRead / 1024 / ($readSw.ElapsedMilliseconds / 1000))
                } else { 0 }
                return @{ Name = $Name; Base = $BaseUrl; TcpMs = $tcpMs; Speed = $speedKbps }
            } catch {
                # HTTP 404 or other HTTP error: mirror doesn't serve db at this path, still usable
                return @{ Name = $Name; Base = $BaseUrl; TcpMs = $tcpMs; Speed = -1 }
            }
        } catch {
            return $null
        }
    }

    $jobs = $candidates | ForEach-Object {
        Start-Job -ScriptBlock $probeScript -ArgumentList $_.Name, $_.Base, $probeTimeout
    }
    $results = $jobs | Wait-Job -Timeout $probeTimeout | Receive-Job
    $jobs | Where-Object { $_.State -eq 'Running' } | Stop-Job -PassThru | Remove-Job -Force

    # Sort: by speed (descending, with -1 (unknown) last), then by TCP ms (ascending)
    $responded = $results | Where-Object { $_ -ne $null } | Sort-Object @{E={$_.Speed};Ascending=$false}, @{E={$_.TcpMs};Ascending=$true}
    if ($responded.Count -eq 0) {
        Write-Log "Warn" "No mirrors responded, using official mirror" -NoConsole
        $fallback = $mirrors[0].Base
        Set-Msys2Mirror -BaseUrl $fallback
        $Script:_selectedMsys2Mirror = $fallback
        return $false
    }

    $winner = $responded[0]
    $speedInfo = if ($winner.Speed -ge 0) { "$($winner.Speed) KB/s" } else { "no speed test" }
    Write-Info "Selected mirror: $($winner.Name) (TCP:${($winner.TcpMs)}ms, $speedInfo) -- $($winner.Base)"
    Set-Msys2Mirror -BaseUrl $winner.Base
    $Script:_selectedMsys2Mirror = $winner.Base
    return $true
}

function Disable-UnusedRepos {
    $conf = Join-PathSafe $Script:_msys2Dir "etc\pacman.conf"
    if (-not (Test-Path $conf -PathType Leaf)) {
        Write-Log "Warn" "pacman.conf not found at $conf" -NoConsole
        return
    }
    $lines = Get-Content $conf
    $kept = @("mingw64", "msys")
    $inUnused = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]') {
            $section = $matches[1]
            $inUnused = $section -ne "options" -and $section -notin $kept
            if ($inUnused) {
                $newLines += "# $line  # disabled (unused repository)"
                continue
            }
        } elseif ($inUnused -and $line -match '^\s*(Include|Server)\s*=') {
            $newLines += "# $line  # disabled (unused repository)"
            continue
        }
        $newLines += $line
    }
    # Single download + no sig check + curl with tight timeouts
    $xferCmd = "XferCommand = /usr/bin/curl --connect-timeout 15 --max-time 300 --retry 5 --retry-delay 10 -C - -f -L -o %o %u"
    $hasParallel = $false
    $hasSigLevel = $false
    $hasXferCommand = $false
    for ($i = 0; $i -lt $newLines.Count; $i++) {
        if ($newLines[$i] -match '^ParallelDownloads\s*=') {
            $newLines[$i] = 'ParallelDownloads = 1'
            $hasParallel = $true
        }
        if ($newLines[$i] -match '^SigLevel\s*=') {
            $newLines[$i] = 'SigLevel = Never'
            $hasSigLevel = $true
        }
        if ($newLines[$i] -match '^XferCommand\s*=') {
            $newLines[$i] = $xferCmd
            $hasXferCommand = $true
        }
    }
    $optIndex = -1
    if (-not $hasParallel) {
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            if ($newLines[$i] -match '^\[options\]') {
                $newLines = $newLines[0..$i] + @('ParallelDownloads = 1') + $newLines[($i+1)..($newLines.Count-1)]
                if ($optIndex -lt 0) { $optIndex = $i + 1 }
                break
            }
        }
    }
    if ($optIndex -lt 0) {
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            if ($newLines[$i] -match '^ParallelDownloads\s*=') { $optIndex = $i; break }
        }
    }
    $insertions = @()
    if (-not $hasSigLevel) { $insertions += 'SigLevel = Never' }
    if (-not $hasXferCommand) { $insertions += $xferCmd }
    if ($insertions.Count -gt 0 -and $optIndex -ge 0) {
        $newLines = $newLines[0..$optIndex] + $insertions + $newLines[($optIndex+1)..($newLines.Count-1)]
    }
    [System.IO.File]::WriteAllText($conf, ($newLines -join "`r`n"))
    Write-Log "Debug" "Disabled unused repos in pacman.conf" -NoConsole
}

function Show-Spinner {
    param([string]$Message, [scriptblock]$ScriptBlock)
    $spinner = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    $job = Start-Job -ScriptBlock {
        param($s, $m)
        $i = 0
        while ($true) {
            Write-Host "`r $($s[$i]) $m..." -NoNewline
            Start-Sleep -Milliseconds 120
            $i = ($i + 1) % $s.Length
        }
    } -ArgumentList $spinner, $Message
    try {
        & $ScriptBlock
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -ErrorAction SilentlyContinue
        Write-Host "`r + $Message" -NoNewline
        Write-Host ""
    }
}

function Install-StartMenuShortcuts {
    $startMenuDir = Join-PathSafe $env:APPDATA "Microsoft\Windows\Start Menu\Programs\mark-dawn"
    Ensure-Directory $startMenuDir

    try {
        $wshell = New-Object -ComObject WScript.Shell

        $shortcuts = @(
            @{ Name = "Start Watcher";    Args = "start" }
            @{ Name = "Stop Watcher";     Args = "stop" }
            @{ Name = "View Logs";        Args = "logs" }
            @{ Name = "Update";           Args = "update" }
        )

        foreach ($s in $shortcuts) {
            $lnk = $wshell.CreateShortcut("$startMenuDir\$($s.Name).lnk")
            $lnk.TargetPath = "powershell.exe"
            $lnk.Arguments = "-WindowStyle Hidden -Command `"Start-Process '$($Script:_launcherPath)' -ArgumentList '$($s.Args)' -WindowStyle Hidden`""
            $lnk.WorkingDirectory = $Script:_installDir
            $lnk.Description = "mark-dawn: $($s.Name)"
            $lnk.Save()
        }

        # Uninstall shortcut
        $psPath = Join-PathSafe $Script:_installDir "mark-dawn.ps1"
        if (Test-Path $psPath -PathType Leaf) {
            $lnk = $wshell.CreateShortcut("$startMenuDir\Uninstall.lnk")
            $lnk.TargetPath = "powershell.exe"
            $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$psPath`" -Uninstall"
            $lnk.WorkingDirectory = $Script:_installDir
            $lnk.Description = "mark-dawn: Uninstall"
            $lnk.Save()
        }

        Write-OK "Start Menu shortcuts created"
    } catch {
        Write-Log "Warn" "Could not create Start Menu shortcuts: $_" -NoConsole
    }
}

