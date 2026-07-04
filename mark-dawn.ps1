#Requires -RunAsAdministrator
<#
.SYNOPSIS
    mark-dawn: complete installer for Windows (WSL + Podman + container)
.DESCRIPTION
    Installs everything in one command:
    - WSL2 (if not installed)
    - Podman (if not installed)
    - Podman machine (Linux VM)
    - mark-dawn container
.NOTES
    Requires: Windows 10/11, administrator rights
#>

param(
    [switch]$SkipReboot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host "[$Step] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-OK { param([string]$Message) Write-Host "OK: $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host ">> $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "FAIL: $Message" -ForegroundColor Red }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " mark-dawn installer for Windows" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# [1/7] Check admin rights
# ============================================================================
Write-Step "1/7" "Checking administrator rights..."
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "Script requires administrator rights"
    Write-Host "Run PowerShell as Administrator:" -ForegroundColor Yellow
    Write-Host "  Right-click Start -> Terminal (Admin)" -ForegroundColor Yellow
    exit 1
}
Write-OK "Administrator rights confirmed"

# ============================================================================
# [2/7] Check and install WSL
# ============================================================================
Write-Step "2/7" "Checking WSL..."
$wslInstalled = $false
try {
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) {
        $wslInstalled = $true
        Write-OK "WSL already installed"
    }
} catch {
    $wslInstalled = $false
}

if (-not $wslInstalled) {
    Write-Info "WSL not found, installing..."
    try {
        wsl --install --no-distribution
        if ($LASTEXITCODE -ne 0) { throw "wsl --install failed" }
        Write-OK "WSL installed"
        
        if (-not $SkipReboot) {
            Write-Host ""
            Write-Host "!! REBOOT REQUIRED to complete WSL installation" -ForegroundColor Yellow
            Write-Host "After reboot, run this script again." -ForegroundColor Yellow
            Write-Host ""
            $confirm = Read-Host "Reboot now? (y/N)"
            if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                shutdown /r /t 10 /c "Rebooting to complete WSL installation"
            } else {
                Write-Host "Reboot manually and run script again." -ForegroundColor Yellow
            }
            exit 0
        }
    } catch {
        Write-Fail "Failed to install WSL: $_"
        exit 1
    }
}

# Check that WSL2 is active
try {
    $wslList = wsl --list --verbose 2>&1
    Write-OK "WSL is working"
} catch {
    Write-Fail "WSL installed but not working. Reboot required."
    exit 1
}

# ============================================================================
# [3/7] Check and install Podman
# ============================================================================
Write-Step "3/7" "Checking Podman..."
if (Get-Command podman -ErrorAction SilentlyContinue) {
    $podmanVer = (podman --version).Trim()
    Write-OK "Podman found: $podmanVer"
} else {
    Write-Info "Podman not found, installing via winget..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail "winget not found. Install Podman manually:"
        Write-Host "  https://podman-desktop.io/" -ForegroundColor Yellow
        exit 1
    }
    try {
        winget install --id RedHat.Podman -e --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget install failed" }
        Write-OK "Podman installed"
        
        # Update PATH in current session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        
        if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
            Write-Host ""
            Write-Host "!! Podman installed but PATH not updated." -ForegroundColor Yellow
            Write-Host "Restart PowerShell and run script again." -ForegroundColor Yellow
            exit 0
        }
    } catch {
        Write-Fail "Failed to install Podman: $_"
        exit 1
    }
}

# ============================================================================
# [4/7] Check and create Podman machine
# ============================================================================
Write-Step "4/7" "Checking Podman machine..."

# Check if machine exists
$machines = podman machine list --format "{{.Name}}" 2>&1
$hasMachine = $machines -and ($machines -notlike "*cannot*") -and ($machines -notlike "*error*") -and ($machines.Trim().Length -gt 0)

if (-not $hasMachine) {
    Write-Info "Creating Podman machine (this will take 2-5 minutes)..."
    try {
        podman machine init --cpus 2 --memory 4096 --disk-size 50
        if ($LASTEXITCODE -ne 0) { throw "podman machine init failed" }
        Write-OK "Podman machine created"
    } catch {
        Write-Fail "Failed to create Podman machine: $_"
        exit 1
    }
} else {
    Write-OK "Podman machine exists"
}

# ============================================================================
# [5/7] Start Podman machine
# ============================================================================
Write-Step "5/7" "Starting Podman machine..."

# Check if machine is running
$machineStatus = podman machine list --format "{{.Running}}" 2>&1
$isRunning = $machineStatus -eq "running" -or $machineStatus -eq "true"

if (-not $isRunning) {
    Write-Info "Starting Podman machine..."
    try {
        podman machine start
        if ($LASTEXITCODE -ne 0) { throw "podman machine start failed" }
        Write-OK "Podman machine started"
    } catch {
        Write-Fail "Failed to start Podman machine: $_"
        exit 1
    }
} else {
    Write-OK "Podman machine already running"
}

# Verify connection
try {
    $null = podman info 2>&1
    if ($LASTEXITCODE -ne 0) { throw "podman info failed" }
    Write-OK "Podman is ready"
} catch {
    Write-Fail "Podman not responding. Check: podman machine list"
    exit 1
}

# ============================================================================
# [6/7] Install mark-dawn launcher
# ============================================================================
Write-Step "6/7" "Installing mark-dawn launcher..."

$binDir = Join-Path $env:USERPROFILE ".local\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$launcherPath = Join-Path $binDir "mark-dawn.ps1"
$launcherUrl = "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1"

try {
    Write-Info "Downloading launcher from GitHub..."
    Invoke-WebRequest -Uri $launcherUrl -OutFile $launcherPath -UseBasicParsing
    Unblock-File -Path $launcherPath -ErrorAction SilentlyContinue
    Write-OK "Launcher installed: $launcherPath"
} catch {
    Write-Fail "Failed to download launcher: $_"
    Write-Host "Download manually: $launcherUrl" -ForegroundColor Yellow
    exit 1
}

# ============================================================================
# [7/7] Start mark-dawn
# ============================================================================
Write-Step "7/7" "Starting mark-dawn..."

try {
    # Check execution policy
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq "Restricted") {
        Write-Info "Allowing local script execution..."
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-OK "Execution policy set to RemoteSigned"
    }
    
    # Start mark-dawn
    Write-Info "Starting mark-dawn watcher..."
    & $launcherPath -Command start
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " mark-dawn installed and started!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Inbox:    $env:USERPROFILE\Documents\Inbox" -ForegroundColor Cyan
    Write-Host "Research: $env:USERPROFILE\Documents\Research" -ForegroundColor Cyan
    Write-Host "Failed:   $env:USERPROFILE\Documents\Inbox_Failed" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Management:" -ForegroundColor Yellow
    Write-Host "  & '$launcherPath' -Command status" -ForegroundColor White
    Write-Host "  & '$launcherPath' -Command logs" -ForegroundColor White
    Write-Host "  & '$launcherPath' -Command stop" -ForegroundColor White
    Write-Host "  & '$launcherPath' -Command update" -ForegroundColor White
    Write-Host ""
    Write-Host "Auto-start on login:" -ForegroundColor Yellow
    Write-Host "  & '$launcherPath' -Command install-task" -ForegroundColor White
    Write-Host ""
    
} catch {
    Write-Fail "Failed to start mark-dawn: $_"
    exit 1
}
