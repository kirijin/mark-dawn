function Show-Help {
    Write-Host "mark-dawn portable installer for Windows (Option B)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: mark-dawn.ps1 [options]" -ForegroundColor White
    Write-Host ""
    Write-Host "Install options:" -ForegroundColor Yellow
    Write-Host "  -InstallDir <path>   Custom installation directory (default: %LOCALAPPDATA%\mark-dawn)"
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
    Write-Host "  -QuickReinstall      Reinstall keeping Python/MSYS2/Research"
    Write-Host "  -FullReinstall       Delete everything and reinstall from scratch"
    Write-Host "  -Help                Show this help"
    Write-Host ""
    Write-Host "After installation, use the launcher:" -ForegroundColor Cyan
    Write-Host "  & `"$($Script:DEFAULT_INSTALL_DIR)\mark-dawn.bat`" start|stop|restart|convert|logs|status|update|install-task|uninstall-task|help"
    Write-Host ""
    exit 0
}

function Main {
    $Script:_logLevelNum = @{ "Debug" = 0; "Info" = 1; "Warn" = 2; "Error" = 3 }[$LogLevel]

    if ($Help) { Show-Help; return }

    # Interactive menu when run without arguments
    if ($args.Count -gt 0) {
        Write-Fail "Unknown argument '$($args[0])'. Run 'mark-dawn.ps1 -Help' for usage."
    }

    if (-not $Uninstall -and -not $QuickReinstall -and -not $FullReinstall -and -not $InstallDir -and -not $DataDir -and -not $Msys2Mirror -and -not $PypiMirror) {
        Write-Host ""
        Write-Host "=== mark-dawn ===" -ForegroundColor Cyan
        Write-Host "Universal Document -> Markdown Pipeline" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  1. Install"
        Write-Host "  2. Uninstall"
        Write-Host "  3. Quick reinstall (preserves deps)"
        Write-Host "  4. Full reinstall (from scratch)"
        Write-Host "  5. Help"
        Write-Host "  6. Quit"
        Write-Host ""
        $choice = Read-Host "Choose"
        Write-Host ""
        if ([string]::IsNullOrWhiteSpace($choice)) {
            exit
        } elseif ($choice -eq "2") {
            $Uninstall = $true
        } elseif ($choice -eq "3") {
            $QuickReinstall = $true
        } elseif ($choice -eq "4") {
            $FullReinstall = $true
        } elseif ($choice -eq "5") {
            Show-Help
            return
        } elseif ($choice -eq "6") {
            exit
        }
    }

    if ($QuickReinstall) {
        $Script:_installDir = if ($InstallDir) { $InstallDir } else { $Script:DEFAULT_INSTALL_DIR }
        $Script:_dataDir    = if ($DataDir)    { $DataDir }    else { $Script:DEFAULT_DATA_DIR }
        $Script:_pythonDir  = Join-PathSafe $Script:_installDir "python"
        $Script:_stateFile  = Join-PathSafe $Script:_installDir ".install-state.json"
        Invoke-QuickReinstall
        return
    }

    if ($FullReinstall) {
        $Script:_installDir = if ($InstallDir) { $InstallDir } else { $Script:DEFAULT_INSTALL_DIR }
        $Script:_dataDir    = if ($DataDir)    { $DataDir }    else { $Script:DEFAULT_DATA_DIR }
        $Script:_pythonDir  = Join-PathSafe $Script:_installDir "python"
        $Script:_stateFile  = Join-PathSafe $Script:_installDir ".install-state.json"
        Invoke-FullReinstall
        return
    }

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
    $Script:_launcherPath  = Join-PathSafe $Script:_installDir "mark-dawn.bat"
    $Script:_pidFile       = Join-PathSafe $Script:_installDir "mark-dawn.pid"
    $Script:_logFile       = Join-PathSafe $Script:_logsDir "mark-dawn.log"
    $Script:_stateFile     = Join-PathSafe $Script:_installDir ".install-state.json"
    $Script:_pythonExe     = Join-PathSafe $Script:_pythonDir "python.exe"

    Invoke-Install
}

