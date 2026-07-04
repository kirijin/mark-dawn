<#
.SYNOPSIS
    mark-dawn portable installer for Windows (MSYS2-based, no WSL required)
.DESCRIPTION
    Installs mark-dawn as a fully portable application in %USERPROFILE%\mark-dawn.
    Compatible with Windows PowerShell 5.1 (default) and PowerShell 7+.
.NOTES
    Requires: Windows 10/11 x64. No admin rights required (except for install-task).
#>

param(
    [string]$InstallDir = "",
    [switch]$SkipInit,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Helper functions (English messages, PS 5.1 compatible)
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

# ============================================================================
# [1/9] Resolve installation directory (generic, no admin required)
# ============================================================================
Write-Step "1/9" "Resolving installation directory..."

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:USERPROFILE "mark-dawn"
}

# PS 5.1 compatible: no ?? operator
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
# [2/9] Download MSYS2 SFX archive (portable self-extracting)
# ============================================================================
Write-Step "2/9" "Downloading MSYS2 SFX archive (~100 MB)..."

$msys2Installer = Join-Path $env:TEMP "msys2-base-x86_64-latest.sfx.exe"
# Primary: nightly (always latest). Fallback: stable release if nightly fails.
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
            # Sanity check: SFX should be > 50 MB
            if ((Get-Item $msys2Installer).Length -gt 50MB) {
                $downloaded = $true
                break
            } else {
                Remove-Item $msys2Installer -Force
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
# [3/9] Extract MSYS2 silently via SFX (-y = auto-confirm, -o = output dir)
# ============================================================================
Write-Step "3/9" "Extracting MSYS2 (this takes 2-3 minutes)..."

$bashExe = Join-Path $MSYS2_DIR "usr\bin\bash.exe"
if (-not (Test-Path $bashExe)) {
    try {
        # SFX creates 'msys2' subfolder inside -o target, so point -o to InstallDir
        $sfxArgs = @("-y", "-o`"$InstallDir`"")
        Write-Info "Running: $msys2Installer $sfxArgs"
        
        $proc = Start-Process -FilePath $msys2Installer `
            -ArgumentList $sfxArgs `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "SFX extraction failed with code $($proc.ExitCode)"
        }
        
        # Verify extraction produced expected structure
        if (-not (Test-Path $bashExe)) {
            throw "bash.exe not found after extraction at $bashExe"
        }
        
        # Cleanup the SFX installer (no longer needed)
        Remove-Item $msys2Installer -Force -ErrorAction SilentlyContinue
        
        Write-OK "MSYS2 extracted to $MSYS2_DIR"
    } catch {
        Write-Fail "Failed to extract MSYS2: $_"
    }
} else {
    Write-OK "MSYS2 already extracted, skipping"
}

# ============================================================================
# [4/9] Initialize MSYS2 (create clean pacman.conf + mirrorlists)
# ============================================================================
Write-Step "4/9" "Initializing MSYS2 (creating clean config)..."

$bash = Join-Path $MSYS2_DIR "usr\bin\bash.exe"

if (-not $SkipInit) {
    try {
        # First run: initialize pacman keyring
        Write-Info "First run: initializing MSYS2 environment..."
        & $bash -lc "exit" | Out-Null
        Start-Sleep -Seconds 5

        # Overwrite pacman.conf with minimal clean config (no awk, no complex quoting)
        Write-Info "Creating clean pacman.conf (msys + mingw64 only)..."
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
        # Write via PowerShell file API (avoids bash quoting hell)
        $pacmanConfPath = Join-Path $MSYS2_DIR "etc\pacman.conf"
        [System.IO.File]::WriteAllText($pacmanConfPath, $pacmanConf, [System.Text.UTF8Encoding]::new($false))
        Write-OK "pacman.conf created"

        # Create mirrorlist.msys
        Write-Info "Creating mirrorlist files..."
        $msysMirror = @"
Server = https://repo.msys2.org/msys/x86_64/
Server = https://mirror.msys2.org/msys/x86_64/
Server = https://mirror.yandex.ru/mirrors/msys2/msys/x86_64/
"@
        [System.IO.File]::WriteAllText((Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.msys"), $msysMirror, [System.Text.UTF8Encoding]::new($false))

        # Create mirrorlist.mingw64
        $mingw64Mirror = @"
Server = https://repo.msys2.org/mingw/mingw64/
Server = https://mirror.msys2.org/mingw/mingw64/
Server = https://mirror.yandex.ru/mirrors/msys2/mingw/mingw64/
"@
        [System.IO.File]::WriteAllText((Join-Path $MSYS2_DIR "etc\pacman.d\mirrorlist.mingw64"), $mingw64Mirror, [System.Text.UTF8Encoding]::new($false))
        Write-OK "Mirrorlist files created"

        # Refresh keyring
        Write-Info "Refreshing pacman keyring..."
        & $bash -lc "pacman-key --init" 2>&1 | Out-Null
        & $bash -lc "pacman-key --populate msys2" 2>&1 | Out-Null

        # Pass 1: core update
        Write-Info "Pass 1: core system update..."
        $output = & $bash -lc "pacman -Syu --noconfirm --disable-download-timeout" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Pass 1 output: $output" -ForegroundColor Yellow
            throw "Pass 1 failed"
        }
        Write-OK "Pass 1 complete"

        # Pass 2: remaining
        Write-Info "Pass 2: remaining packages..."
        & $bash -lc "pacman -Su --noconfirm --disable-download-timeout" 2>&1 | Out-Null
        Write-OK "MSYS2 initialized"
    } catch {
        Write-Fail "MSYS2 initialization failed: $_"
    }
}

# ============================================================================
# [5/9] Install system packages (tesseract, ghostscript, python, pip)
# ============================================================================
Write-Step "5/9" "Installing system packages..."
try {
    & $bash -lc "pacman -S --noconfirm --needed mingw-w64-x86_64-tesseract-ocr mingw-w64-x86_64-ghostscript mingw-w64-x86_64-python mingw-w64-x86_64-python-pip"
    if ($LASTEXITCODE -ne 0) { throw "pacman install failed" }
    Write-OK "System packages installed"
} catch {
    Write-Fail "Failed to install system packages: $_"
}

# ============================================================================
# [6/9] Install Python packages via pip (pymupdf, ocrmypdf, etc.)
# ============================================================================
Write-Step "6/9" "Installing Python packages via pip..."
try {
    & $bash -lc "/mingw64/bin/python -m pip install --no-cache-dir pymupdf4llm 'markitdown[all]' watchdog ocrmypdf pikepdf img2pdf"
    if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

    # Verify imports
    $verify = & $bash -lc "/mingw64/bin/python -c 'import pymupdf4llm, markitdown, watchdog, ocrmypdf; print(\"OK\")'" 2>&1
    if ($verify -notmatch "OK") { throw "Import verification failed: $verify" }
    Write-OK "Python packages installed and verified"
} catch {
    Write-Fail "Failed to install Python packages: $_"
}

# ============================================================================
# [7/9] Download Tesseract language models (6 languages)
# ============================================================================
Write-Step "7/9" "Downloading language models (eng, rus, fra, deu, chi_sim, jpn)..."
$tessdata = Join-Path $MSYS2_DIR "mingw64\share\tessdata"
$baseUrl = "https://github.com/tesseract-ocr/tessdata/raw/main"
foreach ($lang in @("eng","rus","fra","deu","chi_sim","jpn")) {
    $dest = Join-Path $tessdata "$lang.traineddata"
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1MB) {
        Write-Info "Downloading $lang..."
        Invoke-WebRequest -Uri "$baseUrl/$lang.traineddata" -OutFile $dest -UseBasicParsing
    }
}
Write-OK "Language models ready"

# ============================================================================
# [8/9] Generate Python scripts
# ============================================================================
Write-Step "8/9" "Generating watcher.py and convert_pdf.py..."

# watcher.py content
$watcherPy = @'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
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
CONVERT_SCRIPT = SCRIPTS_DIR / "convert_pdf.py"
DEBOUNCE     = 3.0

SUPPORTED = {".pdf", ".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
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

    pid_file = Path(os.environ.get("MARK_DAWN_PID", SCRIPTS_DIR.parent / "mark-dawn.pid"))
    pid_file.write_text(str(os.getpid()))

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

$watcherPy | Out-File -FilePath (Join-Path $SCRIPTS_DIR "watcher.py") -Encoding utf8

# convert_pdf.py content
$convertPdfPy = @'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, subprocess, tempfile
from pathlib import Path
import fitz
import pymupdf4llm

DATA_DIR  = Path(os.environ.get("MARK_DAWN_DATA", os.path.expanduser("~/Documents")))
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
                print(result.stderr[-1500:], file=sys.stderr)
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

$convertPdfPy | Out-File -FilePath (Join-Path $SCRIPTS_DIR "convert_pdf.py") -Encoding utf8

Write-OK "Python scripts generated"

# ============================================================================
# [9/9] Generate launcher (mark-dawn.bat)
# ============================================================================
Write-Step "9/9" "Generating mark-dawn.bat launcher..."

$launcher = @"
@echo off
setlocal enabledelayedexpansion

set "INSTALL_DIR=%~dp0"
set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"

set "MSYS2_DIR=%INSTALL_DIR%\msys64"
set "DATA_DIR=%INSTALL_DIR%\data"
set "SCRIPTS_DIR=%INSTALL_DIR%\scripts"
set "LOGS_DIR=%INSTALL_DIR%\logs"
set "PID_FILE=%INSTALL_DIR%\mark-dawn.pid"
set "LOG_FILE=%LOGS_DIR%\mark-dawn.log"
set "PYTHON=%MSYS2_DIR%\mingw64\bin\python.exe"

set "MARK_DAWN_DATA=%DATA_DIR%"
set "MARK_DAWN_SCRIPTS=%SCRIPTS_DIR%"
set "MARK_DAWN_LOG=%LOG_FILE%"
set "MARK_DAWN_PID=%PID_FILE%"
set "TESSDATA_PREFIX=%MSYS2_DIR%\mingw64\share\tessdata"
set "PATH=%MSYS2_DIR%\mingw64\bin;%MSYS2_DIR%\usr\bin;%PATH%"
set "PYTHONIOENCODING=utf-8"

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
    echo Updating MSYS2 packages and Python dependencies...
    "%MSYS2_DIR%\usr\bin\bash.exe" -lc "pacman -Syu --noconfirm"
    "%MSYS2_DIR%\mingw64\bin\python.exe" -m pip install --upgrade pymupdf4llm "markitdown[all]" watchdog
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
    echo   update             Update MSYS2 packages and Python dependencies
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

$launcher | Out-File -FilePath $LAUNCHER_PATH -Encoding ascii

Write-OK "Launcher generated: $LAUNCHER_PATH"

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
Write-Host "Auto-start on login (requires Admin):" -ForegroundColor Yellow
Write-Host "  & `"$LAUNCHER_PATH`" install-task"
