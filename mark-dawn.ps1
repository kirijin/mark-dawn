param(
    [ValidateSet("start","stop","restart","convert","logs","status","update","install-task","uninstall-task","help")]
    [string]$Command = "help",
    [string]$FilePath
)

$IMAGE = $env:MARK_DAWN_IMAGE ?? "docker.io/kirijin/mark-dawn:latest"
$DATA_DIR = Join-Path $env:USERPROFILE "Documents"

# Создание директорий
New-Item -ItemType Directory -Force -Path (Join-Path $DATA_DIR "Inbox") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DATA_DIR "Research") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DATA_DIR "Inbox_Failed") | Out-Null

if (Get-Command podman -ErrorAction SilentlyContinue) {
    $RUNTIME = "podman"
} elseif (Get-Command docker -ErrorAction SilentlyContinue) {
    $RUNTIME = "docker"
} else {
    Write-Error "podman or docker required"
    exit 1
}

& $RUNTIME pull $IMAGE 2>$null

switch ($Command) {
    "start" {
        Write-Host "Starting mark-dawn watcher..."
        & $RUNTIME run -d `
            --name mark-dawn `
            --restart unless-stopped `
            -v "${DATA_DIR}\Inbox:/data/Inbox:Z" `
            -v "${DATA_DIR}\Research:/data/Research:Z" `
            -v "${DATA_DIR}\Inbox_Failed:/data/Inbox_Failed:Z" `
            $IMAGE watcher
        Write-Host "✅ Watcher started" -ForegroundColor Green
        Write-Host "   Inbox:    $DATA_DIR\Inbox"
        Write-Host "   Research: $DATA_DIR\Research"
        Write-Host "   Logs:     $RUNTIME logs -f mark-dawn"
    }

    "stop" {
        Write-Host "Stopping mark-dawn..."
        & $RUNTIME stop mark-dawn 2>$null
        & $RUNTIME rm mark-dawn 2>$null
        Write-Host "✅ Stopped" -ForegroundColor Green
    }

    "restart" {
        & $PSScriptRoot\mark-dawn.ps1 -Command stop
        Start-Sleep 2
        & $PSScriptRoot\mark-dawn.ps1 -Command start
    }

    "convert" {
        if (-not $FilePath) {
            Write-Error "File path required. Usage: .\mark-dawn.ps1 -Command convert -FilePath FILE"
            exit 1
        }
        $FullPath = (Resolve-Path $FilePath).Path
        $DirPath = Split-Path $FullPath -Parent
        $FileName = Split-Path $FullPath -Leaf

        & $RUNTIME run --rm `
            -v "${DATA_DIR}\Inbox:/data/Inbox:Z" `
            -v "${DATA_DIR}\Research:/data/Research:Z" `
            -v "${DATA_DIR}\Inbox_Failed:/data/Inbox_Failed:Z" `
            -v "${DirPath}:/input:Z" `
            $IMAGE convert "/input/$FileName"
    }

    "logs" {
        & $RUNTIME logs -f mark-dawn
    }

    "status" {
        & $RUNTIME ps --filter name=mark-dawn --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    }

    "update" {
        Write-Host "Updating mark-dawn image..."
        & $RUNTIME pull $IMAGE
        & $PSScriptRoot\mark-dawn.ps1 -Command restart
    }

    "install-task" {
        $scriptContent = @"
@echo off
$RUNTIME run --rm --name mark-dawn-task `
    -v "$DATA_DIR\Inbox:/data/Inbox:Z" `
    -v "$DATA_DIR\Research:/data/Research:Z" `
    -v "$DATA_DIR\Inbox_Failed:/data/Inbox_Failed:Z" `
    $IMAGE watcher
"@
        $scriptPath = Join-Path $env:APPDATA "mark-dawn\watcher.bat"
        New-Item -ItemType Directory -Force -Path (Split-Path $scriptPath) | Out-Null
        $scriptContent | Out-File -FilePath $scriptPath -Encoding ASCII

        $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)

        Register-ScheduledTask -TaskName "mark-dawn" -Action $action -Trigger $trigger -Settings $settings -Description "mark-dawn document converter watcher" -RunLevel Highest -Force
        Start-ScheduledTask -TaskName "mark-dawn"

        Write-Host "✅ Task Scheduler job installed and started" -ForegroundColor Green
    }

    "uninstall-task" {
        Unregister-ScheduledTask -TaskName "mark-dawn" -Confirm:$false
        Write-Host "✅ Task Scheduler job uninstalled" -ForegroundColor Green
    }

    default {
        Write-Host "mark-dawn - Universal Document to Markdown Pipeline" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Usage: .\mark-dawn.ps1 -Command <command> [-FilePath <file>]"
        Write-Host ""
        Write-Host "Commands:" -ForegroundColor Yellow
        Write-Host "  start              Start background watcher"
        Write-Host "  stop               Stop background watcher"
        Write-Host "  restart            Restart watcher"
        Write-Host "  convert FILE       Convert single file"
        Write-Host "  logs               Follow logs"
        Write-Host "  status             Show container status"
        Write-Host "  update             Pull latest image and restart"
        Write-Host "  install-task       Install as Task Scheduler job"
        Write-Host "  uninstall-task     Uninstall Task Scheduler job"
        Write-Host ""
        Write-Host "Supported formats: PDF, DOCX, XLSX, PPTX, HTML, CSV" -ForegroundColor Yellow
        Write-Host "Supported languages: English, Russian, French, German, Chinese, Japanese" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Directories:" -ForegroundColor Yellow
        Write-Host "  Documents\Inbox        - Drop files here"
        Write-Host "  Documents\Research     - Converted files appear here"
        Write-Host "  Documents\Inbox_Failed - Failed conversions"
        Write-Host ""
        Write-Host "Environment: MARK_DAWN_IMAGE - Docker image to use" -ForegroundColor Yellow
    }
}
