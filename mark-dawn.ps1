<#
.SYNOPSIS
    mark-dawn portable installer for Windows (Option B)
.DESCRIPTION
    Installs mark-dawn - a universal document-to-Markdown pipeline - as a fully
    portable application on Windows 10/11 x64.  No WSL, no containers, no
    administrator rights required (except for Task Scheduler auto-start).

    Architecture: Python.org embedded distribution + pip for Python packages,
    MSYS2 only for system tool binaries (tesseract, ghostscript, qpdf).

    Data directories match the Linux convention so the workflow is identical:
      %USERPROFILE%\Documents\Inbox         Drop files here
      %USERPROFILE%\Documents\Research      Converted .md files appear here
      %USERPROFILE%\Documents\Inbox_Failed  Failed conversions land here

    SHA256-verified downloads, idempotent execution, structured logging.

.NOTES
    Version  : 2.0.0
    Author   : kirijin
    Requires : Windows 10/11 x64, PowerShell 5.1+
#>

param(
    [string]$InstallDir = "",
    [string]$DataDir = "",
    [string]$Msys2Mirror = "",
    [string]$PypiMirror = "",
    [switch]$SkipInit,
    [switch]$ForceRedownload,
    [switch]$SkipVerification,
    [int]$MaxRetries = 3,
    [int]$TimeoutSec = 300,
    [ValidateSet("Debug", "Info", "Warn", "Error")]
    [string]$LogLevel = "Info",
    [switch]$Help,
    [switch]$Uninstall
)

# ============================================================================
# CONFIGURATION - pinned artifacts with SHA256 verification
# ============================================================================

# Python.org embedded distribution (no installer needed, just unzip)
$Script:PYTHON_VERSION = "3.12.4"
$Script:PYTHON_URL     = "https://www.python.org/ftp/python/$($Script:PYTHON_VERSION)/python-$($Script:PYTHON_VERSION)-embed-amd64.zip"
$Script:PYTHON_SHA256  = "15fea3c9367653a85086fe37216b4d1a1c78688fa5e1587e1db0b0f658856564"
$Script:PYTHON_FALLBACK_URLS = @(
    "https://www.python.org/ftp/python/$($Script:PYTHON_VERSION)/python-$($Script:PYTHON_VERSION)-embed-amd64.zip"
    "https://mirrors.tuna.tsinghua.edu.cn/python/$($Script:PYTHON_VERSION)/python-$($Script:PYTHON_VERSION)-embed-amd64.zip"
    "https://repo.huaweicloud.com/python/$($Script:PYTHON_VERSION)/python-$($Script:PYTHON_VERSION)-embed-amd64.zip"
)

# get-pip.py for bootstrapping pip into embedded Python
$Script:GETPIP_URL     = "https://bootstrap.pypa.io/get-pip.py"
$Script:GETPIP_SHA256  = "a341e1a43e38001c551a1508a73ff23636a11970b61d901d9a1cad2a18f57055"
$Script:GETPIP_FALLBACK_URLS = @(
    "https://bootstrap.pypa.io/get-pip.py"
    "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/get-pip.py"
    "https://mirrors.ustc.edu.cn/pypi/web/get-pip.py"
    "https://mirrors.aliyun.com/pypi/get-pip.py"
)

# MSYS2 - base system SFX for tool extraction only
$Script:MSYS2_VERSION  = "2026-06-11"
$Script:MSYS2_URL      = "https://github.com/msys2/msys2-installer/releases/download/$($Script:MSYS2_VERSION)/msys2-base-x86_64-$($Script:MSYS2_VERSION.Replace('-','')).sfx.exe"
$Script:MSYS2_SHA256   = "c105946e64e08f099ac0e4647461ce762b95333ad211777666476a9a41451d65"

# MSYS2 tool packages to install via pacman (no Python packages!)
$Script:MSYS2_TOOL_PACKAGES = @(
    "mingw-w64-x86_64-tesseract-ocr"
    "mingw-w64-x86_64-ghostscript"
    "mingw-w64-x86_64-qpdf"
)

# MSYS2 mirrors -- probed in order during Select-FastestMirror
$Script:MSYS2_MIRRORS = @(
    @{ Name = "Official";  Base = "https://mirror.msys2.org" }
    @{ Name = "Yandex";    Base = "https://mirror.yandex.ru/msys2" }
    @{ Name = "USTC";      Base = "https://mirrors.ustc.edu.cn/msys2" }
    @{ Name = "Tsinghua";  Base = "https://mirrors.tuna.tsinghua.edu.cn/msys2" }
    @{ Name = "Aliyun";    Base = "https://mirrors.aliyun.com/msys2" }
    @{ Name = "Selfnet";   Base = "https://mirror.selfnet.de/msys2" }
    @{ Name = "FAU";       Base = "https://ftp.fau.de/msys2" }
)

# Tesseract language models (6 languages)
$Script:TESSDATA_BASE_URL  = "https://github.com/tesseract-ocr/tessdata/raw/main"
$Script:TESSDATA_MIRROR_URL = "https://cdn.jsdelivr.net/gh/tesseract-ocr/tessdata@main"
$Script:TESSDATA_LANGS    = @("eng", "rus", "fra", "deu", "chi_sim", "jpn")
$Script:TESSDATA_SHA256   = @{
    "eng"     = "daa0c97d651c19fba3b25e81317cd697e9908c8208090c94c3905381c23fc047"
    "rus"     = "681be2c2bead1bc7bd235df88c44e8e60ae73ae866840c0ad4e3b4c247bd37c2"
    "fra"     = "eac01c1d72540d6090facb7b2f42dd0a2ee8fc57c5be1b20548ae668e2761913"
    "deu"     = "896b3b4956503ab9daa10285db330881b2d74b70d889b79262cc534b9ec699a4"
    "chi_sim" = "fc05d89ab31d8b4e226910f16a8bcbf78e43bae3e2580bb5feefd052efdab363"
    "jpn"     = "6f416b902d129d8cc28e99c33244034b1cf52549e8560f6320b06d317852159a"
}
$Script:TESSDATA_MIN_SIZE = 1MB

# Python packages to install via pip (from PyPI win_amd64 wheels)
$Script:PIP_PACKAGES = @(
    "pymupdf4llm"
    "markitdown"
    "ocrmypdf"
    "python-docx"
    "openpyxl"
    "python-pptx"
    "watchdog"
)

# Default directories
$Script:DEFAULT_INSTALL_DIR = [System.IO.Path]::Combine($env:USERPROFILE, "mark-dawn")
$Script:DEFAULT_DATA_DIR    = [System.IO.Path]::Combine($env:USERPROFILE, "Documents")

# ============================================================================
# INTERNAL STATE (set after parameter resolution)
# ============================================================================
$Script:_installDir     = ""
$Script:_dataDir        = ""
$Script:_pythonDir      = ""
$Script:_msys2Dir       = ""
$Script:_scriptsDir     = ""
$Script:_logsDir        = ""
$Script:_tessdataDir    = ""
$Script:_launcherPath   = ""
$Script:_pidFile        = ""
$Script:_logFile        = ""
$Script:_installLog     = ""
$Script:_stateFile      = ""
$Script:_pythonExe      = ""
$Script:_installVersion = "2.2.0"
$Script:_logLevelNum    = 1  # 0=Debug 1=Info 2=Warn 3=Error
$Script:msys2InstallerPath = ""
$Script:_selectedMsys2Mirror = ""
$Script:_msys2MirrorOverride = ""
$Script:_failedMsys2Mirrors = @()
$Script:_pypiMirror = ""

# ============================================================================
# LOGGING HELPERS
# ============================================================================
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

# ============================================================================
# PATH HELPERS
# ============================================================================
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

# ============================================================================
# CHECKSUM HELPERS
# ============================================================================
function Test-Sha256 {
    param([string]$FilePath, [string]$ExpectedHash)
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

# ============================================================================
# NETWORK HELPERS
# ============================================================================
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

# ============================================================================
# STATE MANAGEMENT (idempotency via JSON state file)
# ============================================================================
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

# ============================================================================
# ADMIN HELPERS
# ============================================================================
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

# ============================================================================
# PYTHON HELPERS
# ============================================================================
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

# ============================================================================
# MSYS2 HELPERS
# ============================================================================
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
    $env:MSYSTEM = "MINGW64"
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
    }
}

# ============================================================================
# MSYS2 MIRROR HELPERS
# ============================================================================
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

