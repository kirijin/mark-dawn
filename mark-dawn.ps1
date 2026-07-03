param(
    [ValidateSet("start","stop","restart","convert","logs","status","update","install-task","uninstall-task","help")]
    [string]$Command = "help",
    [string]$FilePath
)

$IMAGE = if ($env:MARK_DAWN_IMAGE) { $env:MARK_DAWN_IMAGE } else { "docker.io/kirijin/mark-dawn:latest" }
$DATA_DIR = Join-Path $env:USERPROFILE "Documents"

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
    }
    "stop" {
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
        if (-not $FilePath) { Write-Error "File path required"; exit 1 }
        $FullPath = (Resolve-Path $FilePath).Path
        & $RUNTIME run --rm `
            -v "${DATA_DIR}\Inbox:/data/Inbox:Z" `
            -v "${DATA_DIR}\Research:/data/Research:Z" `
            -v "${DATA_DIR}\Inbox_Failed:/data/Inbox_Failed:Z" `
            -v "$(Split-Path $FullPath -Parent):/input:Z" `
            $IMAGE convert "/input/$(Split-Path $FullPath -Leaf)"
    }
    "logs" { & $RUNTIME logs -f mark-dawn }
    "status" { & $RUNTIME ps --filter name=mark-dawn }
    "update" {
        & $RUNTIME pull $IMAGE
        & $PSScriptRoot\mark-dawn.ps1 -Command restart
    }
    "install-task" {
        $bat = "@echo off`r`n$RUNTIME run --rm --name mark-dawn-task -v `"$DATA_DIR\Inbox`":/data/Inbox:Z -v `"$DATA_DIR\Research`":/data/Research:Z -v `"$DATA_DIR\Inbox_Failed`":/data/Inbox_Failed:Z $IMAGE watcher"
        $batPath = Join-Path $env:APPDATA "mark-dawn\watcher.bat"
        New-Item -ItemType Directory -Force -Path (Split-Path $batPath) | Out-Null
        $bat | Out-File -FilePath $batPath -Encoding ASCII
        $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$batPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)
        Register-ScheduledTask -TaskName "mark-dawn" -Action $action -Trigger $trigger -Settings $settings -Description "mark-dawn watcher" -RunLevel Highest -Force
        Start-ScheduledTask -TaskName "mark-dawn"
        Write-Host "✅ Task installed" -ForegroundColor Green
    }
    "uninstall-task" {
        Unregister-ScheduledTask -TaskName "mark-dawn" -Confirm:$false
        Write-Host "✅ Task uninstalled" -ForegroundColor Green
    }
    default {
        Write-Host "mark-dawn - Universal Document to Markdown Pipeline" -ForegroundColor Cyan
        Write-Host "Usage: .\mark-dawn.ps1 -Command <command> [-FilePath <file>]"
        Write-Host "Commands: start, stop, restart, convert, logs, status, update, install-task, uninstall-task"
    }
}
