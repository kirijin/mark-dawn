# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    mark-dawn portable installer for Windows (Option B)
.DESCRIPTION
    Installs mark-dawn - a universal document-to-Markdown pipeline - as a fully
    portable application on Windows 10/11 x64.  No WSL, no containers, no
    administrator rights required (except for Task Scheduler auto-start).

    Architecture: Python.org embedded distribution + pip for Python packages,
    MSYS2 only for system tool binaries (djvulibre).

    Data directories match the Linux convention so the workflow is identical:
      %USERPROFILE%\Documents\Inbox         Drop files here
      %USERPROFILE%\Documents\Research      Converted .md files appear here
      %USERPROFILE%\Documents\Inbox_Failed  Failed conversions land here

    SHA256-verified downloads, idempotent execution, structured logging.

.NOTES
    Version  : 2.3.0
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
    [switch]$Uninstall,
    [switch]$QuickReinstall,
    [switch]$FullReinstall,
    [switch]$ChangeLangs
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
# NOTE: get-pip.py changes with every pip release — pinning its hash would
# break fresh installs whenever PyPA ships a new one. Size is sanity-checked
# at download time instead.
$Script:GETPIP_URL     = "https://bootstrap.pypa.io/get-pip.py"
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
    "mingw-w64-x86_64-djvulibre"
)

# MSYS2 mirrors -- probed in order during Select-FastestMirror
$Script:MSYS2_MIRRORS = @(
    @{ Name = "Official";  Base = "https://mirror.msys2.org" }
    @{ Name = "CDN77";     Base = "https://msys2.cdn77.org" }
    @{ Name = "Yandex";    Base = "https://mirror.yandex.ru/msys2" }
    @{ Name = "USTC";      Base = "https://mirrors.ustc.edu.cn/msys2" }
    @{ Name = "Tsinghua";  Base = "https://mirrors.tuna.tsinghua.edu.cn/msys2" }
    @{ Name = "Aliyun";    Base = "https://mirrors.aliyun.com/msys2" }
    @{ Name = "Selfnet";   Base = "https://mirror.selfnet.de/msys2" }
    @{ Name = "FAU";       Base = "https://ftp.fau.de/msys2" }
)


# Python packages are installed from the pinned requirements.txt shared with
# the container build and the brew installer — every platform runs the same
# versions. (watchdog, not watchfiles: the watcher is the same code everywhere.)
$Script:REPO_URL = "https://raw.githubusercontent.com/kirijin/mark-dawn/main"
$Script:REQUIREMENTS_URL = "$($Script:REPO_URL)/requirements.txt"

# Default directories
$Script:DEFAULT_INSTALL_DIR = [System.IO.Path]::Combine($env:LOCALAPPDATA, "mark-dawn")
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
$Script:_launcherPath   = ""
$Script:_pidFile        = ""
$Script:_logFile        = ""
$Script:_installLog     = ""
$Script:_stateFile      = ""
$Script:_pythonExe      = ""
$Script:_installVersion = "2.3.0"
$Script:_logLevelNum    = 1  # 0=Debug 1=Info 2=Warn 3=Error
$Script:msys2InstallerPath = ""
$Script:_selectedMsys2Mirror = ""
$Script:_msys2MirrorOverride = ""
$Script:_failedMsys2Mirrors = @()
$Script:_pypiMirror = ""

# ============================================================================
# LOGGING HELPERS
# ============================================================================

# --- Load modules (split) ---------------------------------------------
$moduleDir = Join-Path $PSScriptRoot "windows"
$moduleNames = @("00-bootstrap.ps1","10-steps.ps1","20-commands.ps1",
                 "30-templates.ps1","40-ui.ps1")
if (-not (Test-Path (Join-Path $moduleDir $moduleNames[0]))) {
    # Fallback: fetch modules from GitHub (piped install without local tree).
    $moduleDir = Join-Path $env:TEMP ("mark-dawn-modules-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
    $base = "https://raw.githubusercontent.com/kirijin/mark-dawn/main/windows"
    foreach ($m in $moduleNames) {
        Invoke-WebRequest -Uri "$base/$m" -UseBasicParsing -OutFile (Join-Path $moduleDir $m) -ErrorAction Stop
    }
}
foreach ($m in $moduleNames) {
    . (Join-Path $moduleDir $m)
}

# --- Entry point --------------------------------------------------------
Main