# ============================================================================
# INSTALLATION STEP FUNCTIONS
# ============================================================================
function Step-Init {
    Write-Step "0/14" "Resolving paths and creating directories..."

    if (-not $Script:_installDir) { $Script:_installDir = $Script:DEFAULT_INSTALL_DIR }
    if (-not $Script:_dataDir) { $Script:_dataDir = $Script:DEFAULT_DATA_DIR }

    try {
        $resolved = Resolve-Path $Script:_installDir -ErrorAction SilentlyContinue
        if ($resolved) { $Script:_installDir = $resolved.Path }
    } catch {}

    try {
        $resolved = Resolve-Path $Script:_dataDir -ErrorAction SilentlyContinue
        if ($resolved) { $Script:_dataDir = $resolved.Path }
    } catch {}

    $null = Assert-PathSafe $Script:_installDir
    $null = Assert-PathSafe $Script:_dataDir

    $Script:_pythonDir     = Join-PathSafe $Script:_installDir "python"
    $Script:_msys2Dir      = Join-PathSafe $Script:_installDir ".msys2"
    $Script:_scriptsDir    = Join-PathSafe $Script:_installDir "scripts"
    $Script:_logsDir       = Join-PathSafe $Script:_installDir "logs"
    $Script:_tessdataDir   = Join-PathSafe $Script:_installDir "tessdata"
    $Script:_launcherPath  = Join-PathSafe $Script:_installDir "mark-dawn.bat"
    $Script:_pidFile       = Join-PathSafe $Script:_installDir "mark-dawn.pid"
    $Script:_logFile       = Join-PathSafe $Script:_logsDir "mark-dawn.log"
    $Script:_stateFile     = Join-PathSafe $Script:_installDir ".install-state.json"
    $Script:_pythonExe     = Join-PathSafe $Script:_pythonDir "python.exe"

    try {
        Ensure-Directory $Script:_installDir
        Ensure-Directory (Join-PathSafe $Script:_dataDir "Inbox")
        Ensure-Directory (Join-PathSafe $Script:_dataDir "Research")
        Ensure-Directory (Join-PathSafe $Script:_dataDir "Inbox_Failed")
        Ensure-Directory $Script:_logsDir

        $testFile = Join-PathSafe $Script:_installDir ".write-test"
        "test" | Out-File -FilePath $testFile -Encoding ascii -Force -ErrorAction Stop
        Remove-Item -Path $testFile -Force -ErrorAction Stop
    } catch {
        Write-Fail "Cannot write to '$Script:_installDir'. Check permissions: $_"
    }

    $Script:_installLog = Join-PathSafe $Script:_logsDir "install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    try {
        "=== mark-dawn installer v$($Script:_installVersion) ===" | Out-File -FilePath $Script:_installLog -Encoding utf8 -Force
        "Started: $(Get-Date -Format 'o')" | Out-File -FilePath $Script:_installLog -Append -Encoding utf8
        "InstallDir: $($Script:_installDir)" | Out-File -FilePath $Script:_installLog -Append -Encoding utf8
        "DataDir: $($Script:_dataDir)" | Out-File -FilePath $Script:_installLog -Append -Encoding utf8
    } catch {}

    Write-OK "Install directory: $($Script:_installDir)"
    Write-OK "Data directory: $($Script:_dataDir)"
    Write-Log "Info" "Install log: $($Script:_installLog)"
    Set-InstallState -Step "init" -Status "ok"
}

function Step-DownloadPython {
    Write-Step "1/14" "Downloading Python $($Script:PYTHON_VERSION) embedded distribution (~11 MB)..."
    $tempDir = Join-PathSafe $env:TEMP "mark-dawn-installer"
    Ensure-Directory $tempDir
    $pythonZip = Join-PathSafe $tempDir "python-embed.zip"

    $lastError = $null
    foreach ($url in $Script:PYTHON_FALLBACK_URLS) {
        try {
            Invoke-DownloadWithRetry -Url $url -OutFile $pythonZip `
                -MaxRetries 2 -TimeoutSec 600 `
                -ExpectedHash $Script:PYTHON_SHA256 -Force:$Script:ForceRedownload
            $lastError = $null
            break
        } catch {
            $lastError = $_
            Write-Log "Warn" "Python download from $url failed, trying next mirror" -NoConsole
            Remove-Item $pythonZip -Force -ErrorAction SilentlyContinue
            Remove-Item "$pythonZip.tmp" -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lastError) { Write-Fail "Failed to download Python: $lastError" }

    $Script:pythonZipPath = $pythonZip
    Write-OK "Python embedded zip ready (SHA256 verified)"
    Set-InstallState -Step "python_downloaded" -Status "ok"
}

function Step-DownloadGetPip {
    Write-Step "2/14" "Downloading get-pip.py..."
    $tempDir = Join-PathSafe $env:TEMP "mark-dawn-installer"
    Ensure-Directory $tempDir
    $getPipPath = Join-PathSafe $tempDir "get-pip.py"

    $lastError = $null
    foreach ($url in $Script:GETPIP_FALLBACK_URLS) {
        try {
            Invoke-DownloadWithRetry -Url $url -OutFile $getPipPath `
                -MaxRetries 2 -TimeoutSec 600 `
                -ExpectedHash $Script:GETPIP_SHA256 -Force:$Script:ForceRedownload
            $lastError = $null
            break
        } catch {
            $lastError = $_
            Write-Log "Warn" "get-pip.py from $url failed, trying next mirror" -NoConsole
            Remove-Item $getPipPath -Force -ErrorAction SilentlyContinue
            Remove-Item "$getPipPath.tmp" -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lastError) { Write-Fail "Failed to download get-pip.py: $lastError" }

    $Script:getPipPath = $getPipPath
    Write-OK "get-pip.py ready (SHA256 verified)"
    Set-InstallState -Step "getpip_downloaded" -Status "ok"
}

function Step-ExtractPython {
    Write-Step "3/14" "Extracting Python $($Script:PYTHON_VERSION) embedded..."

    $pythonExeCheck = Join-PathSafe $Script:_pythonDir "python.exe"
    if (-not (Test-Path $pythonExeCheck -PathType Leaf) -or $Script:ForceRedownload) {
        Remove-DirectorySafe $Script:_pythonDir -Force
        Ensure-Directory $Script:_pythonDir

        Expand-Archive -Path $Script:pythonZipPath -DestinationPath $Script:_pythonDir -Force -ErrorAction Stop

        if (-not (Test-Path $pythonExeCheck -PathType Leaf)) {
            throw "python.exe not found after extraction"
        }
    } else {
        Write-OK "Python already extracted, skipping re-extraction"
    }

    # Always patch python312._pth (BOM-free write, runs even on re-run)
    try {
        $pthFile = Join-PathSafe $Script:_pythonDir "python312._pth"
        if (Test-Path $pthFile -PathType Leaf) {
            $pthContent = Get-Content -Path $pthFile -Raw -Encoding utf8
            $pthContent = $pthContent -replace '#import site', 'import site'
            [System.IO.File]::WriteAllText($pthFile, $pthContent)
            Write-Log "Info" "Patched python312._pth - site-packages enabled" -NoConsole
        } else {
            Write-Log "Warn" "python312._pth not found (may be different version)" -NoConsole
        }
    } catch {
        Write-Log "Warn" "Could not patch python312._pth: $_" -NoConsole
    }

    Set-InstallState -Step "python_extracted" -Status "ok"
}

function Step-InstallPip {
    Write-Step "4/14" "Installing pip into embedded Python..."

    # Ensure python312._pth is valid (BOM-free + import site uncommented)
    try {
        $pthFile = Join-PathSafe $Script:_pythonDir "python312._pth"
        if (Test-Path $pthFile -PathType Leaf) {
            $pthContent = Get-Content -Path $pthFile -Raw -Encoding utf8
            $pthContent = $pthContent -replace '#import site', 'import site'
            [System.IO.File]::WriteAllText($pthFile, $pthContent)
        }
    } catch {
        Write-Log "Warn" "Could not verify python312._pth: $_" -NoConsole
    }

    $pipCheck = Join-PathSafe $Script:_pythonDir "Scripts\pip.exe"
    if ((Test-Path $pipCheck -PathType Leaf) -and -not $Script:ForceRedownload) {
        Write-OK "pip already installed, skipping"
        Set-InstallState -Step "pip_installed" -Status "ok"
        return
    }

    try {
        # Bootstrap pip into embedded Python
        Invoke-Python -ArgumentList @($Script:getPipPath, "--no-warn-script-location")

        if (-not (Test-Path $pipCheck -PathType Leaf)) {
            throw "pip.exe not found after bootstrap"
        }

        Write-OK "pip installed successfully"
        Set-InstallState -Step "pip_installed" -Status "ok"
    } catch {
        Write-Fail "pip installation failed: $_"
    }
}

function Step-InstallPythonPackages {
    Write-Step "5/14" "Installing Python packages via pip ($($Script:PIP_PACKAGES.Count) packages)..."

    try {
        $pkgList = $Script:PIP_PACKAGES -join " "
        Write-Info "Installing: $pkgList"

        $pipArgs = @("-m", "pip", "install", "--no-cache-dir") + $Script:PIP_PACKAGES
        if ($Script:_pypiMirror) {
            $pipArgs = @("-m", "pip", "install", "--no-cache-dir", "-i", $Script:_pypiMirror) + $Script:PIP_PACKAGES
        }
        $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList $pipArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "pip install failed (exit $($proc.ExitCode))"
        }

        # Verify imports via temp script (avoids -c quoting issues on PS5.1)
        Write-Info "Verifying Python packages..."
        $verifyScript = Join-PathSafe $env:TEMP "mark-dawn-verify-imports.py"
        $verifyCode = @'
import sys, importlib
modules = ["pymupdf4llm", "markitdown", "watchdog"]
all_ok = True
for mod in modules:
    try:
        importlib.import_module(mod)
        print(f"{mod}: ok")
    except Exception as e:
        print(f"{mod}: FAIL - {e}")
        all_ok = False
sys.exit(0 if all_ok else 1)
'@
        [System.IO.File]::WriteAllText($verifyScript, $verifyCode)
        $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList @($verifyScript) -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "Import verification failed"
        }
        Remove-Item $verifyScript -Force -ErrorAction SilentlyContinue

        Write-OK "Python packages installed and verified"
        Set-InstallState -Step "python_packages_installed" -Status "ok"
    } catch {
        Write-Fail "Failed to install Python packages: $_"
    }
}

