<#
.SYNOPSIS
    mark-dawn portable installer for Windows (MSYS2-based, no WSL required)
.DESCRIPTION
    One-command install of mark-dawn as a fully portable application.
    No administrator rights required (except for install-task).
    No WSL, no VM, no Docker.
.NOTES
    Supports Windows 10/11 x64. PowerShell 5.1+ compatible.
    All output in English for automation compatibility.
#>

param(
    [string]$InstallDir = "",
    [switch]$SkipInit,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Helper functions
# ============================================================================
function Write-Step  { param([string]$n,[string]$m) Write-Host "[$n] " -ForegroundColor Cyan -NoNewline; Write-Host $m }
function Write-OK    { param([string]$m) Write-Host "OK: $m" -ForegroundColor Green }
function Write-Info  { param([string]$m) Write-Host ">> $m" -ForegroundColor Yellow }
function Write-Fail  { param([string]$m) Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

function Show-Help {
    Write-Host "mark-dawn portable installer for Windows" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: install.ps1 [-InstallDir <path>] [-SkipInit] [-Help]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -InstallDir   Custom installation directory (default: %USERPROFILE%\mark-dawn)"
    Write-Host "  -SkipInit     Skip MSYS2 initialization (advanced, for re-runs)"
    Write-Host "  -Help         Show this help message"
    exit 0
}

if ($Help) { Show-Help }

function Test-Administrator {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================================
# [1/10] Resolve installation directory (no admin required)
# ============================================================================
Write-Step "1/10" "Resolving installation directory..."

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:USERPROFILE "mark-dawn"
}

$resolvedPath = Resolve-Path $InstallDir -ErrorAction SilentlyContinue
if ($resolvedPath) {
    $InstallDir = $resolvedPath.Path
}

$MSYS2_DIR     = Join-Path $InstallDir "msys64"
$DATA_DIR      = Join-Path $InstallDir "data"
$SCRIPTS_DIR   = Join-Path $InstallDir "scripts"
$LOGS_DIR      = Join-Path $InstallDir "logs"
$TESSDATA_DIR  = Join-Path $MSYS2_DIR "mingw64\share\tessdata"
$LAUNCHER_PATH = Join-Path $InstallDir "mark-dawn.bat"
$PID_FILE      = Join-Path $InstallDir "mark-dawn.pid"
$LOG_FILE      = Join-Path $LOGS_DIR "mark-dawn.log"

try {
    New-Item -ItemType Directory -Force -Path $InstallDir, $DATA_DIR, $SCRIPTS_DIR, $LOGS_DIR | Out-Null
} catch {
    Write-Fail "Cannot write to $InstallDir. Check permissions."
}
Write-OK "Install directory: $InstallDir"

# ============================================================================
# [2/10] Download MSYS2 SFX archive
# ============================================================================
Write-Step "2/10" "Downloading MSYS2 SFX archive (~100 MB)..."

$msys2Installer = Join-Path $env:TEMP "msys2-base-x86_64-latest.sfx.exe"
$msys2Urls = @(
    "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe",
    "https://github.com/msys2/msys2-installer/releases/download/2025-02-21/msys2-base-x86_64-latest.sfx.exe"
)

if (-not (Test-Path $msys2Installer)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloaded = $false
    foreach ($url in $msys2Urls) {
        try {
            Write-Info "Trying: $url"
            Invoke-WebRequest -Uri $url -OutFile $msys2Installer -UseBasicParsing
            if ((Get-Item $msys2Installer).Length -gt 50MB) {
                $downloaded = $true
                break
            } else {
                Remove-Item $msys2Installer -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Info "Failed, trying fallback..."
            Remove-Item $msys2Installer -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $downloaded) {
        Write-Fail "Failed to download MSYS2 from all mirrors"
    }
}
Write-OK "MSYS2 SFX archive ready"

# ============================================================================
# [3/10] Extract MSYS2 silently via SFX
# ============================================================================
Write-Step "3/10" "Extracting MSYS2 (this takes 2-3 minutes)..."

$bashExe = Join-Path $MSYS2_DIR "usr\bin\bash.exe"
if (-not (Test-Path $bashExe)) {
    try {
        $sfxArgs = @("-y", "-o`"$InstallDir`"")
        Write-Info "Running: $msys2Installer $sfxArgs"
        $proc = Start-Process -FilePath $msys2Installer `
            -ArgumentList $sfxArgs `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "SFX extraction failed with code $($proc.ExitCode)"
        }
        if (-not (Test-Path $bashExe)) {
            throw "bash.exe not found after extraction at $bashExe"
        }
        Remove-Item $msys2Installer -Force -ErrorAction SilentlyContinue
        Write-OK "MSYS2 extracted to $MSYS2_DIR"
    } catch {
        Write-Fail "Failed to extract MSYS2: $_"
    }
} else {
    Write-OK "MSYS2 already extracted, skipping"
}

# ============================================================================
# [4/10] Create clean pacman.conf (only msys + mingw64)
# ============================================================================
Write-Step "4/10" "Creating clean pacman.conf..."

$pacmanConf = @"
[options]
HoldPkg     = pacman
Architecture = auto
Color
CheckSpace
ParallelDownloads = 5
SigLevel    = Required
LocalFileSigLevel = Optional

[msys]
Include = /etc/pacman.d/mirrorlist.msys

[mingw64]
Include = /etc/pacman.d/mirrorlist.mingw64
"@

$pacmanConfPath = Join-Path $MSYS2_DIR "etc\pacman.conf"
[System.IO.File]::WriteAllText($pacmanConfPath, $pacmanConf, [System.Text.UTF8Encoding]::new($false))
Write-OK "pacman.conf created"

# ============================================================================
# [5/10] Create mirrorlist files
# ============================================================================
Write-Step "5/10" "Creating mirrorlist files..."

$msysMirror = @"
Server = https://repo.msys2.org/msys/x86_64/
Server = https://mirror.msys2.org/msys/x86_64/
Server = https://mirror.yandex.ru/mirrors/msys2/msys/x86_64/
"@
[System.IO.File]::WriteAllText((Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.msys"), $msysMirror, [System.Text.UTF8Encoding]::new($false))

$mingw64Mirror = @"
Server = https://repo.msys2.org/mingw/mingw64/
Server = https://mirror.msys2.org/mingw/mingw64/
Server = https://mirror.yandex.ru/mirrors/msys2/mingw/mingw64/
"@
[System.IO.File]::WriteAllText((Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.mingw64"), $mingw64Mirror, [System.Text.UTF8Encoding]::new($false))

# Remove any stale mirrorlist files from previous runs
Remove-Item (Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.clang64") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.clangarm64") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.ucrt64") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.mingw32") -Force -ErrorAction SilentlyContinue

Write-OK "Mirrorlist files created"

# ============================================================================
# [6/10] Initialize MSYS2 (keyring + system update)
# ============================================================================
Write-Step "6/10" "Initializing MSYS2 (first run + update, may take 5-10 min)..."

$bash = Join-Path $MSYS2_DIR "usr\bin\bash.exe"

if (-not $SkipInit) {
    try {
        # First run: initialize user profile
        Write-Info "First run: initializing MSYS2 environment..."
        & $bash -lc "exit" | Out-Null
        Start-Sleep -Seconds 5

        # Refresh keys (ignore GPG warnings about trust database)
        Write-Info "Refreshing pacman keyring..."
        & $bash -lc "pacman-key --init" 2>&1 | Out-Null
        & $bash -lc "pacman-key --populate msys2" 2>&1 | Out-Null
        # NOTE: GPG warnings about trust database expiry are harmless - ignore exit code

        # Pass 1: core system update with disabled download timeout
        Write-Info "Pass 1: core system update..."
        $retryCount = 0
        $maxRetries = 3
        while ($retryCount -lt $maxRetries) {
            $output = & $bash -lc "pacman -Syu --noconfirm --disable-download-timeout" 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            $retryCount++
            if ($retryCount -lt $maxRetries) {
                Write-Info "Pass 1 failed (attempt $retryCount/$maxRetries), retrying in 10s..."
                Start-Sleep -Seconds 10
            } else {
                Write-Host "Pass 1 output:" -ForegroundColor Yellow
                $output | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
                throw "Pass 1 failed after $maxRetries attempts"
            }
        }
        Write-OK "Pass 1 complete"

        # Pass 2: remaining packages (non-fatal if fails)
        Write-Info "Pass 2: remaining packages..."
        & $bash -lc "pacman -Su --noconfirm --disable-download-timeout" 2>&1 | Out-Null
        Write-OK "MSYS2 initialized"
    } catch {
        Write-Fail "MSYS2 initialization failed: $_"
    }
}

# ============================================================================
# [7/10] Install system packages (tesseract, ghostscript, python, pip)
# ============================================================================
Write-Step "7/10" "Installing system packages..."
try {
    $packages = "mingw-w64-x86_64-tesseract-ocr mingw-w64-x86_64-ghostscript mingw-w64-x86_64-python mingw-w64-x86_64-python-pip"
    $output = & $bash -lc "pacman -S --noconfirm --needed $packages" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "pacman output:" -ForegroundColor Yellow
        $output | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
        throw "pacman install failed"
    }

    # Verify critical binaries
    $required = @{
        "tesseract" = (Join-Path $MSYS2_DIR "mingw64\bin\tesseract.exe")
        "python"    = (Join-Path $MSYS2_DIR "mingw64\bin\python.exe")
        "gswin64c"  = (Join-Path $MSYS2_DIR "mingw64\bin\gswin64c.exe")
    }
    $missing = @()
    foreach ($kv in $required.GetEnumerator()) {
        if (-not (Test-Path $kv.Value)) {
            $missing += "$($kv.Key) (expected: $($kv.Value))"
        }
    }
    if ($missing.Count -gt 0) {
        throw "Missing binaries after install: $($missing -join ', ')"
    }

    Write-OK "System packages installed (tesseract, python, ghostscript verified)"
} catch {
    Write-Fail "Failed to install system packages: $_"
}

# ============================================================================
# [8/10] Install Python packages via pip (with --break-system-packages)
# ============================================================================
Write-Step "8/10" "Installing Python packages via pip..."
try {
    $python = Join-Path $MSYS2_DIR "mingw64\bin\python.exe"

    if (-not (Test-Path $python)) {
        Write-Fail "python.exe not found at $python. Step [7/10] must have failed."
    }

    # Bootstrap pip (in case ensurepip wasn't triggered)
    Write-Info "Ensuring pip is available..."
    & $bash -lc "/mingw64/bin/python -m ensurepip --upgrade" 2>&1 | Out-Null
    & $bash -lc "/mingw64/bin/python -m pip install --upgrade pip --break-system-packages" 2>&1 | Out-Null

    # Install main packages with --break-system-packages (PEP 668 workaround)
    $pyPackages = "pymupdf4llm 'markitdown[all]' watchdog ocrmypdf pikepdf img2pdf"
    Write-Info "Installing: $pyPackages"
    $output = & $bash -lc "/mingw64/bin/python -m pip install --no-cache-dir --break-system-packages $pyPackages" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "pip output:" -ForegroundColor Yellow
        $output | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
        throw "pip install failed"
    }

    # Verify imports
    $verifyOut = & $bash -lc "/mingw64/bin/python -c 'import pymupdf4llm, markitdown, watchdog, ocrmypdf; print(\"all-imports-OK\")'" 2>&1
    if ($verifyOut -notmatch "all-imports-OK") {
        throw "Import verification failed: $verifyOut"
    }

    Write-OK "Python packages installed and verified (incl. ocrmypdf via pip)"
} catch {
    Write-Fail "Failed to install Python packages: $_"
}

# ============================================================================
# [9/10] Download Tesseract language models (6 languages)
# ============================================================================
Write-Step "9/10" "Downloading language models (eng, rus, fra, deu, chi_sim, jpn)..."

if (-not (Test-Path $TESSDATA_DIR)) {
    New-Item -ItemType Directory -Force -Path $TESSDATA_DIR | Out-Null
}

$languages = @("eng","rus","fra","deu","chi_sim","jpn")
$baseUrl = "https://github.com/tesseract-ocr/tessdata/raw/main"

foreach ($lang in $languages) {
    $dest = Join-Path $TESSDATA_DIR "$lang.traineddata"
    $needsDownload = $false

    if (-not (Test-Path $dest)) {
        $needsDownload = $true
    } else {
        $fileSize = (Get-Item $dest).Length
        if ($fileSize -lt 1MB) {
            $needsDownload = $true
        }
    }

    if ($needsDownload) {
        Write-Info "Downloading $lang..."
        try {
            Invoke-WebRequest -Uri "$baseUrl/$lang.traineddata" -OutFile $dest -UseBasicParsing
        } catch {
            Write-Host "WARNING: Failed to download $lang" -ForegroundColor Yellow
        }
    }
}
Write-OK "Language models ready"

# ============================================================================
# [10/10] Generate watcher.py, convert_pdf.py, launcher.bat
# ============================================================================
Write-Step "10/10" "Generating Python scripts and launcher..."

# --- watcher.py (native Windows paths via env vars) ---
$watcherPy = @'
#!/usr/bin/env python3
"""
mark-dawn watcher: monitors Inbox folder and converts new files to Markdown.
Native Windows version - uses MARK_DAWN_* env vars for paths.
"""
import os, sys, time, subprocess
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

DATA_DIR     = Path(os.environ.get("MARK_DAWN_DATA", os.path.expanduser("~/mark-dawn/data")))
SCRIPTS_DIR  = Path(os.environ.get("MARK_DAWN_SCRIPTS", DATA_DIR.parent / "scripts"))
LOG_FILE     = Path(os.environ.get("MARK_DAWN_LOG", DATA_DIR.parent / "logs" / "mark-dawn.log"))

INBOX    = DATA_DIR / "Inbox"
RESEARCH = DATA_DIR / "Research"
FAILED   = DATA_DIR / "Inbox_Failed"
CONVERT_SCRIPT = SCRIPTS_DIR / "convert_pdf.py"
DEBOUNCE = 3.0

SUPPORTED = {".pdf", ".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

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

class InboxHandler(FileSystemEventHandler):
    def __init__(self):
        self.pending = {}

    def _touch(self, p):
        p = Path(p)
        if p.suffix.lower() in SUPPORTED and not p.name.startswith("~"):
            self.pending[p] = time.time()

    def on_created(self, e):
        if not e.is_directory:
            self._touch(e.src_path)
            log(f"New file detected: {Path(e.src_path).name}")

    def on_moved(self, e):
        if not e.is_directory:
            self._touch(e.dest_path)

    def on_modified(self, e):
        if not e.is_directory:
            self._touch(e.src_path)

def process_file(file_path: Path):
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
        elif ext in SUPPORTED:
            env = os.environ.copy()
            env["PYTHONIOENCODING"] = "utf-8"
            result = subprocess.run(
                ["markitdown", str(file_path)],
                capture_output=True, text=True, timeout=120, env=env
            )
            if result.returncode == 0 and result.stdout:
                out_file.write_text(result.stdout, encoding="utf-8")
                file_path.unlink(missing_ok=True)
                log(f"OK: {file_path.name} -> {out_file.name}")
                return True
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

    pid_file = Path(os.environ.get("MARK_DAWN_PID", DATA_DIR.parent / "mark-dawn.pid"))
    try:
        pid_file.write_text(str(os.getpid()))
    except Exception:
        pass

    handler = InboxHandler()
    observer = Observer()
    observer.schedule(handler, str(INBOX), recursive=False)
    observer.start()

    log(f"mark-dawn watcher started (PID {os.getpid()})")
    log(f"Watching: {INBOX}")
    log(f"Output:   {RESEARCH}")

    try:
        while True:
            time.sleep(1.0)
            now = time.time()
            ready = [p for p, t in list(handler.pending.items())
                     if now - t >= DEBOUNCE and p.exists()]
            if ready:
                for p in ready:
                    handler.pending.pop(p, None)
                    log(f"Processing: {p.name}")
                    process_file(p)
    except KeyboardInterrupt:
        log("Stopping watcher...")
        observer.stop()
    observer.join()

    try:
        pid_file.unlink(missing_ok=True)
    except Exception:
        pass

if __name__ == "__main__":
    main()
'@

[System.IO.File]::WriteAllText(
    (Join-Path $SCRIPTS_DIR "watcher.py"),
    $watcherPy,
    [System.Text.UTF8Encoding]::new($false)
)

# --- convert_pdf.py (native Windows paths) ---
$convertPdfPy = @'
#!/usr/bin/env python3
"""
mark-dawn PDF converter: digital PDFs via pymupdf4llm, scanned via ocrmypdf.
Native Windows version - uses MARK_DAWN_DATA env var for paths.
"""
import os, sys, subprocess, tempfile
from pathlib import Path
import fitz
import pymupdf4llm

DATA_DIR  = Path(os.environ.get("MARK_DAWN_DATA", os.path.expanduser("~/mark-dawn/data")))
RESEARCH  = DATA_DIR / "Research"
RESEARCH.mkdir(parents=True, exist_ok=True)

file_path = Path(sys.argv[1])
out_file  = RESEARCH / f"{file_path.stem}.md"

try:
    doc = fitz.open(str(file_path))
    num_pages = len(doc)
    text_len = sum(len(page.get_text()) for page in doc)
    doc.close()

    avg_chars = text_len / num_pages if num_pages > 0 else 0

    if avg_chars > 100:
        md_text = pymupdf4llm.to_markdown(str(file_path))
        out_file.write_text(md_text, encoding="utf-8")
        print(f"Digital PDF ({int(avg_chars)} chars/page). Converted via pymupdf4llm.")
        sys.exit(0)
    else:
        print(f"Scanned PDF ({int(avg_chars)} chars/page). Falling back to ocrmypdf...")
        with tempfile.TemporaryDirectory() as tmp_dir:
            ocr_output = Path(tmp_dir) / file_path.name
            env = os.environ.copy()
            env["PYTHONIOENCODING"] = "utf-8"

            cmd = [
                "ocrmypdf",
                "--skip-text",
                "-l", "eng+rus+fra+deu+chi_sim+jpn",
                "-j", "1",
                "--output-type", "pdf",
                str(file_path),
                str(ocr_output)
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=600)
            if result.returncode != 0:
                print(f"ocrmypdf failed (exit {result.returncode}):", file=sys.stderr)
                print(result.stderr[-1500:] if len(result.stderr) > 1500 else result.stderr, file=sys.stderr)
                sys.exit(1)
            if not ocr_output.exists():
                print("ocrmypdf did not produce output file", file=sys.stderr)
                sys.exit(1)

            md_text = pymupdf4llm.to_markdown(str(ocr_output))
            out_file.write_text(md_text, encoding="utf-8")
            print("ocrmypdf + pymupdf4llm completed successfully.")
            sys.exit(0)

except subprocess.TimeoutExpired:
    print("Timeout: ocrmypdf took more than 10 minutes", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Fatal error: {e}", file=sys.stderr)
    sys.exit(1)
'@

[System.IO.File]::WriteAllText(
    (Join-Path $SCRIPTS_DIR "convert_pdf.py"),
    $convertPdfPy,
    [System.Text.UTF8Encoding]::new($false)
)

# --- launcher.bat (commands match Linux version) ---
$launcher = @"
@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM mark-dawn launcher for Windows
REM Commands match Linux version: start, stop, restart, convert, logs, status,
REM                                update, install-task, uninstall-task, help
REM ============================================================================

REM Resolve install directory from script location
set "INSTALL_DIR=%~dp0"
set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"

REM Generic paths (relative to install dir)
set "MSYS2_DIR=%INSTALL_DIR%\msys64"
set "DATA_DIR=%INSTALL_DIR%\data"
set "SCRIPTS_DIR=%INSTALL_DIR%\scripts"
set "LOGS_DIR=%INSTALL_DIR%\logs"
set "PID_FILE=%INSTALL_DIR%\mark-dawn.pid"
set "LOG_FILE=%LOGS_DIR%\mark-dawn.log"
set "PYTHON=%MSYS2_DIR%\mingw64\bin\python.exe"

REM Set environment variables consumed by Python scripts
set "MARK_DAWN_DATA=%DATA_DIR%"
set "MARK_DAWN_SCRIPTS=%SCRIPTS_DIR%"
set "MARK_DAWN_LOG=%LOG_FILE%"
set "MARK_DAWN_PID=%PID_FILE%"
set "TESSDATA_PREFIX=%MSYS2_DIR%\mingw64\share\tessdata"
set "PATH=%MSYS2_DIR%\mingw64\bin;%MSYS2_DIR%\usr\bin;%PATH%"
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
    start "" /B "%PYTHON%" "%SCRIPTS_DIR%\watcher.py" >> "%LOG_FILE%" 2>&1
    timeout /t 2 /nobreak > nul
    if exist "%PID_FILE%" (
        set /p PID=<"%PID_FILE%"
        echo OK: mark-dawn started (PID !PID!)
    ) else (
        echo OK: mark-dawn started
    )
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
    taskkill /PID %PID% /F > nul 2>&1
    del "%PID_FILE%" > nul 2>&1
    echo OK: mark-dawn stopped
    goto end

:restart
    call :stop
    timeout /t 2 /nobreak > nul
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
    "%PYTHON%" "%SCRIPTS_DIR%\convert_pdf.py" "%~f2"
    goto end

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
    tasklist /FI "PID eq %PID%" 2>nul | find "%PID%" >nul
    if errorlevel 1 (
        echo mark-dawn is not running (stale PID file, cleaning up)
        del "%PID_FILE%" > nul 2>&1
    ) else (
        echo mark-dawn is running (PID %PID%)
        echo    Inbox:    %DATA_DIR%\Inbox
        echo    Research: %DATA_DIR%\Research
        echo    Logs:     %LOG_FILE%
    )
    goto end

:update
    echo Updating Python packages...
    "%PYTHON%" -m pip install --upgrade --break-system-packages pymupdf4llm "markitdown[all]" watchdog ocrmypdf pikepdf img2pdf
    echo OK: Update complete. Restart the watcher with: mark-dawn.bat restart
    goto end

:install_task
    echo Creating Task Scheduler entry for auto-start on login...
    net session >nul 2>&1
    if errorlevel 1 (
        echo FAIL: install-task requires administrator rights
        echo Right-click PowerShell and select "Run as Administrator"
        exit /b 1
    )
    schtasks /Create /TN "mark-dawn" /TR "\"%INSTALL_DIR%\mark-dawn.bat\" start" /SC ONLOGON /RL HIGHEST /F
    schtasks /Run /TN "mark-dawn"
    echo OK: Task Scheduler entry created and started
    goto end

:uninstall_task
    net session >nul 2>&1
    if errorlevel 1 (
        echo FAIL: uninstall-task requires administrator rights
        exit /b 1
    )
    schtasks /Delete /TN "mark-dawn" /F
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
    echo Directories (relative to install root):
    echo   data\Inbox         - Drop files here for auto-conversion
    echo   data\Research      - Converted Markdown files appear here
    echo   data\Inbox_Failed  - Failed conversions moved here
    echo   logs\              - Log files
    goto end

:end
endlocal
exit /b 0
"@

[System.IO.File]::WriteAllText(
    $LAUNCHER_PATH,
    $launcher,
    [System.Text.UTF8Encoding]::new($false)
)

Write-OK "Python scripts and launcher generated"

# ============================================================================
# Final summary
# ============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " mark-dawn installed successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Location:  $InstallDir" -ForegroundColor Cyan
Write-Host "Launcher:  $LAUNCHER_PATH" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open Command Prompt or PowerShell"
Write-Host "  2. Run:  & `"$LAUNCHER_PATH`" start"
Write-Host "  3. Drop files into: $DATA_DIR\Inbox"
Write-Host "  4. Results appear in: $DATA_DIR\Research"
Write-Host ""
Write-Host "Management commands:" -ForegroundColor Yellow
Write-Host "  & `"$LAUNCHER_PATH`" status"
Write-Host "  & `"$LAUNCHER_PATH`" logs"
Write-Host "  & `"$LAUNCHER_PATH`" stop"
Write-Host "  & `"$LAUNCHER_PATH`" update"
Write-Host ""
Write-Host "Auto-start on login (requires Admin PowerShell):" -ForegroundColor Yellow
Write-Host "  & `"$LAUNCHER_PATH`" install-task"
