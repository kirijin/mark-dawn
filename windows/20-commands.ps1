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
        @{ Name = "msys2_initialized";       Desc = "Initialize MSYS2 keyring";          Func = ${function:Step-InitMsys2} }
        @{ Name = "msys2_tools_installed";   Desc = "Install system tools (pacman)";    Func = ${function:Step-InstallMsys2Tools} }
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
            $proc = Start-Process -FilePath $Script:_launcherPath -ArgumentList "start" -WindowStyle Hidden -PassThru
            if ($proc.ExitCode -eq 0) {
                Write-OK "mark-dawn watcher started"
            } else {
                Write-Log "Warn" "Launcher exited with code $($proc.ExitCode)" -NoConsole
            }
        } catch {
            Write-Log "Warn" "Failed to start watcher: $_" -NoConsole
        }
    } else {
        Write-Info "You can start it later with: mark-dawn start"
    }
}

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

    $inboxDir  = Join-PathSafe $Script:_dataDir "Inbox"
    $failedDir = Join-PathSafe $Script:_dataDir "Inbox_Failed"
    $researchDir = Join-PathSafe $Script:_dataDir "Research"

    Write-Host "This will remove:" -ForegroundColor Yellow
    Write-Host "  - $($Script:_installDir)  (mark-dawn installation)" -ForegroundColor Yellow
    Write-Host "  - $inboxDir  (Inbox folder)" -ForegroundColor Yellow
    Write-Host "  - $failedDir  (failed conversions)" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Research folder will be kept: $researchDir" -ForegroundColor Yellow
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

    # Clean up data directories
    Remove-DirectorySafe $inboxDir -Force
    Write-OK "Removed: Inbox"

    Remove-DirectorySafe $failedDir -Force
    Write-OK "Removed: Inbox_Failed"

    if (Test-Path $researchDir -PathType Container) {
        $researchFiles = (Get-ChildItem $researchDir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($researchFiles -eq 0) {
            Remove-DirectorySafe $researchDir -Force
            Write-OK "Removed empty: Research"
        } else {
            Write-Info "Preserved non-empty Research ($researchFiles file(s))"
        }
    }

    # Clean up any mark-dawn entries from User PATH
    try {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $filtered = ($userPath -split ';' | Where-Object { $_ -notlike '*mark-dawn*' }) -join ';'
        if ($filtered -ne $userPath) {
            [Environment]::SetEnvironmentVariable("Path", $filtered, "User")
            Write-OK "Removed mark-dawn entries from User PATH"
        }
    } catch {
        Write-Log "Warn" "Could not update PATH: $_" -NoConsole
    }

    Clear-InstallState

    Write-Host ""
    Write-Host "=== mark-dawn uninstalled ===" -ForegroundColor Green
    Write-Host "Research folder preserved: $researchDir" -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-ChangeLangs {
    Write-Host "OCR languages are now handled by RapidOCR (pure Python)."
    Write-Host "Set MARK_DAWN_LANGS in the launcher or use --langs per file."
    Write-Host "Example: mark-dawn convert scan.pdf --langs eng+rus"
}

function Invoke-QuickReinstall {
    Write-Host ""
    Write-Host "=== mark-dawn quick reinstall ===" -ForegroundColor Cyan
    Write-Host "Preserves: Python + pip packages, MSYS2, pacman cache, Research"
    Write-Host "Deletes: scripts, launcher, state, inbox, failed, logs"
    Write-Host ""

    # B8: this deletes user files (Inbox/Inbox_Failed) — require confirmation,
    # same gate as Uninstall and FullReinstall.
    $confirm = Read-Host "This removes Inbox and Inbox_Failed (pending documents!). Type 'yes' to continue"
    if ($confirm -ne "yes") {
        Write-Host "Quick reinstall cancelled."
        return
    }
    Write-Host ""

    if (-not $Script:_installDir) { $Script:_installDir = $Script:DEFAULT_INSTALL_DIR }
    if (-not $Script:_dataDir)    { $Script:_dataDir = $Script:DEFAULT_DATA_DIR }
    $launcher = Join-PathSafe $Script:_installDir "mark-dawn.bat"

    if (Test-Path $launcher -PathType Leaf) {
        Write-Log "Info" "Stopping watcher via launcher..." -NoConsole
        try {
            $null = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$launcher`" stop" -Wait -PassThru -NoNewWindow
        } catch {
            Write-Log "Warn" "Could not stop watcher: $_" -NoConsole
        }
    }

    $preserved = @()
    $deleted = @()

    # Delete: scripts, launcher, state, pid, stop, inbox, failed, logs
    $scriptsDir = Join-PathSafe $Script:_installDir "scripts"
    if (Test-Path $scriptsDir -PathType Container) {
        Remove-DirectorySafe $scriptsDir -Force
        $deleted += "scripts/"
    }

    if (Test-Path $launcher -PathType Leaf) {
        Remove-Item $launcher -Force -ErrorAction SilentlyContinue
        $deleted += "mark-dawn.bat"
    }

    $stateFile = Join-PathSafe $Script:_installDir ".install-state.json"
    if (Test-Path $stateFile -PathType Leaf) {
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        $deleted += ".install-state.json"
    }

    foreach ($f in @("mark-dawn.pid", "mark-dawn.stop")) {
        $p = Join-PathSafe $Script:_installDir $f
        if (Test-Path $p -PathType Leaf) {
            Remove-Item $p -Force -ErrorAction SilentlyContinue
            $deleted += $f
        }
    }

    $logsDir = Join-PathSafe $Script:_installDir "logs"
    if (Test-Path $logsDir -PathType Container) {
        Remove-DirectorySafe $logsDir -Force
        $deleted += "logs/"
    }

    $inboxDir  = Join-PathSafe $Script:_dataDir "Inbox"
    $failedDir = Join-PathSafe $Script:_dataDir "Inbox_Failed"
    if (Test-Path $inboxDir -PathType Container) {
        Remove-DirectorySafe $inboxDir -Force
        $deleted += "Inbox/"
    }
    if (Test-Path $failedDir -PathType Container) {
        Remove-DirectorySafe $failedDir -Force
        $deleted += "Inbox_Failed/"
    }

    # Preserved items
    $preserved += "python/", ".msys2/", ".pacman-cache/", "Research/"

    Write-Host ""
    Write-OK "Deleted: $($deleted -join ', ')"
    Write-Info "Preserved: $($preserved -join ', ')"
    Write-Host ""
    Write-Host "Re-running installation steps (skipping preserved dependencies)..." -ForegroundColor Yellow
    Write-Host ""

    # Clean up old mark-dawn entries from User PATH, then re-add current install dir
    try {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $filtered = ($userPath -split ';' | Where-Object { $_ -notlike '*mark-dawn*' }) -join ';'
        if ($filtered -ne $userPath) {
            [Environment]::SetEnvironmentVariable("Path", $filtered, "User")
            Write-OK "Removed old mark-dawn entries from User PATH"
        }
        if ($filtered -notlike "*$($Script:_installDir)*") {
            [Environment]::SetEnvironmentVariable("Path", "$($Script:_installDir);$filtered", "User")
            Write-OK "Added $($Script:_installDir) to User PATH"
        }
    } catch {
        Write-Log "Warn" "Could not update PATH: $_" -NoConsole
    }

    # Preserve state for completed steps (python, msys2, etc.)
    # but clear scripts/launcher/verify steps so they regenerate
    $stateFile = Join-PathSafe $Script:_installDir ".install-state.json"
    if (Test-Path $stateFile -PathType Leaf) {
        try {
            $state = Get-Content $stateFile -Raw -Encoding utf8 | ConvertFrom-Json
            $clearSteps = @("scripts_generated", "launcher_generated", "verified", "complete")
            foreach ($step in $clearSteps) {
                if ($state.completed.$step) {
                    $state.completed.$step = $null
                }
            }
            $state | ConvertTo-Json -Compress | Out-File $stateFile -Encoding utf8 -Force
        } catch {
            Write-Log "Warn" "Could not update state file, falling back to full clear: $_" -NoConsole
            Clear-InstallState
        }
    }

    Invoke-Install
}

function Invoke-FullReinstall {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Red -BackgroundColor Black
    Write-Host "   FULL REINSTALL — THIS WILL DELETE EVERYTHING"            -ForegroundColor Red -BackgroundColor Black
    Write-Host "========================================================" -ForegroundColor Red -BackgroundColor Black
    Write-Host ""

    if (-not $Script:_installDir) { $Script:_installDir = $Script:DEFAULT_INSTALL_DIR }
    if (-not $Script:_dataDir)    { $Script:_dataDir = $Script:DEFAULT_DATA_DIR }

    $inboxDir     = Join-PathSafe $Script:_dataDir "Inbox"
    $failedDir    = Join-PathSafe $Script:_dataDir "Inbox_Failed"
    $researchDir  = Join-PathSafe $Script:_dataDir "Research"
    $startMenuDir = Join-PathSafe $env:APPDATA "Microsoft\Windows\Start Menu\Programs\mark-dawn"

    Write-Host "This will permanently delete:" -ForegroundColor Red
    Write-Host "  • $($Script:_installDir)" -ForegroundColor Red
    Write-Host "  • $inboxDir" -ForegroundColor Red
    Write-Host "  • $failedDir" -ForegroundColor Red
    Write-Host "  • $researchDir (ALL your markdown output)" -ForegroundColor Red
    Write-Host "  • $startMenuDir (Start Menu shortcuts)" -ForegroundColor Red
    Write-Host "  • User PATH entry for mark-dawn" -ForegroundColor Red
    Write-Host "  • Scheduled task 'mark-dawn'" -ForegroundColor Red
    Write-Host "  • Windows Defender exclusions" -ForegroundColor Red
    Write-Host ""

    $confirm = Read-Host "Type 'YES' to confirm full reinstall"
    if ($confirm -ne "YES") {
        Write-Host ""
        Write-Host "Full reinstall cancelled."
        return
    }

    # Stop watcher
    $launcher = Join-PathSafe $Script:_installDir "mark-dawn.bat"
    if (Test-Path $launcher -PathType Leaf) {
        Write-Log "Info" "Stopping watcher..." -NoConsole
        try {
            $null = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$launcher`" stop" -Wait -PassThru -NoNewWindow
        } catch {
            Write-Log "Warn" "Could not stop watcher: $_" -NoConsole
        }
    }

    # Delete scheduled task
    try {
        $null = Start-Process -FilePath "schtasks" -ArgumentList "/Delete", "/TN", "mark-dawn", "/F" -Wait -PassThru -NoNewWindow
    } catch {
        Write-Log "Info" "Task Scheduler entry may remain (not admin)" -NoConsole
    }

    # Remove any mark-dawn entries from User PATH
    try {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $filtered = ($userPath -split ';' | Where-Object { $_ -notlike '*mark-dawn*' }) -join ';'
        if ($filtered -ne $userPath) {
            [Environment]::SetEnvironmentVariable("Path", $filtered, "User")
            Write-OK "Removed mark-dawn entries from User PATH"
        }
    } catch {
        Write-Log "Warn" "Could not update PATH: $_" -NoConsole
    }

    # Remove Start Menu shortcuts
    if (Test-Path $startMenuDir -PathType Container) {
        Remove-DirectorySafe $startMenuDir -Force
        Write-OK "Removed Start Menu shortcuts"
    }

    # Remove Defender exclusion
    try {
        $null = Remove-MpPreference -ExclusionPath $Script:_installDir -ErrorAction SilentlyContinue
        $null = Remove-MpPreference -ExclusionPath (Join-PathSafe $env:TEMP "mark-dawn-installer") -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Debug" "Could not remove Defender exclusion" -NoConsole
    }

    # Delete install directory
    try {
        Remove-DirectorySafe $Script:_installDir -Force
        Write-OK "Deleted: $($Script:_installDir)"
    } catch {
        Write-Log "Warn" "Could not remove installation directory: $_" -NoConsole
    }

    # Delete data directories
    Remove-DirectorySafe $inboxDir -Force
    Remove-DirectorySafe $failedDir -Force
    Remove-DirectorySafe $researchDir -Force
    Write-OK "Deleted: Inbox, Inbox_Failed, Research"

    Write-Host ""
    Write-OK "All mark-dawn files removed"
    Write-Host ""
    Write-Host "Running fresh installation..." -ForegroundColor Yellow
    Write-Host ""

    Clear-InstallState
    Invoke-Install
}