function Step-DownloadMsys2 {
    Write-Step "6/14" "Downloading MSYS2 base system SFX (~50 MB)..."
    $tempDir = Join-PathSafe $env:TEMP "mark-dawn-installer"
    Ensure-Directory $tempDir
    $installerPath = Join-PathSafe $tempDir "msys2-sfx.exe"
    $sfxFile = "msys2-base-x86_64-$($Script:MSYS2_VERSION.Replace('-','')).sfx.exe"

    # Check cache first
    if (-not $Script:ForceRedownload -and (Test-Path $installerPath -PathType Leaf)) {
        if (Test-Sha256 -FilePath $installerPath -ExpectedHash $Script:MSYS2_SHA256) {
            Write-OK "MSYS2 SFX already cached (SHA256 OK)"
            $Script:msys2InstallerPath = $installerPath
            Set-InstallState -Step "msys2_downloaded" -Status "ok"
            return
        }
        Write-Log "Warn" "Cached SFX hash mismatch, re-downloading" -NoConsole
    }

    # Build fallback URL list: mirrors first (works without VPN), then GitHub
    $urls = @()
    foreach ($m in $Script:MSYS2_MIRRORS) {
        $urls += "$($m.Base)/distrib/x86_64/$sfxFile"
    }
    $urls += $Script:MSYS2_URL

    $lastError = $null
    foreach ($url in $urls) {
        try {
            Invoke-DownloadWithRetry -Url $url -OutFile $installerPath `
                -MaxRetries 2 -TimeoutSec 600 `
                -ExpectedHash $Script:MSYS2_SHA256
            $lastError = $null
            break
        } catch {
            $lastError = $_
            Write-Log "Warn" "Failed to download from $url, trying next mirror" -NoConsole
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            Remove-Item "$installerPath.tmp" -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lastError) { Write-Fail "All download URLs failed for MSYS2 SFX: $lastError" }

    $Script:msys2InstallerPath = $installerPath
    Write-OK "MSYS2 SFX ready (SHA256 verified)"
    Set-InstallState -Step "msys2_downloaded" -Status "ok"
}

function Step-ExtractMsys2 {
    Write-Step "7/14" "Extracting MSYS2 base system..."

    $bashCheck = Join-PathSafe $Script:_msys2Dir "usr\bin\bash.exe"

    if ((Test-Path $bashCheck -PathType Leaf) -and -not $Script:ForceRedownload) {
        Write-OK "MSYS2 already extracted, skipping"
        Set-InstallState -Step "msys2_extracted" -Status "ok"
        return
    }

    # Remove old directory, then extract SFX directly to .msys2
    Remove-DirectorySafe $Script:_msys2Dir -Force
    Ensure-Directory $Script:_msys2Dir

    try {
        Write-Log "Info" "Extracting SFX to: $Script:_msys2Dir" -NoConsole

        $proc = Start-Process -FilePath $Script:msys2InstallerPath `
            -ArgumentList "-y", "-o`"$Script:_msys2Dir`"" `
            -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -ne 0) {
            throw "Extractor exited with code $($proc.ExitCode)"
        }

        # Handle subdirectory structure: some SFX versions create a subfolder
        $extractedRoot = $Script:_msys2Dir
        $subFound = $false
        foreach ($sub in @("msys2", "msys64")) {
            $candidate = Join-PathSafe $Script:_msys2Dir $sub
            if (Test-Path (Join-PathSafe $candidate "usr\bin\bash.exe") -PathType Leaf) {
                Write-Log "Info" "SFX extracted into '$sub' subdirectory, flattening..." -NoConsole
                $children = Get-ChildItem $candidate -Force
                foreach ($child in $children) {
                    $destName = Split-Path $child.FullName -Leaf
                    $dest = Join-PathSafe $Script:_msys2Dir $destName
                    # Move-Item can fail if dest exists (e.g. the $sub dir itself)
                    Move-Item -Path $child.FullName -Destination $dest -Force -ErrorAction Stop
                }
                Remove-Item $candidate -Force -Recurse -ErrorAction SilentlyContinue
                $subFound = $true
                break
            }
        }

        # Verify critical files exist in the final location
        if (-not (Test-Path $bashCheck -PathType Leaf)) {
            throw "bash.exe not found after extraction"
        }
        $dllCount = @(Get-ChildItem (Join-PathSafe $Script:_msys2Dir "usr\bin\*.dll") -ErrorAction SilentlyContinue).Count
        if ($dllCount -eq 0) {
            throw "No DLLs found in usr/bin/ after extraction (corrupted SFX)"
        }

        Write-OK "MSYS2 extracted to $($Script:_msys2Dir)"
        Set-InstallState -Step "msys2_extracted" -Status "ok"
    } catch {
        Remove-DirectorySafe $Script:_msys2Dir -Force
        Write-Fail "MSYS2 extraction failed: $_"
    }
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
        } elseif ($inUnused -and $line -match '^\s*(Include|Server)\s*=') {
            $newLines += "# $line  # disabled (unused repository)"
            continue
        }
        $newLines += $line
    }
    # Force single download + timeout/retry for unstable connections
    $hasParallel = $false
    $hasSigLevel = $false
    $hasConnectTimeout = $false
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
        if ($newLines[$i] -match '^ConnectTimeout\s*=') {
            $newLines[$i] = 'ConnectTimeout = 15'
            $hasConnectTimeout = $true
        }
        if ($newLines[$i] -match '^XferCommand\s*=') {
            $newLines[$i] = "XferCommand = /usr/bin/curl --connect-timeout 10 --max-time 300 --retry 2 --retry-delay 3 -C - -f -L -o %o %u"
            $hasXferCommand = $true
        }
    }
    if (-not $hasParallel) {
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            if ($newLines[$i] -match '^\[options\]') {
                $newLines = $newLines[0..$i] + @('ParallelDownloads = 1') + $newLines[($i+1)..($newLines.Count-1)]
                break
            }
        }
    }
    # Insert missing options after ParallelDownloads
    $optIndex = -1
    for ($i = 0; $i -lt $newLines.Count; $i++) {
        if ($newLines[$i] -match '^ParallelDownloads\s*=') { $optIndex = $i; break }
    }
    $insertions = @()
    if (-not $hasSigLevel) { $insertions += 'SigLevel = Never' }
    if (-not $hasConnectTimeout) { $insertions += 'ConnectTimeout = 15' }
    if (-not $hasXferCommand) { $insertions += "XferCommand = /usr/bin/curl --connect-timeout 10 --max-time 300 --retry 2 --retry-delay 3 -C - -f -L -o %o %u" }
    if ($insertions.Count -gt 0) {
        $newLines = $newLines[0..$optIndex] + $insertions + $newLines[($optIndex+1)..($newLines.Count-1)]
    }
    [System.IO.File]::WriteAllText($conf, ($newLines -join "`r`n"))
    Write-Log "Debug" "Disabled unused repos in pacman.conf" -NoConsole
}

