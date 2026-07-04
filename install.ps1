<#
.SYNOPSIS
    mark-dawn portable installer for Windows (MSYS2-based, no WSL required)
.DESCRIPTION
    One-command install. No admin rights required (except for install-task).
    Compatible with Windows PowerShell 5.1+.
#>

param(
    [string]$InstallDir = "",
    [switch]$Help
)

# Continue on warnings, but use explicit error checking for critical commands
$ErrorActionPreference = "Continue"

function Write-Step  { param([string]$n,[string]$m) Write-Host "[$n] " -ForegroundColor Cyan -NoNewline; Write-Host $m }
function Write-OK    { param([string]$m) Write-Host "OK: $m" -ForegroundColor Green }
function Write-Info  { param([string]$m) Write-Host ">> $m" -ForegroundColor Yellow }
function Write-Fail  { param([string]$m) Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

if ($Help) {
    Write-Host "Usage: install.ps1 [-InstallDir <path>]"
    Write-Host "Default install dir: %USERPROFILE%\mark-dawn"
    exit 0
}

# ============================================================================
# [1/8] Resolve installation directory
# ============================================================================
Write-Step "1/8" "Resolving installation directory..."

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:USERPROFILE "mark-dawn"
}

$resolved = Resolve-Path $InstallDir -ErrorAction SilentlyContinue
if ($resolved) { $InstallDir = $resolved.Path }

$MSYS2_DIR    = Join-Path $InstallDir "msys64"
$DATA_DIR     = Join-Path $InstallDir "data"
$SCRIPTS_DIR  = Join-Path $InstallDir "scripts"
$LOGS_DIR     = Join-Path $InstallDir "logs"
$TESSDATA_DIR = Join-Path $MSYS2_DIR "mingw64\share\tessdata"
$LAUNCHER     = Join-Path $InstallDir "mark-dawn.bat"

try {
    New-Item -ItemType Directory -Force -Path $InstallDir, $DATA_DIR, $SCRIPTS_DIR, $LOGS_DIR | Out-Null
} catch {
    Write-Fail "Cannot write to $InstallDir"
}
Write-OK "Install directory: $InstallDir"

# ============================================================================
# [2/8] Download MSYS2 SFX archive
# ============================================================================
Write-Step "2/8" "Downloading MSYS2 SFX (~100 MB)..."

$sfxPath = Join-Path $env:TEMP "msys2-base-x86_64-latest.sfx.exe"
$sfxUrls = @(
    "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe",
    "https://github.com/msys2/msys2-installer/releases/download/2025-02-21/msys2-base-x86_64-latest.sfx.exe"
)

if (-not (Test-Path $sfxPath) -or (Get-Item $sfxPath).Length -lt 50MB) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloaded = $false
    foreach ($url in $sfxUrls) {
        try {
            Write-Info "Trying: $url"
            Invoke-WebRequest -Uri $url -OutFile $sfxPath -UseBasicParsing
            if ((Get-Item $sfxPath).Length -gt 50MB) {
                $downloaded = $true
                break
            }
            Remove-Item $sfxPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Info "Failed, trying fallback..."
            Remove-Item $sfxPath -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $downloaded) { Write-Fail "Failed to download MSYS2" }
}
Write-OK "MSYS2 SFX ready"

# ============================================================================
# [3/8] Extract MSYS2
# ============================================================================
Write-Step "3/8" "Extracting MSYS2 (2-3 minutes)..."

