function Step-Init {
    Write-Step "0/13" "Resolving paths and creating directories..."

    if (-not $Script:_installDir) { $Script:_installDir = $Script:DEFAULT_INSTALL_DIR }
    if (-not $Script:_dataDir) { $Script:_dataDir = $Script:DEFAULT_DATA_DIR }

    try {
        $resolved = Resolve-Path $Script:_installDir -ErrorAction SilentlyContinue
        if ($resolved) { $Script:_installDir = $resolved.Path }
    } catch {}

    # Clean up stale aria2c.exe if present (previous broken install)
    $staleAria2 = Join-PathSafe $Script:_installDir "bin\aria2c.exe"
    if (Test-Path $staleAria2 -PathType Leaf) {
        Remove-Item $staleAria2 -Force -ErrorAction SilentlyContinue
        Write-Log "Debug" "Cleaned up stale aria2c.exe" -NoConsole
    }

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
    Write-Step "1/13" "Downloading Python $($Script:PYTHON_VERSION) embedded distribution (~11 MB)..."
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
    Write-Step "2/13" "Downloading get-pip.py..."
    $tempDir = Join-PathSafe $env:TEMP "mark-dawn-installer"
    Ensure-Directory $tempDir
    $getPipPath = Join-PathSafe $tempDir "get-pip.py"

    $lastError = $null
    foreach ($url in $Script:GETPIP_FALLBACK_URLS) {
        try {
            Invoke-DownloadWithRetry -Url $url -OutFile $getPipPath `
                -MaxRetries 2 -TimeoutSec 600 -Force:$Script:ForceRedownload
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
    if ((Get-Item $getPipPath -ErrorAction Stop).Length -lt 100KB) {
        Remove-Item $getPipPath -Force -ErrorAction SilentlyContinue
        Write-Fail "Downloaded get-pip.py looks invalid (too small) — check network/proxy."
    }

    $Script:getPipPath = $getPipPath
    Write-OK "get-pip.py ready (size verified)"
    Set-InstallState -Step "getpip_downloaded" -Status "ok"
}

function Step-ExtractPython {
    Write-Step "3/13" "Extracting Python $($Script:PYTHON_VERSION) embedded..."

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
    Write-Step "4/13" "Installing pip into embedded Python..."

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
    Write-Step "5/13" "Installing Python packages from pinned requirements.txt..."

    try {
        # Download the pinned requirement set shared with the other platforms
        $reqPath = Join-PathSafe $Script:_installDir "requirements.txt"
        Invoke-DownloadWithRetry -Url $Script:REQUIREMENTS_URL -OutFile $reqPath `
            -MaxRetries 2 -TimeoutSec 120
        if ((Get-Item $reqPath -ErrorAction Stop).Length -lt 50) {
            throw "requirements.txt download looks invalid"
        }
        Write-Info "Installing from pinned requirements (all platforms share this file)..."

        $pipArgs = @("-m", "pip", "install", "--no-cache-dir", "-r", $reqPath)
        if ($Script:_pypiMirror) {
            $pipArgs = @("-m", "pip", "install", "--no-cache-dir", "-r", $reqPath, "-i", $Script:_pypiMirror)
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
    Write-Step "6/13" "Downloading MSYS2 base system SFX (~50 MB)..."
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
    Write-Step "7/13" "Extracting MSYS2 base system..."

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

function Step-InitMsys2 {
    Write-Step "8/13" "Initializing MSYS2 pacman keyring (2-3 minutes)..."

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
            Show-Spinner -Message "Initializing pacman keyring" -ScriptBlock {
                Invoke-Msys2Bash -Msys2Dir $Script:_msys2Dir -Command "pacman-key --init 2>&1"
            }

            Show-Spinner -Message "Populating keyring" -ScriptBlock {
                Invoke-Msys2Bash -Msys2Dir $Script:_msys2Dir -Command "pacman-key --populate msys2 mingw64 2>&1"
            }
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
    Write-Step "9/13" "Installing system tools via pacman (djvulibre)..."

    try {
        $pkgs = $Script:MSYS2_TOOL_PACKAGES
        # OCR is now pure-Python (RapidOCR); no tesseract/ghostscript/qpdf to filter.
        $pkgList = $pkgs -join " "
        if (-not $pkgs) {
            Write-Info "No tool packages to install"
            Write-OK "System tools installed"
            Set-InstallState -Step "msys2_tools_installed" -Status "ok"
            return
        }
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
                Write-Log "Info" "pacman attempt $attempt/3 failed, retrying in 3s..." -NoConsole
                Start-Sleep -Seconds 3
            }
        }
        if ($lastError) { throw $lastError }

        # Verify critical binaries exist
        $checks = @()
        $checks += @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\ddjvu.exe"; Name = "djvulibre" }
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

function Step-GenerateScripts {
    Write-Step "10/13" "Deploying Python scripts (watcher, convert, docx_styler)..."

    Ensure-Directory $Script:_scriptsDir

    try {
        # Download the canonical scripts — same files every other platform runs.
        # (No more embedded copies: the watcher/converter now live in exactly
        # one place in the repo and diverge on nothing.)
        foreach ($script in @("watcher.py", "convert_pdf.py", "docx_styler.py")) {
            $dest = Join-PathSafe $Script:_scriptsDir $script
            Invoke-DownloadWithRetry -Url "$($Script:REPO_URL)/$script" -OutFile $dest `
                -MaxRetries 2 -TimeoutSec 120
            if ((Get-Item $dest -ErrorAction Stop).Length -lt 500) {
                throw "$script download looks invalid (too small)"
            }
        }

        # Verify scripts with Python syntax check
        if (Test-Path $Script:_pythonExe -PathType Leaf) {
            foreach ($script in @("watcher.py", "convert_pdf.py", "docx_styler.py")) {
                $scriptPath = Join-PathSafe $Script:_scriptsDir $script
                $proc = Start-Process -FilePath $Script:_pythonExe -ArgumentList @("-m", "py_compile", $scriptPath) -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -ne 0) { Write-Log "Warn" "$script syntax check failed" -NoConsole }
            }
        }

        Write-OK "Python scripts deployed"
        Set-InstallState -Step "scripts_generated" -Status "ok"
    } catch {
        Write-Fail "Failed to deploy Python scripts: $_"
    }
}

function Step-GenerateLauncher {
    Write-Step "11/13" "Generating mark-dawn.bat launcher..."

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
    Write-Step "12/13" "Verifying installation..."

    $failures = @()

    # Check critical binaries
    $checks = @(
        @{ Path = $Script:_pythonExe;                                Name = "python.exe" }
        @{ Path = $Script:_launcherPath;                             Name = "mark-dawn.bat" }
        @{ Path = Join-PathSafe $Script:_msys2Dir "mingw64\bin\ddjvu.exe"; Name = "ddjvu (djvulibre)" }
    )
    foreach ($check in $checks) {
        if (-not (Test-Path $check.Path -PathType Leaf)) {
            $failures += "Missing: $($check.Name) at $($check.Path)"
        }
    }

    # Verify pip and key modules (via temp script to avoid -c quoting issues)
    if (Test-Path $Script:_pythonExe -PathType Leaf) {
        $verifyScript = Join-PathSafe $env:TEMP "mark-dawn-verify-final.py"
        $code = @"
import sys
import pymupdf4llm; print('pymupdf4llm ok')
import rapidocr; print('rapidocr ok')
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
    Write-Step "13/13" "Installation complete!"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "           mark-dawn installed successfully" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Location:  $($Script:_installDir)" -ForegroundColor Cyan
    Write-Host "Launcher:  $($Script:_launcherPath)" -ForegroundColor Cyan
    Write-Host "Data:      $($Script:_dataDir)" -ForegroundColor Cyan
    Write-Host ""

    # Add install dir to User PATH
    try {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$($Script:_installDir)*") {
            [Environment]::SetEnvironmentVariable("Path", "$($Script:_installDir);$userPath", "User")
            Write-OK "Added $($Script:_installDir) to User PATH"
            Write-Info "Run: `$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User')"
        } else {
            Write-Log "Debug" "Install dir already in PATH" -NoConsole
        }
    } catch {
        Write-Log "Warn" "Could not update PATH: $_" -NoConsole
    }

    # Copy installer to install dir for future uninstall
    try {
        if ($PSCommandPath) {
            Copy-Item $PSCommandPath (Join-PathSafe $Script:_installDir "mark-dawn.ps1") -Force -ErrorAction Stop
        }
    } catch {
        Write-Log "Warn" "Could not copy installer for uninstall: $_" -NoConsole
    }

    Install-StartMenuShortcuts

    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Open a new terminal window (or run the PATH refresh command above)"
    Write-Host "  2. Run:  mark-dawn start"
    Write-Host "  3. Drop files into: $($Script:_dataDir)\Inbox"
    Write-Host "  4. Results appear in: $($Script:_dataDir)\Research"
    Write-Host ""
    Write-Host "Management commands:" -ForegroundColor Yellow
    Write-Host "  mark-dawn status"
    Write-Host "  mark-dawn logs"
    Write-Host "  mark-dawn stop"
    Write-Host "  mark-dawn update"
    Write-Host ""
    Write-Host "Auto-start on login (requires Admin):" -ForegroundColor Yellow
    Write-Host "  mark-dawn install-task"
    Write-Host ""

    Set-InstallState -Step "complete" -Status "ok"
}