function Step-InitMsys2 {
    Write-Step "8/14" "Initializing MSYS2 pacman keyring (2-3 minutes)..."

    if ($Script:SkipInit) {
        Write-Info "Skipping MSYS2 initialization (-SkipInit)"
        if (Test-StepCompleted "msys2_initialized") {
            Write-OK "MSYS2 previously initialized"
        }
        Set-InstallState -Step "msys2_initialized" -Status "ok"
        return
    }

    $pacmanDb = Join-PathSafe $Script:_msys2Dir "var\lib\pacman\local"
    $alpmDb = Join-PathSafe $pacmanDb "ALPM_DB_VERSION"
    $gpgDir = Join-PathSafe $Script:_msys2Dir "etc\pacman.d\gnupg"
    $gpgExe = Join-PathSafe $Script:_msys2Dir "usr\bin\gpg.exe"

    # Fully initialized check
    if ((Test-Path $alpmDb -PathType Leaf) -and -not $Script:ForceRedownload) {
        Write-OK "MSYS2 already initialized, skipping"
        Set-InstallState -Step "msys2_initialized" -Status "ok"
        return
    }

    # Detect corrupt or partial MSYS2 by checking key binaries
    $missing = @()
    $usrBin = Join-PathSafe $Script:_msys2Dir "usr\bin"
    if (-not (Test-Path (Join-PathSafe $usrBin "bash.exe") -PathType Leaf)) { $missing += "usr/bin/bash.exe" }
    $dlls = @(Get-ChildItem (Join-PathSafe $usrBin "*.dll") -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) { $missing += "usr/bin/*.dll (no DLLs at all)" }
    if ($missing.Count -gt 0) {
        $dllList = $dlls | ForEach-Object { $_.Name } | Sort-Object
        Write-Log "Warn" "DLLs found in usr/bin: $($dllList -join ', ')" -NoConsole
        Write-Log "Warn" "Contents of usr/bin: $(Get-ChildItem $usrBin -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })" -NoConsole
        Write-Fail "MSYS2 installation corrupt (missing: $($missing -join ', ')). The SFX download may have returned a wrong file. Please re-run with -ForceRedownload -Msys2Mirror https://mirror.yandex.ru/msys2 to force a specific mirror."
    }

    $keyringExists = (Test-Path $gpgDir -PathType Container)

    try {
        if (-not $keyringExists) {
            Write-Info "Initializing pacman keyring..."
            Invoke-Msys2Bash -Msys2Dir $Script:_msys2Dir -Command "pacman-key --init 2>&1"

            Write-Info "Populating keyring..."
            Invoke-Msys2Bash -Msys2Dir $Script:_msys2Dir -Command "pacman-key --populate msys2 mingw64 2>&1"
        } else {
            Write-Info "Keyring already exists, skipping init"
        }

        # Ensure local database directory exists before sync
        Ensure-Directory $pacmanDb

        Write-Info "Selecting fastest mirror..."
        Select-FastestMirror

        Write-Info "Disabling unused repositories..."
        Disable-UnusedRepos

        Write-Info "Updating package databases..."
        Invoke-Msys2Bash -Msys2Dir $Script:_msys2Dir -Command "pacman -Sy --noconfirm --disable-download-timeout 2>&1"

        Write-OK "MSYS2 initialized"
        Set-InstallState -Step "msys2_initialized" -Status "ok"
    } catch {
        Write-Fail "MSYS2 initialization failed: $_"
    }
}

function Step-InstallMsys2Tools {
    Write-Step "9/14" "Installing system tools via pacman (tesseract, ghostscript, qpdf)..."

    try {
        $pkgList = $Script:MSYS2_TOOL_PACKAGES -join " "
        Write-Info "Installing packages: $pkgList"

        # Persistent pacman cache dir so retries only fetch missing packages
        $cacheDir = Join-PathSafe $Script:_installDir ".pacman-cache"
        Ensure-Directory $cacheDir
        # Convert Windows path to MSYS2 path: C:\foo\bar -> /c/foo/bar
        $cachePath = "/" + ($cacheDir[0]).ToString().ToLower() + $cacheDir.Substring(2) -replace '\\', '/'

        $lastError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # Select fastest mirror (re-probes all mirrors if previous attempt failed)
                if ($attempt -gt 1) { $Script:_selectedMsys2Mirror = "" }
                Select-FastestMirror | Out-Null
                Disable-UnusedRepos

                # Also refresh package databases before tool install
                Invoke-Msys2Bash -Msys2Dir $Script:_msys2Dir -Command @"
mkdir -p "$cachePath"
pacman -Sy --noconfirm --disable-download-timeout 2>&1
pacman -S --noconfirm --needed --disable-download-timeout \
    --cachedir "$cachePath" \
    $pkgList 2>&1
"@ -ExpectedExitCodes @(0)
                $lastError = $null
                break
            } catch {
                $lastError = $_
                if ($Script:_selectedMsys2Mirror) {
                    $Script:_failedMsys2Mirrors += $Script:_selectedMsys2Mirror
                    Write-Log "Info" "Blacklisting mirror: $Script:_selectedMsys2Mirror" -NoConsole
                }
                $Script:_selectedMsys2Mirror = ""
                if ($attempt -ge 3) { throw }
                Write-Log "Info" "pacman attempt $attempt/3 failed, retrying in 5s..." -NoConsole
                Start-Sleep -Seconds 5
            }
        }
        if ($lastError) { throw $lastError }

        # Verify critical binaries exist
        $checks = @(
            @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\tesseract.exe"; Name = "tesseract" }
            @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\gs.exe";         Name = "ghostscript" }
            @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\qpdf.exe";       Name = "qpdf" }
        )
        $missing = @()
        foreach ($check in $checks) {
            if (-not (Test-Path $check.Path -PathType Leaf)) {
                $missing += $check.Name
            }
        }
        if ($missing.Count -gt 0) {
            throw "Tool binaries missing after install: $($missing -join ', ')"
        }

        Write-OK "System tools installed"
        Set-InstallState -Step "msys2_tools_installed" -Status "ok"
    } catch {
        Write-Fail "Failed to install system tools: $_"
    }
}

function Step-DownloadTessdata {
    Write-Step "10/14" "Downloading language models ($($Script:TESSDATA_LANGS.Count) languages)..."

    Ensure-Directory $Script:_tessdataDir

    $failed = @()
    $succeeded = @()
    $allLangs = $Script:TESSDATA_LANGS
    $minSize = $Script:TESSDATA_MIN_SIZE

    # Determine which languages need downloading (skip cached + valid)
    $pending = @()
    foreach ($lang in $allLangs) {
        $dest = Join-PathSafe $Script:_tessdataDir "$lang.traineddata"
        $expectedHash = $Script:TESSDATA_SHA256[$lang]
        if ((Test-Path $dest -PathType Leaf) -and -not $Script:ForceRedownload) {
            if ($Script:SkipVerification -or (Test-Sha256 -FilePath $dest -ExpectedHash $expectedHash)) {
                $succeeded += $lang
                Write-Log "Debug" "Language model '$lang' already valid, skipping" -NoConsole
                continue
            } else {
                Write-Log "Warn" "Language model '$lang' hash mismatch, re-downloading" -NoConsole
            }
        }
        $tessdataLangUrl = "$($Script:TESSDATA_BASE_URL)/$lang.traineddata"
        $tessdataMirrorUrl = "$($Script:TESSDATA_MIRROR_URL)/$lang.traineddata"
        $pending += @{ Lang = $lang; Dest = $dest; Url = $tessdataMirrorUrl; FallbackUrl = $tessdataLangUrl; Hash = $expectedHash }
    }

    if ($pending.Count -eq 0) {
        Write-OK "Language models ready: $($succeeded -join ', ')"
        Write-Log "Debug" "No tessdata downloads needed" -NoConsole
    } else {
        Write-Info "Downloading $($pending.Count) language models in parallel..."
        $jobScript = {
            param($Lang, $Dest, $PrimaryUrl, $FallbackUrl, $ExpectedHash, $MinSize, $TimeoutSec, $MaxRetries)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $urls = @($PrimaryUrl) + @($FallbackUrl)
            $tempFile = "$Dest.tmp"
            foreach ($url in $urls) {
                for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
                    try {
                        Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -ErrorAction Stop -TimeoutSec $TimeoutSec
                        $info = Get-Item $tempFile -ErrorAction Stop
                        if ($info.Length -lt $MinSize) { throw "File too small ($($info.Length) bytes)" }
                        if ($ExpectedHash) {
                            $actualHash = (Get-FileHash $tempFile -Algorithm SHA256).Hash.ToLower()
                            if ($actualHash -ne $ExpectedHash) { throw "SHA256 hash mismatch" }
                        }
                        if (Test-Path $Dest -PathType Leaf) { Remove-Item $Dest -Force }
                        Rename-Item $tempFile -NewName (Split-Path $Dest -Leaf) -ErrorAction Stop
                        return @{ Lang = $Lang; Success = $true }
                    } catch {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                        if ($attempt -ge $MaxRetries) {
                            break
                        }
                        Start-Sleep -Seconds ([Math]::Min(5 * $attempt, 30))
                    }
                }
            }
            return @{ Lang = $Lang; Success = $false; Error = "All URLs failed: $_" }
        }
        $jobs = @()
        foreach ($p in $pending) {
            $jobs += Start-Job -ScriptBlock $jobScript -ArgumentList @(
                $p.Lang, $p.Dest, $p.Url, $p.FallbackUrl, $p.Hash, $minSize,
                $Script:TimeoutSec, $Script:MaxRetries
            )
        }
        $results = $jobs | Wait-Job | Receive-Job
        foreach ($r in $results) {
            if ($r.Success) { $succeeded += $r.Lang }
            else { $failed += $r.Lang; Write-Log "Warn" "Failed to download '$($r.Lang)': $($r.Error)" -NoConsole }
        }
    }

    if ($succeeded.Count -gt 0) {
        Write-OK "Language models ready: $($succeeded -join ', ')"
    }
    if ($failed.Count -gt 0) {
        Write-Host "WARNING: Failed to download: $($failed -join ', ')" -ForegroundColor Yellow
        Write-Log "Warn" "Failed to download language models: $($failed -join ', ')"
    }

    # Copy tesseract config files from MSYS2 (needed for PDF/TXT output modes)
    $msys2Configs = Join-PathSafe $Script:_msys2Dir "mingw64\share\tessdata\configs"
    $ourConfigs = Join-PathSafe $Script:_tessdataDir "configs"
    if (Test-Path $msys2Configs -PathType Container) {
        Ensure-Directory $ourConfigs
        Copy-Item -Path "$msys2Configs\*" -Destination $ourConfigs -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log "Debug" "Copied tesseract config files to: $ourConfigs" -NoConsole
    }

    Set-InstallState -Step "tessdata_downloaded" -Status "ok"
}