$bashExe = Join-Path $MSYS2_DIR "usr\bin\bash.exe"
if (-not (Test-Path $bashExe)) {
    try {
        $proc = Start-Process -FilePath $sfxPath -ArgumentList "-y", "-o`"$InstallDir`"" -Wait -PassThru -NoNewWindow
        if (-not (Test-Path $bashExe)) {
            Write-Fail "Extraction failed — bash.exe not found at $bashExe"
        }
        Remove-Item $sfxPath -Force -ErrorAction SilentlyContinue
        Write-OK "MSYS2 extracted"
    } catch {
        Write-Fail "Extraction failed: $_"
    }
} else {
    Write-OK "MSYS2 already extracted"
}

$bash = $bashExe

# ============================================================================
# [4/8] Initialize MSYS2 (first run + keyring)
# ============================================================================
Write-Step "4/8" "Initializing MSYS2 (first run)..."

try {
    # First run: creates user profile, initializes pacman
    & $bash -lc "exit" 2>$null | Out-Null
    Start-Sleep -Seconds 3

    # Initialize keyring (GPG warnings are harmless — ignore exit code)
    Write-Info "Initializing pacman keyring (may show GPG warnings, this is normal)..."
    & $bash -lc "pacman-key --init" 2>$null | Out-Null
    & $bash -lc "pacman-key --populate msys2" 2>$null | Out-Null
    # Ignore $LASTEXITCODE — GPG trust-db warnings return non-zero but are not errors

    Write-OK "MSYS2 initialized"
} catch {
    Write-Fail "MSYS2 initialization failed: $_"
}

# ============================================================================
# [5/8] Install system packages via pacman
# ============================================================================
Write-Step "5/8" "Installing system packages (tesseract, python, ghostscript)..."

$packages = "mingw-w64-x86_64-tesseract-ocr mingw-w64-x86_64-ghostscript mingw-w64-x86_64-python mingw-w64-x86_64-python-pip"

Write-Info "Running: pacman -Sy --noconfirm --disable-download-timeout"
$output = & $bash -lc "pacman -Sy --noconfirm --disable-download-timeout" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "pacman -Sy failed:" -ForegroundColor Red
    $output | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
    Write-Fail "pacman repository sync failed"
}

Write-Info "Installing packages (this takes 3-5 minutes)..."
$output = & $bash -lc "pacman -S --noconfirm --needed --disable-download-timeout $packages" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "pacman -S failed:" -ForegroundColor Red
    $output | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
    Write-Fail "pacman package install failed"
}

# Verify critical binaries
$pythonExe = Join-Path $MSYS2_DIR "mingw64\bin\python.exe"
$tessExe   = Join-Path $MSYS2_DIR "mingw64\bin\tesseract.exe"
$gsExe     = Join-Path $MSYS2_DIR "mingw64\bin\gswin64c.exe"

$missing = @()
if (-not (Test-Path $pythonExe)) { $missing += "python.exe" }
if (-not (Test-Path $tessExe))   { $missing += "tesseract.exe" }
if (-not (Test-Path $gsExe))     { $missing += "gswin64c.exe" }

if ($missing.Count -gt 0) {
    Write-Fail "Missing binaries after pacman install: $($missing -join ', '). Try re-running the script."
}
Write-OK "System packages installed"

# ============================================================================
# [6/8] Install Python packages via pip
# ============================================================================
Write-Step "6/8" "Installing Python packages (pymupdf4llm, markitdown, ocrmypdf, watchdog)..."

$pyPackages = "pymupdf4llm 'markitdown[all]' watchdog ocrmypdf pikepdf img2pdf"

Write-Info "Installing via pip (this takes 2-5 minutes)..."
$output = & $bash -lc "/mingw64/bin/python -m pip install --break-system-packages --no-cache-dir $pyPackages" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "pip install failed:" -ForegroundColor Red
    $output | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
    Write-Fail "Python pip install failed"
}

# Verify imports
$verifyResult = & $bash -lc "/mingw64/bin/python -c 'import pymupdf4llm, markitdown, watchdog, ocrmypdf; print(\"OK\")'" 2>&1 | Select-Object -Last 1
if ($verifyResult -notmatch "OK") {
    Write-Host "Import verification failed:" -ForegroundColor Red
    Write-Host "  $verifyResult"
    Write-Fail "Python import verification failed"
}
Write-OK "Python packages installed and verified"

# ============================================================================
# [7/8] Download Tesseract language models
# ============================================================================
Write-Step "7/8" "Downloading language models (eng, rus, fra, deu, chi_sim, jpn)..."

if (-not (Test-Path $TESSDATA_DIR)) {
    New-Item -ItemType Directory -Force -Path $TESSDATA_DIR | Out-Null
}

$languages = @("eng","rus","fra","deu","chi_sim","jpn")
$baseUrl = "https://github.com/tesseract-ocr/tessdata/raw/main"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($lang in $languages) {
    $dest = Join-Path $TESSDATA_DIR "$lang.traineddata"
    $needsDownload = $false
    if (-not (Test-Path $dest)) {
        $needsDownload = $true
    } elseif ((Get-Item $dest).Length -lt 1MB) {
        $needsDownload = $true
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
# [8/8] Generate scripts and launcher
# ============================================================================
Write-Step "8/8" "Generating scripts and launcher..."

# --- watcher.py ---
$watcherPy = @'
#!/usr/bin/env python3
"""mark-dawn watcher: monitors Inbox and converts files to Markdown."""
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

$watcherPy | Out-File -FilePath (Join-Path $SCRIPTS_DIR "watcher.py") -Encoding utf8NoBOM

# --- convert_pdf.py ---
$convertPdfPy = @'
#!/usr/bin/env python3
"""mark-dawn PDF converter: digital PDFs via pymupdf4llm, scanned via ocrmypdf."""
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
                stderr = result.stderr or ""
                print(stderr[-1500:] if len(stderr) > 1500 else stderr, file=sys.stderr)
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

$convertPdfPy | Out-File -FilePath (Join-Path $SCRIPTS_DIR "convert_pdf.py") -Encoding utf8NoBOM

# --- mark-dawn.bat (launcher) ---
$launcherBat = @"
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
        echo OK: mark-dawn started (PID !PID!^)
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
    echo Stopping mark-dawn (PID %PID%^)...
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
    echo Showing last 50 lines of %LOG_FILE% (Ctrl+C to exit^)...
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
        echo mark-dawn is not running (stale PID file, cleaning up^)
        del "%PID_FILE%" > nul 2>&1
    ) else (
        echo mark-dawn is running (PID %PID%^)
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
    echo mark-dawn - Universal Document to Markdown Pipeline (Windows Portable^)
    echo.
    echo Usage: mark-dawn.bat ^<command^> [args]
    echo.
    echo Commands:
    echo   start              Start background watcher (watches data\Inbox^)
    echo   stop               Stop background watcher
    echo   restart            Restart watcher
    echo   convert FILE       Convert single file
    echo   logs               Follow logs (last 50 lines + live tail^)
    echo   status             Show watcher status and PID
    echo   update             Update Python dependencies
    echo   install-task       Install auto-start on login (requires Admin^)
    echo   uninstall-task     Remove auto-start entry (requires Admin^)
    echo   help               Show this help message
    echo.
    echo Supported formats: PDF, DOCX, XLSX, PPTX, HTML, CSV, RTF
    echo Supported languages: English, Russian, French, German, Chinese, Japanese
    echo.
    echo Directories (relative to install root^):
    echo   data\Inbox         - Drop files here for auto-conversion
    echo   data\Research      - Converted Markdown files appear here
    echo   data\Inbox_Failed  - Failed conversions moved here
    echo   logs\              - Log files
    goto end

:end
endlocal
exit /b 0
"@

$launcherBat | Out-File -FilePath $LAUNCHER -Encoding ascii

Write-OK "Scripts and launcher generated"

# ============================================================================
# Done
# ============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " mark-dawn installed successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Location:  $InstallDir" -ForegroundColor Cyan
Write-Host "Launcher:  $LAUNCHER" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open Command Prompt or PowerShell"
Write-Host "  2. Run:  & `"$LAUNCHER`" start"
Write-Host "  3. Drop files into: $DATA_DIR\Inbox"
Write-Host "  4. Results appear in: $DATA_DIR\Research"
Write-Host ""
Write-Host "Management commands:" -ForegroundColor Yellow
Write-Host "  & `"$LAUNCHER`" status"
Write-Host "  & `"$LAUNCHER`" logs"
Write-Host "  & `"$LAUNCHER`" stop"
Write-Host "  & `"$LAUNCHER`" update"
