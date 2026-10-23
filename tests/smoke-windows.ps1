# mark-dawn Windows VM smoke test harness
# Run inside the Windows 11 VM (PowerShell, admin not required).
# Output: C:\mark-dawn-smoke\result.txt  (copy back to host via SPICE shared folder or RDP clipboard)

$ErrorActionPreference = "Stop"
$base = "C:\mark-dawn-smoke"
New-Item -ItemType Directory -Force -Path "$base\Inbox","$base\Research","$base\Inbox_Failed" | Out-Null

# --- 1. Ensure Python 3.12+ is available ---
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    # Try winget (Windows 10 1709+ / Windows 11)
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Installing Python 3.12 via winget..."
        & winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $py = Get-Command python -ErrorAction SilentlyContinue
    }
}
if (-not $py) {
    Write-Host "Python not found and could not be auto-installed."
    Write-Host "Install Python 3.12 from https://www.python.org/downloads/ (check 'Add python.exe to PATH'), then re-run."
    "FAIL: python missing" | Out-File "$base\result.txt"
    exit 1
}
$ver = & python -c "import sys; print(sys.version)" 2>&1
if ($ver -match "was not found|Microsoft Store") {
    Write-Host "Python is the Microsoft Store stub. Installing via winget..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        & winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Host "Python not installed. Install from https://www.python.org/downloads/ (check 'Add python.exe to PATH'), then re-run."
        "FAIL: python missing" | Out-File "$base\result.txt"
        exit 1
    }
    $ver = & python -c "import sys; print(sys.version)" 2>&1
}
Write-Host "Python: $ver"

# --- 2. Install / refresh mark-dawn ---
$repo = "C:\mark-dawn"
if (-not (Test-Path "$repo\convert_pdf.py")) {
    # Fetch via the GitHub raw URL (requires internet in the VM)
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    foreach ($f in @("convert_pdf.py","docx_styler.py","watcher.py","requirements.txt")) {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/kirijin/mark-dawn/main/$f" -OutFile "$repo\$f" -UseBasicParsing
    }
}

# --- 3. Install Python deps (into the active interpreter) ---
& python -m pip install --quiet --upgrade pip 2>&1 | Out-Null
& python -m pip install --quiet -r "$repo\requirements.txt" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    # fall back: install individually
    & python -m pip install --quiet pymupdf rapidocr onnxruntime markitdown python-docx watchdog 2>&1 | Out-Null
}

# --- 4. Generate a fixture PDF (>100 chars/page -> digital path) ---
$fixture = "$base\Inbox\fixture.pdf"
& python -c "import fitz; d=fitz.open(); p=d.new_page(); p.insert_textbox(fitz.Rect(72,72,523,700), 'Hello mark-dawn smoke test ' * 40); d.save('$fixture')" 2>&1 | Out-Null
if (-not (Test-Path $fixture)) {
    "FAIL: could not generate fixture.pdf" | Out-File "$base\result.txt"
    exit 1
}

# --- 5. Convert ---
$env:MARK_DAWN_OUT_DIR = "$base\Research"
$env:MARK_DAWN_FAILED_DIR = "$base\Inbox_Failed"
& python "$repo\convert_pdf.py" $fixture 2>&1 | Tee-Object -FilePath "$base\convert.log"

# --- 6. Verify ---
$out = "$base\Research\fixture.md"
if (Test-Path $out -and (Get-Item $out).Length -gt 0) {
    "PASS: smoke test succeeded. Output: $out ($((Get-Item $out).Length) bytes)" | Out-File "$base\result.txt"
    Get-Content $out | Select-Object -First 3 | Out-File "$base\result.txt" -Append
} else {
    "FAIL: no output produced. See $base\convert.log" | Out-File "$base\result.txt"
}
Write-Host "=== RESULT ==="
Get-Content "$base\result.txt"