function Step-GenerateScripts {
    Write-Step "11/14" "Generating Python scripts..."

    Ensure-Directory $Script:_scriptsDir

    $watcherPath = Join-PathSafe $Script:_scriptsDir "watcher.py"
    $convertPath = Join-PathSafe $Script:_scriptsDir "convert_pdf.py"

    try {
        $watcherContent = Get-WatcherScript
        $watcherContent | Out-File -FilePath $watcherPath -Encoding utf8 -Force -ErrorAction Stop

        $convertContent = Get-ConvertScript
        $convertContent | Out-File -FilePath $convertPath -Encoding utf8 -Force -ErrorAction Stop

        # Verify scripts with Python syntax check
        if (Test-Path $Script:_pythonExe -PathType Leaf) {
            $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList @("-m", "py_compile", $watcherPath) -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) { Write-Log "Warn" "watcher.py syntax check failed" -NoConsole }

            $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList @("-m", "py_compile", $convertPath) -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) { Write-Log "Warn" "convert_pdf.py syntax check failed" -NoConsole }
        }

        Write-OK "Python scripts generated"
        Set-InstallState -Step "scripts_generated" -Status "ok"
    } catch {
        Write-Fail "Failed to generate Python scripts: $_"
    }
}

function Step-GenerateLauncher {
    Write-Step "12/14" "Generating mark-dawn.bat launcher..."

    try {
        $launcherContent = Get-LauncherScript
        $launcherContent | Out-File -FilePath $Script:_launcherPath -Encoding ascii -Force -ErrorAction Stop

        $fileInfo = Get-Item $Script:_launcherPath
        if ($fileInfo.Length -lt 2000) {
            throw "Launcher file too small ($($fileInfo.Length) bytes)"
        }

        Write-OK "Launcher generated: $($Script:_launcherPath)"
        Set-InstallState -Step "launcher_generated" -Status "ok"
    } catch {
        Write-Fail "Failed to generate launcher: $_"
    }
}

function Step-Verify {
    Write-Step "13/14" "Verifying installation..."

    $failures = @()

    # Check critical binaries
    $checks = @(
        @{ Path = $Script:_pythonExe;                                Name = "python.exe" }
        @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\tesseract.exe"; Name = "tesseract" }
        @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\gs.exe";      Name = "ghostscript" }
        @{ Path = Join-PathSafe $Script:_launcherPath;               Name = "mark-dawn.bat" }
    )
    foreach ($check in $checks) {
        if (-not (Test-Path $check.Path -PathType Leaf)) {
            $failures += "Missing: $($check.Name) at $($check.Path)"
        }
    }

    # Validate tessdata
    foreach ($lang in $Script:TESSDATA_LANGS) {
        $path = Join-PathSafe $Script:_tessdataDir "$lang.traineddata"
        if (-not (Test-Path $path -PathType Leaf)) {
            $failures += "Missing language model: $lang"
        }
    }

    # Verify pip and key modules (via temp script to avoid -c quoting issues)
    if (Test-Path $Script:_pythonExe -PathType Leaf) {
        $verifyScript = Join-PathSafe $env:TEMP "mark-dawn-verify-final.py"
        $code = @"
import sys
import pymupdf4llm; print('pymupdf4llm ok')
import markitdown; print('markitdown ok')
import watchdog; print('watchdog ok')
"@
        [System.IO.File]::WriteAllText($verifyScript, $code)
        $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList @($verifyScript) -Wait -PassThru -NoNewWindow
        Remove-Item $verifyScript -Force -ErrorAction SilentlyContinue
        if ($proc.ExitCode -ne 0) {
            $failures += "Python module import failed ($($proc.ExitCode))"
        }
    } else {
        $failures += "Python not found for verification"
    }

    # Check data directories
    $dataDirs = @("Inbox", "Research", "Inbox_Failed")
    foreach ($dir in $dataDirs) {
        $path = Join-PathSafe $Script:_dataDir $dir
        if (-not (Test-Path $path -PathType Container)) {
            $failures += "Missing data directory: $dir"
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "FAILURES:" -ForegroundColor Red
        foreach ($f in $failures) {
            Write-Host "  - $f" -ForegroundColor Red
        }
        Write-Fail "Installation verification failed"
    }

    Write-OK "All checks passed"
    Set-InstallState -Step "verified" -Status "ok"
}

function Step-Complete {
    Write-Step "14/14" "Installation complete!"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " mark-dawn installed successfully" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Location:  $($Script:_installDir)" -ForegroundColor Cyan
    Write-Host "Launcher:  $($Script:_launcherPath)" -ForegroundColor Cyan
    Write-Host "Data:      $($Script:_dataDir)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Open a new Command Prompt or PowerShell window"
    Write-Host "  2. Run:  & `"$($Script:_launcherPath)`" start"
    Write-Host "  3. Drop files into: $($Script:_dataDir)\Inbox"
    Write-Host "  4. Results appear in: $($Script:_dataDir)\Research"
    Write-Host ""
    Write-Host "Management commands:" -ForegroundColor Yellow
    Write-Host "  & `"$($Script:_launcherPath)`" status"
    Write-Host "  & `"$($Script:_launcherPath)`" logs"
    Write-Host "  & `"$($Script:_launcherPath)`" stop"
    Write-Host "  & `"$($Script:_launcherPath)`" update"
    Write-Host ""
    Write-Host "Auto-start on login (requires Admin):" -ForegroundColor Yellow
    Write-Host "  & `"$($Script:_launcherPath)`" install-task"
    Write-Host ""

    Set-InstallState -Step "complete" -Status "ok"
}

# ============================================================================
# INSTALL WORKFLOW
# ============================================================================
function Invoke-Install {
    Write-Host ""
    Write-Host "=== mark-dawn installer v$($Script:_installVersion) ===" -ForegroundColor Cyan
    Write-Host "Universal Document -> Markdown Pipeline for Windows" -ForegroundColor Cyan
    Write-Host "Architecture: Python.org embedded + pip + MSYS2 tools" -ForegroundColor Cyan
    Write-Host ""

    $steps = @(
        @{ Name = "init";                    Desc = "Initialize directories";           Func = ${function:Step-Init} }
        @{ Name = "python_downloaded";       Desc = "Download Python embedded";         Func = ${function:Step-DownloadPython} }
        @{ Name = "getpip_downloaded";       Desc = "Download get-pip.py";              Func = ${function:Step-DownloadGetPip} }
        @{ Name = "python_extracted";        Desc = "Extract Python";                   Func = ${function:Step-ExtractPython} }
        @{ Name = "pip_installed";           Desc = "Install pip";                      Func = ${function:Step-InstallPip} }
        @{ Name = "python_packages_installed"; Desc = "Install Python packages";        Func = ${function:Step-InstallPythonPackages} }
        @{ Name = "msys2_downloaded";        Desc = "Download MSYS2";                   Func = ${function:Step-DownloadMsys2} }
        @{ Name = "msys2_extracted";         Desc = "Extract MSYS2";                    Func = ${function:Step-ExtractMsys2} }
        @{ Name = "msys2_initialized";       Desc = "Initialize MSYS2 keyring";         Func = ${function:Step-InitMsys2} }
        @{ Name = "msys2_tools_installed";   Desc = "Install system tools (pacman)";    Func = ${function:Step-InstallMsys2Tools} }
        @{ Name = "tessdata_downloaded";     Desc = "Download language models";         Func = ${function:Step-DownloadTessdata} }
        @{ Name = "scripts_generated";       Desc = "Generate Python scripts";          Func = ${function:Step-GenerateScripts} }
        @{ Name = "launcher_generated";      Desc = "Generate launcher";                Func = ${function:Step-GenerateLauncher} }
        @{ Name = "verified";                Desc = "Verify installation";              Func = ${function:Step-Verify} }
    )

    $totalSteps = $steps.Count
    $currentStep = 0
    $globalError = $null

    foreach ($step in $steps) {
        $currentStep++
        if (Test-StepCompleted $step.Name) {
            Write-Log "Info" "[$currentStep/$totalSteps] SKIP (already completed): $($step.Desc)" -NoConsole
            continue
        }
        try {
            & $step.Func
        } catch {
            $globalError = $_
            Set-InstallState -Step $step.Name -Status "failed" -ErrorMsg "$_"
            Write-Fail "Step '$($step.Desc)' failed: $_"
            return
        }
        Write-Log "Info" "[$currentStep/$totalSteps] COMPLETE: $($step.Desc)" -NoConsole
    }

    Step-Complete

    # Add Windows Defender exclusion for install directory
    try {
        $null = Add-MpPreference -ExclusionPath $Script:_installDir -ErrorAction SilentlyContinue
        $null = Add-MpPreference -ExclusionPath (Join-PathSafe $env:TEMP "mark-dawn-installer") -ErrorAction SilentlyContinue
        Write-Log "Debug" "Added Windows Defender exclusions" -NoConsole
    } catch {
        Write-Log "Debug" "Could not set Defender exclusion (may need Admin)" -NoConsole
    }

    # Prompt to start watcher immediately
    Write-Host ""
    $startAnswer = Read-Host "Start mark-dawn watcher now? [Y/n]"
    if ($startAnswer -eq '' -or $startAnswer -match '^[yY]') {
        try {
            $proc = Start-Process -FilePath $Script:_launcherPath -ArgumentList "start" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0) {
                Write-OK "mark-dawn watcher started"
            } else {
                Write-Log "Warn" "Launcher exited with code $($proc.ExitCode)" -NoConsole
            }
        } catch {
            Write-Log "Warn" "Failed to start watcher: $_" -NoConsole
        }
    } else {
        Write-Info "You can start it later with: & `"$($Script:_launcherPath)`" start"
    }
}

# ============================================================================
# UNINSTALL
# ============================================================================
function Invoke-Uninstall {
    Write-Host ""
    Write-Host "=== mark-dawn uninstall ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not $Script:_installDir) { $Script:_installDir = $Script:DEFAULT_INSTALL_DIR }
    if (-not $Script:_dataDir)    { $Script:_dataDir = $Script:DEFAULT_DATA_DIR }
    $Script:_launcherPath = Join-PathSafe $Script:_installDir "mark-dawn.bat"

    $launcher = $Script:_launcherPath
    if (Test-Path $launcher -PathType Leaf) {
        Write-Log "Info" "Stopping watcher via launcher..." -NoConsole
        try {
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$launcher`" stop" -Wait -PassThru -NoNewWindow
        } catch {
            Write-Log "Warn" "Could not stop watcher: $_" -NoConsole
        }
    }

    Write-Host "This will remove:" -ForegroundColor Yellow
    Write-Host "  - $($Script:_installDir) (mark-dawn installation)" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Data files in $($Script:_dataDir)\Research and $($Script:_dataDir)\Inbox_Failed will NOT be removed." -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "Are you sure? Type 'yes' to uninstall"
    if ($confirm -ne "yes") {
        Write-Host "Uninstall cancelled."
        return
    }

    try {
        $proc = Start-Process -FilePath "schtasks" -ArgumentList "/Delete", "/TN", "mark-dawn", "/F" -Wait -PassThru -NoNewWindow
    } catch {
        Write-Log "Info" "Task Scheduler entry may remain (not admin)" -NoConsole
    }

    try {
        Remove-DirectorySafe $Script:_installDir -Force
        Write-OK "Installation directory removed: $($Script:_installDir)"
    } catch {
        Write-Log "Warn" "Could not remove installation directory: $_" -NoConsole
    }

    Clear-InstallState

    Write-Host ""
    Write-Host "=== mark-dawn uninstalled ===" -ForegroundColor Green
    Write-Host "Data files preserved in: $($Script:_dataDir)" -ForegroundColor Cyan
    Write-Host "To remove them manually, delete the Inbox, Research, and Inbox_Failed folders." -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# SCRIPT CONTENT GENERATORS
