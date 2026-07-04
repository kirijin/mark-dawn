#Requires -RunAsAdministrator
<#
.SYNOPSIS
    mark-dawn: полная установка на Windows (WSL + Podman + контейнер)
.DESCRIPTION
    Устанавливает всё необходимое одной командой:
    - WSL2 (если не установлен)
    - Podman (если не установлен)
    - Podman machine (Linux VM)
    - mark-dawn контейнер
.NOTES
    Требует: Windows 10/11, администраторские права
#>

param(
    [switch]$SkipReboot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host "[$Step] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-OK { param([string]$Message) Write-Host "✅ $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "▶️  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "❌ $Message" -ForegroundColor Red }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " mark-dawn installer for Windows" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# [1/6] Проверка администраторских прав
# ============================================================================
Write-Step "1/6" "Проверка прав администратора..."
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "Скрипт требует прав администратора"
    Write-Host "Запустите PowerShell от имени администратора:" -ForegroundColor Yellow
    Write-Host "  Правый клик по Start → Terminal (Admin)" -ForegroundColor Yellow
    exit 1
}
Write-OK "Права администратора есть"

# ============================================================================
# [2/6] Проверка и установка WSL
# ============================================================================
Write-Step "2/6" "Проверка WSL..."
$wslInstalled = $false
try {
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) {
        $wslInstalled = $true
        Write-OK "WSL уже установлен"
    }
} catch {
    $wslInstalled = $false
}

if (-not $wslInstalled) {
    Write-Info "WSL не найден, устанавливаем..."
    try {
        wsl --install --no-distribution
        if ($LASTEXITCODE -ne 0) { throw "wsl --install failed" }
        Write-OK "WSL установлен"
        
        if (-not $SkipReboot) {
            Write-Host ""
            Write-Host "⚠️  Требуется перезагрузка для завершения установки WSL" -ForegroundColor Yellow
            Write-Host "После перезагрузки запустите скрипт снова." -ForegroundColor Yellow
            Write-Host ""
            $confirm = Read-Host "Перезагрузить сейчас? (y/N)"
            if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                shutdown /r /t 10 /c "Перезагрузка для завершения установки WSL"
            } else {
                Write-Host "Перезагрузите компьютер вручную и запустите скрипт снова." -ForegroundColor Yellow
            }
            exit 0
        }
    } catch {
        Write-Fail "Не удалось установить WSL: $_"
        exit 1
    }
}

# Проверка, что WSL2 активен
try {
    $wslList = wsl --list --verbose 2>&1
    Write-OK "WSL работает"
} catch {
    Write-Fail "WSL установлен, но не работает. Перезагрузите компьютер."
    exit 1
}

# ============================================================================
# [3/6] Проверка и установка Podman
# ============================================================================
Write-Step "3/6" "Проверка Podman..."
if (Get-Command podman -ErrorAction SilentlyContinue) {
    $podmanVer = (podman --version).Trim()
    Write-OK "Podman найден: $podmanVer"
} else {
    Write-Info "Podman не найден, устанавливаем через winget..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail "winget не найден. Установите Podman вручную:"
        Write-Host "  https://podman-desktop.io/" -ForegroundColor Yellow
        exit 1
    }
    try {
        winget install --id RedHat.Podman -e --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget install failed" }
        Write-OK "Podman установлен"
        
        # Обновить PATH в текущей сессии
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        
        if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
            Write-Host ""
            Write-Host "⚠️  Podman установлен, но PATH не обновлён." -ForegroundColor Yellow
            Write-Host "Перезапустите PowerShell и запустите скрипт снова." -ForegroundColor Yellow
            exit 0
        }
    } catch {
        Write-Fail "Не удалось установить Podman: $_"
        exit 1
    }
}

# ============================================================================
# [4/6] Создание и запуск Podman machine
# ============================================================================
Write-Step "4/6" "Проверка Podman machine..."