# ============================================================================
function Get-LauncherScript {
    return @"
@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM mark-dawn launcher for Windows (Option B)
REM Commands match Linux version: start, stop, restart, convert, logs, status,
REM                                update, install-task, uninstall-task, help
REM Generated by mark-dawn.ps1 installer v$($Script:_installVersion)
REM ============================================================================

set "INSTALL_DIR=%~dp0"
set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"
set "PYTHON_DIR=%INSTALL_DIR%\python"
set "MSYS2_DIR=%INSTALL_DIR%\.msys2"
set "DATA_DIR=$($Script:_dataDir)"
set "SCRIPTS_DIR=%INSTALL_DIR%\scripts"
set "LOGS_DIR=%INSTALL_DIR%\logs"
set "PID_FILE=%INSTALL_DIR%\mark-dawn.pid"
set "PID_TMP=%PID_FILE%.tmp"
set "LOG_FILE=%LOGS_DIR%\mark-dawn.log"
set "PYTHON=%PYTHON_DIR%\python.exe"

REM Set environment variables consumed by Python scripts
set "MARK_DAWN_DATA=%DATA_DIR%"
set "MARK_DAWN_SCRIPTS=%SCRIPTS_DIR%"
set "MARK_DAWN_LOG=%LOG_FILE%"
set "MARK_DAWN_PID=%PID_FILE%"
set "TESSDATA_PREFIX=%INSTALL_DIR%\tessdata"
set "PATH=%MSYS2_DIR%\mingw64\bin;%PYTHON_DIR%;%PYTHON_DIR%\Scripts;%PATH%"
set "PYTHONIOENCODING=utf-8"

REM Ensure directories exist
if not exist "%DATA_DIR%\Inbox" mkdir "%DATA_DIR%\Inbox"
if not exist "%DATA_DIR%\Research" mkdir "%DATA_DIR%\Research"
if not exist "%DATA_DIR%\Inbox_Failed" mkdir "%DATA_DIR%\Inbox_Failed"
if not exist "%LOGS_DIR%" mkdir "%LOGS_DIR%"

if "%1"=="" goto help
if "%1"=="start" goto start
if "%1"=="stop" goto stop
if "%1"=="restart" goto restart
if "%1"=="convert" goto convert
if "%1"=="logs" goto logs
if "%1"=="status" goto status
if "%1"=="update" goto update
if "%1"=="install-task" goto install_task
if "%1"=="uninstall-task" goto uninstall_task
if "%1"=="help" goto help
if "%1"=="--help" goto help
if "%1"=="-h" goto help
goto help

:start
    echo Starting mark-dawn watcher...

    if exist "%PID_FILE%" (
        set /p OLD_PID=<"%PID_FILE%"
        tasklist /FI "PID eq !OLD_PID!" 2>nul | findstr /C:"!OLD_PID!" >nul 2>&1
        if errorlevel 1 (
            echo Cleaning up stale PID file...
            del "%PID_FILE%" >nul 2>&1
        ) else (
            echo FAIL: mark-dawn is already running - PID !OLD_PID!
            echo Stop it first: mark-dawn.bat stop
            exit /b 1
        )
    )

    if not exist "%PYTHON%" (
        echo FAIL: Python not found at %PYTHON%
        exit /b 1
    )

    if not exist "%SCRIPTS_DIR%\watcher.py" (
        echo FAIL: watcher.py not found at %SCRIPTS_DIR%\watcher.py
        echo Re-run the installer to fix this.
        exit /b 1
    )

    start "" /B "%PYTHON%" "%SCRIPTS_DIR%\watcher.py" >> "%LOG_FILE%" 2>&1

    set WAIT_COUNT=0
    :wait_pid
    if exist "%PID_FILE%" goto pid_ok
    timeout /t 1 /nobreak >nul
    set /a WAIT_COUNT+=1
    if !WAIT_COUNT! lss 5 goto wait_pid

    echo WARNING: Watcher started but PID file not yet created.
    echo Check logs: %LOG_FILE%
    goto :eof

    :pid_ok
    set /p PID=<"%PID_FILE%"
    echo OK: mark-dawn started (PID !PID!)
    echo    Inbox:    %DATA_DIR%\Inbox
    echo    Research: %DATA_DIR%\Research
    echo    Logs:     %LOG_FILE%
    goto end

:stop
    if not exist "%PID_FILE%" (
        echo mark-dawn is not running
        goto end
    )
    set /p PID=<"%PID_FILE%"
    echo Stopping mark-dawn (PID %PID%)...

    tasklist /FI "PID eq %PID%" 2>nul | findstr /C:"%PID%" >nul 2>&1
    if errorlevel 1 (
        echo Process not found - stale PID file, cleaning up...
        del "%PID_FILE%" >nul 2>&1
        goto end
    )

    taskkill /PID %PID% /T /F >nul 2>&1
    timeout /t 2 /nobreak >nul

    if exist "%PID_FILE%" del "%PID_FILE%" >nul 2>&1

    echo OK: mark-dawn stopped
    goto end

:restart
    call :stop
    timeout /t 2 /nobreak >nul
    call :start
    goto end

:convert
    if "%2"=="" (
        echo Usage: mark-dawn.bat convert FILE
        exit /b 1
    )
    if not exist "%2" (
        echo File not found: %2
        exit /b 1
    )
    if not exist "%PYTHON%" (
        echo FAIL: Python not found at %PYTHON%
        exit /b 1
    )
    "%PYTHON%" "%SCRIPTS_DIR%\convert_pdf.py" "%~f2"
    set EXIT_CODE=!ERRORLEVEL!
    if !EXIT_CODE! equ 0 (
        echo OK: Conversion complete
    ) else (
        echo FAIL: Conversion failed - exit code !EXIT_CODE!
    )
    exit /b !EXIT_CODE!

:logs
    if not exist "%LOG_FILE%" (
        echo No logs yet. Start the watcher first.
        goto end
    )
    echo Showing last 50 lines of %LOG_FILE% (Ctrl+C to exit)...
    powershell -Command "Get-Content -Tail 50 -Wait -Path '%LOG_FILE%'"
    goto end

:status
    if not exist "%PID_FILE%" (
        echo mark-dawn is not running
        goto end
    )
    set /p PID=<"%PID_FILE%"
    tasklist /FI "PID eq %PID%" 2>nul | findstr /C:"%PID%" >nul 2>&1
    if errorlevel 1 (
        echo mark-dawn is not running - stale PID file, cleaning up
        del "%PID_FILE%" >nul 2>&1
    ) else (
        echo mark-dawn is running - PID %PID%
        echo    Inbox:    %DATA_DIR%\Inbox
        echo    Research: %DATA_DIR%\Research
        echo    Logs:     %LOG_FILE%
    )
    goto end

:update
    echo Updating mark-dawn components...
    echo.

    echo [1/3] Updating Python packages via pip...
    if exist "%PYTHON%" (
        "%PYTHON%" -m pip install --upgrade --no-cache-dir pymupdf4llm markitdown python-docx openpyxl python-pptx watchdog
    ) else (
        echo WARNING: Python not found. Skipping pip update.
    )

    echo [2/3] Restarting watcher...
    call :stop
    timeout /t 2 /nobreak >nul
    call :start

    echo.
    echo OK: Update complete
    goto end

:install_task
    net session >nul 2>&1
    if errorlevel 1 (
        echo install-task requires Administrator rights.
        echo Attempting to elevate...
        powershell -Command "Start-Process '%~f0' -ArgumentList 'install-task' -Verb RunAs -Wait"
        if errorlevel 1 (
            echo FAIL: Elevation failed or cancelled.
        ) else (
            echo OK: Task Scheduler entry created
        )
        exit /b !ERRORLEVEL!
    )

    schtasks /Create /TN "mark-dawn" /TR "\"%INSTALL_DIR%\mark-dawn.bat\" start" /SC ONLOGON /RL HIGHEST /F
    if errorlevel 1 (
        echo FAIL: Failed to create Task Scheduler entry.
        exit /b 1
    )

    schtasks /Run /TN "mark-dawn" >nul 2>&1

    echo OK: Task Scheduler entry created and started on next login
    goto end

:uninstall_task
    net session >nul 2>&1
    if errorlevel 1 (
        echo uninstall-task requires Administrator rights.
        echo Attempting to elevate...
        powershell -Command "Start-Process '%~f0' -ArgumentList 'uninstall-task' -Verb RunAs -Wait"
        if errorlevel 1 (
            echo FAIL: Elevation failed or cancelled.
        ) else (
            echo OK: Task Scheduler entry removed
        )
        exit /b !ERRORLEVEL!
    )

    schtasks /Delete /TN "mark-dawn" /F
    if errorlevel 1 (
        echo FAIL: Failed to remove Task Scheduler entry.
        exit /b 1
    )
    echo OK: Task Scheduler entry removed
    goto end

:help
    echo.
    echo mark-dawn - Universal Document to Markdown Pipeline (Windows Portable)
    echo.
    echo Usage: mark-dawn.bat ^<command^> [args]
    echo.
    echo Commands:
    echo   start              Start background watcher (watches data\Inbox)
    echo   stop               Stop background watcher
    echo   restart            Restart watcher
    echo   convert FILE       Convert single file
    echo   logs               Follow logs (last 50 lines + live tail)
    echo   status             Show watcher status and PID
    echo   update             Update Python dependencies
    echo   install-task       Install auto-start on login (requires Admin)
    echo   uninstall-task     Remove auto-start entry (requires Admin)
    echo   help               Show this help message
    echo.
    echo Supported formats: PDF, DOCX, XLSX, PPTX, HTML, CSV, RTF
    echo Supported languages: English, Russian, French, German, Chinese, Japanese
    echo.
    echo Directories:
    echo   %DATA_DIR%\Inbox         - Drop files here for auto-conversion
    echo   %DATA_DIR%\Research      - Converted Markdown files appear here
    echo   %DATA_DIR%\Inbox_Failed  - Failed conversions moved here
    echo.
    goto end

:end
endlocal
exit /b 0
"@
}

function Get-WatcherScript {
    return @'
#!/usr/bin/env python3
"""mark-dawn watcher: monitors Inbox folder and converts new files to Markdown."""
import os, sys, time, subprocess
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

DATA_DIR     = Path(os.environ.get("MARK_DAWN_DATA", os.path.expanduser("~/Documents")))
INBOX        = DATA_DIR / "Inbox"
RESEARCH     = DATA_DIR / "Research"
FAILED       = DATA_DIR / "Inbox_Failed"
SCRIPTS_DIR  = Path(os.environ.get("MARK_DAWN_SCRIPTS", Path(__file__).parent))
LOG_FILE     = Path(os.environ.get("MARK_DAWN_LOG", SCRIPTS_DIR.parent / "logs" / "mark-dawn.log"))
PID_FILE     = Path(os.environ.get("MARK_DAWN_PID", SCRIPTS_DIR.parent / "mark-dawn.pid"))
STOP_FILE    = SCRIPTS_DIR.parent / "mark-dawn.stop"
CONVERT_SCRIPT = SCRIPTS_DIR / "convert_pdf.py"
DEBOUNCE     = 3.0
SUPPORTED    = {".pdf", ".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

def file_is_ready(filepath, min_size=1024, max_age=2.0):
    try:
        if not filepath.exists():
            return False
        if filepath.stat().st_size < min_size:
            return False
        s1 = filepath.stat().st_size
        time.sleep(0.5)
        s2 = filepath.stat().st_size
        return s1 == s2
    except (OSError, PermissionError):
        return False

class InboxHandler(FileSystemEventHandler):
    def __init__(self):
        self.pending = {}

    def _touch(self, p):
        p = Path(p)
        if p.suffix.lower() in SUPPORTED and not p.name.startswith("~") and not p.name.startswith("."):
            self.pending[p] = time.time()
            log(f"Detected: {p.name}")

    def on_created(self, e):
        if not e.is_directory:
            self._touch(e.src_path)

    def on_moved(self, e):
        if not e.is_directory:
            self._touch(e.dest_path)

    def on_modified(self, e):
        if not e.is_directory:
            self._touch(e.src_path)

def process_file(file_path):
    ext = file_path.suffix.lower()
    out_file = RESEARCH / f"{file_path.stem}.md"

    try:
        if ext == ".pdf":
            result = subprocess.run(
                [sys.executable, str(CONVERT_SCRIPT), str(file_path)],
                timeout=700
            )
            if result.returncode == 0 and out_file.exists():
                file_path.unlink(missing_ok=True)
                log(f"OK: {file_path.name} -> {out_file.name}")
                return True
        elif ext in {".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}:
            env = os.environ.copy()
            env["PYTHONIOENCODING"] = "utf-8"
            result = subprocess.run(
                ["markitdown", str(file_path)],
                capture_output=True, text=True, timeout=120, env=env
            )
            if result.returncode == 0 and result.stdout:
                tmp = out_file.with_suffix(".md.tmp")
                tmp.write_text(result.stdout, encoding="utf-8")
                tmp.rename(out_file)
                file_path.unlink(missing_ok=True)
                log(f"OK: {file_path.name} -> {out_file.name}")
                return True
    except subprocess.TimeoutExpired:
        log(f"Timeout processing {file_path.name}")
    except Exception as e:
        log(f"Error processing {file_path.name}: {e}")

    try:
        dest = FAILED / file_path.name
        file_path.rename(dest)
        log(f"FAIL: {file_path.name} moved to Failed")
    except Exception as e:
        log(f"Failed to move {file_path.name} to Failed: {e}")
    return False

def main():
    INBOX.mkdir(parents=True, exist_ok=True)
    RESEARCH.mkdir(parents=True, exist_ok=True)
    FAILED.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    try:
        pid_tmp = PID_FILE.with_suffix(".pid.tmp")
        pid_tmp.write_text(str(os.getpid()))
        pid_tmp.rename(PID_FILE)
    except Exception as e:
        log(f"WARNING: Could not write PID file: {e}")

    STOP_FILE.unlink(missing_ok=True)

    handler = InboxHandler()
    observer = Observer()
    observer.schedule(handler, str(INBOX), recursive=False)
    observer.start()

    log(f"mark-dawn watcher started (PID {os.getpid()})")
    log(f"Watching: {INBOX}")
    log(f"Output:   {RESEARCH}")
    log(f"Stop marker: {STOP_FILE}")

    try:
        while True:
            if STOP_FILE.exists():
                log("Stop marker detected, shutting down...")
                break

            time.sleep(1.0)
            now = time.time()

            ready = [
                p for p, t in list(handler.pending.items())
                if now - t >= DEBOUNCE and p.exists() and file_is_ready(p)
            ]
            for p in ready:
                handler.pending.pop(p, None)
                if not p.exists():
                    continue
                log(f"Processing: {p.name}")
                process_file(p)

            stale = [p for p, t in list(handler.pending.items()) if now - t > 300]
            for p in stale:
                handler.pending.pop(p, None)
    except KeyboardInterrupt:
        log("Interrupted, stopping watcher...")
    finally:
        observer.stop()
        observer.join()
        log("Watcher stopped")

    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass

if __name__ == "__main__":
    main()
'@
}

function Get-ConvertScript {
    return @'
#!/usr/bin/env python3
"""mark-dawn PDF converter: digital via pymupdf4llm, scanned via ocrmypdf."""
import os, sys, subprocess, tempfile, shutil
from pathlib import Path
import fitz
import pymupdf4llm

DATA_DIR  = Path(os.environ.get("MARK_DAWN_DATA", os.path.expanduser("~/Documents")))
RESEARCH  = DATA_DIR / "Research"
RESEARCH.mkdir(parents=True, exist_ok=True)

file_path = Path(sys.argv[1])
out_file  = RESEARCH / f"{file_path.stem}.md"

lock_file = RESEARCH / f".{file_path.stem}.lock"

try:
    if lock_file.exists():
        print(f"Lock file exists for {file_path.name}, another process may be working on it")
        sys.exit(0)
    lock_file.write_text(str(os.getpid()))

    doc = fitz.open(str(file_path))
    num_pages = len(doc)
    if num_pages == 0:
        doc.close()
        print(f"Empty PDF: {file_path.name}")
        sys.exit(1)

    text_len = sum(len(page.get_text()) for page in doc)
    doc.close()

    avg_chars = text_len / num_pages if num_pages > 0 else 0

    if avg_chars > 100:
        print(f"Digital PDF ({int(avg_chars)} chars/page). Converting via pymupdf4llm...")
        md_text = pymupdf4llm.to_markdown(str(file_path))
        tmp_out = out_file.with_suffix(".md.tmp")
        tmp_out.write_text(md_text, encoding="utf-8")
        tmp_out.rename(out_file)
        print(f"OK: {out_file.name}")
        sys.exit(0)
    else:
        print(f"Scanned PDF ({int(avg_chars)} chars/page). Running ocrmypdf...")
        with tempfile.TemporaryDirectory() as tmp_dir:
            ocr_input = Path(tmp_dir) / file_path.name
            ocr_output = Path(tmp_dir) / f"ocr_{file_path.name}"

            shutil.copy2(str(file_path), str(ocr_input))

            env = os.environ.copy()
            env["PYTHONIOENCODING"] = "utf-8"
            env["OMP_THREAD_LIMIT"] = "1"

            cmd = [
                "ocrmypdf",
                "--skip-text",
                "-l", "eng+rus+fra+deu+chi_sim+jpn",
                "-j", "1",
                "--output-type", "pdf",
                "--pdf-renderer", "sandwich",
                str(ocr_input),
                str(ocr_output)
            ]
            result = subprocess.run(
                cmd, capture_output=True, text=True, env=env, timeout=600
            )
            if result.returncode != 0:
                print(f"ocrmypdf failed (exit {result.returncode}):", file=sys.stderr)
                if result.stderr:
                    print(result.stderr[-1024:], file=sys.stderr)
                sys.exit(1)
            if not ocr_output.exists():
                print("ocrmypdf did not produce output file", file=sys.stderr)
                sys.exit(1)

            print("OCR complete. Converting to Markdown...")
            md_text = pymupdf4llm.to_markdown(str(ocr_output))
            tmp_out = out_file.with_suffix(".md.tmp")
            tmp_out.write_text(md_text, encoding="utf-8")
            tmp_out.rename(out_file)
            print(f"OK: {out_file.name}")
            sys.exit(0)

except subprocess.TimeoutExpired:
    print("Timeout: ocrmypdf took more than 10 minutes", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Fatal error: {e}", file=sys.stderr)
    sys.exit(1)
finally:
    try:
        lock_file.unlink(missing_ok=True)
    except Exception:
        pass
'@
}

# ============================================================================
# COMMAND DISPATCH
# ============================================================================
function Show-Help {
    Write-Host "mark-dawn portable installer for Windows (Option B)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: mark-dawn.ps1 [options]" -ForegroundColor White
    Write-Host ""
    Write-Host "Install options:" -ForegroundColor Yellow
    Write-Host "  -InstallDir <path>   Custom installation directory (default: %USERPROFILE%\mark-dawn)"
    Write-Host "  -DataDir <path>      Custom data directory (default: %USERPROFILE%\Documents)"
    Write-Host "  -Msys2Mirror <url>   MSYS2 mirror base URL (skip auto-probe, e.g. https://mirrors.ustc.edu.cn/msys2)"
    Write-Host "  -PypiMirror <url>    PyPI mirror for pip (e.g. https://mirror.yandex.ru/mirror/pypi/simple/)"
    Write-Host "  -SkipInit            Skip MSYS2 initialization (for re-runs)"
    Write-Host "  -ForceRedownload     Re-download all artifacts"
    Write-Host "  -SkipVerification    Skip SHA256 checks (not recommended)"
    Write-Host "  -MaxRetries <n>      Download retry count (default: 3)"
    Write-Host "  -TimeoutSec <n>      Download timeout in seconds (default: 300)"
    Write-Host "  -LogLevel <level>    Debug|Info|Warn|Error (default: Info)"
    Write-Host ""
    Write-Host "Other commands:" -ForegroundColor Yellow
    Write-Host "  -Uninstall           Remove the installation"
    Write-Host "  -Help                Show this help"
    Write-Host ""
    Write-Host "After installation, use the launcher:" -ForegroundColor Cyan
    Write-Host "  & `"$($Script:DEFAULT_INSTALL_DIR)\mark-dawn.bat`" start|stop|restart|convert|logs|status|update|install-task|uninstall-task|help"
    Write-Host ""
    exit 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================
function Main {
    $Script:_logLevelNum = @{ "Debug" = 0; "Info" = 1; "Warn" = 2; "Error" = 3 }[$LogLevel]

    if ($Help) { Show-Help }

    if ($Uninstall) {
        $Script:_installDir = if ($InstallDir) { $InstallDir } else { $Script:DEFAULT_INSTALL_DIR }
        $Script:_dataDir    = if ($DataDir)    { $DataDir }    else { $Script:DEFAULT_DATA_DIR }
        $Script:_pythonDir  = Join-PathSafe $Script:_installDir "python"
        $Script:_stateFile  = Join-PathSafe $Script:_installDir ".install-state.json"
        Invoke-Uninstall
        return
    }

    $Script:_installDir = if ($InstallDir) { $InstallDir } else { $Script:DEFAULT_INSTALL_DIR }
    $Script:_dataDir    = if ($DataDir)    { $DataDir }    else { $Script:DEFAULT_DATA_DIR }
    $Script:_msys2MirrorOverride = $Msys2Mirror
    $Script:_pypiMirror = $PypiMirror
    # Set all path variables BEFORE Invoke-Install (so skipped steps still have valid paths)
    $Script:_pythonDir     = Join-PathSafe $Script:_installDir "python"
    $Script:_msys2Dir      = Join-PathSafe $Script:_installDir ".msys2"
    $Script:_scriptsDir    = Join-PathSafe $Script:_installDir "scripts"
    $Script:_logsDir       = Join-PathSafe $Script:_installDir "logs"
    $Script:_tessdataDir   = Join-PathSafe $Script:_installDir "tessdata"
    $Script:_launcherPath  = Join-PathSafe $Script:_installDir "mark-dawn.bat"
    $Script:_pidFile       = Join-PathSafe $Script:_installDir "mark-dawn.pid"
    $Script:_logFile       = Join-PathSafe $Script:_logsDir "mark-dawn.log"
    $Script:_stateFile     = Join-PathSafe $Script:_installDir ".install-state.json"
    $Script:_pythonExe     = Join-PathSafe $Script:_pythonDir "python.exe"

    Invoke-Install
}

Main