# Проверяем, есть ли уже machine
$machines = podman machine list --format "{{.Name}}" 2>&1
$hasMachine = $machines -and ($machines -notlike "*cannot*") -and ($machines -notlike "*error*") -and ($machines.Trim().Length -gt 0)

if ($hasMachine) {
    Write-OK "Podman machine существует"
    
    # Проверяем, запущена ли
    $machineStatus = podman machine list --format "{{.Running}}" 2>&1
    if ($machineStatus -eq "running" -or $machineStatus -eq "true") {
        Write-OK "Podman machine запущена"
    } else {
        Write-Info "Запускаем Podman machine..."
        podman machine start
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Не удалось запустить Podman machine"
            exit 1
        }
        Write-OK "Podman machine запущена"
    }
} else {
    Write-Info "Создаём Podman machine (это займёт 2-5 минут)..."
    try {
        podman machine init --cpus 2 --memory 4096 --disk-size 50
        if ($LASTEXITCODE -ne 0) { throw "podman machine init failed" }
        Write-OK "Podman machine создана"
        
        Write-Info "Запускаем Podman machine..."
        podman machine start
        if ($LASTEXITCODE -ne 0) { throw "podman machine start failed" }
        Write-OK "Podman machine запущена"
    } catch {
        Write-Fail "Не удалось создать/запустить Podman machine: $_"
        exit 1
    }
}

# Проверка подключения
try {
    $null = podman info 2>&1
    if ($LASTEXITCODE -ne 0) { throw "podman info failed" }
    Write-OK "Podman готов к работе"
} catch {
    Write-Fail "Podman не отвечает. Проверьте: podman machine list"
    exit 1
}

# ============================================================================
# [5/6] Установка mark-dawn launcher
# ============================================================================
Write-Step "5/6" "Установка mark-dawn launcher..."

$binDir = Join-Path $env:USERPROFILE ".local\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$launcherPath = Join-Path $binDir "mark-dawn.ps1"
$launcherUrl = "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1"

try {
    Write-Info "Скачиваем launcher с GitHub..."
    Invoke-WebRequest -Uri $launcherUrl -OutFile $launcherPath -UseBasicParsing
    Write-OK "Launcher установлен: $launcherPath"
    
    # Разблокировать файл (на случай скачивания из интернета)
    Unblock-File -Path $launcherPath -ErrorAction SilentlyContinue
} catch {
    Write-Fail "Не удалось скачать launcher: $_"
    Write-Host "Скачайте вручную: $launcherUrl" -ForegroundColor Yellow
    exit 1
}

# ============================================================================
# [6/6] Запуск mark-dawn
# ============================================================================
Write-Step "6/6" "Запуск mark-dawn..."

try {
    # Проверка политики выполнения
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq "Restricted") {
        Write-Info "Разрешаем запуск локальных скриптов..."
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-OK "Политика обновлена: RemoteSigned"
    }
    
    # Запустить mark-dawn
    Write-Info "Запускаем mark-dawn watcher..."
    & $launcherPath -Command start
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " ✅ mark-dawn установлен и запущен!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📥 Inbox:    $env:USERPROFILE\Documents\Inbox" -ForegroundColor Cyan
    Write-Host "📤 Research: $env:USERPROFILE\Documents\Research" -ForegroundColor Cyan
    Write-Host "❌ Failed:   $env:USERPROFILE\Documents\Inbox_Failed" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Управление:" -ForegroundColor Yellow
    Write-Host "  & '$launcherPath' -Command status" -ForegroundColor White
    Write-Host "  & '$launcherPath' -Command logs" -ForegroundColor White
    Write-Host "  & '$launcherPath' -Command stop" -ForegroundColor White
    Write-Host "  & '$launcherPath' -Command update" -ForegroundColor White
    Write-Host ""
    Write-Host "Автозапуск при входе в систему:" -ForegroundColor Yellow
    Write-Host "  & '$launcherPath' -Command install-task" -ForegroundColor White
    Write-Host ""
    
} catch {
    Write-Fail "Не удалось запустить mark-dawn: $_"
    exit 1
}
