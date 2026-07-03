Write-Host "mark-dawn Installer" -ForegroundColor Cyan
Write-Host "===================" -ForegroundColor Cyan
Write-Host ""

$InstallerDir = Join-Path $env:USERPROFILE ".local\bin"
$Installer = Join-Path $InstallerDir "mark-dawn.ps1"
$URL = "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1"

New-Item -ItemType Directory -Force -Path $InstallerDir | Out-Null

Write-Host "Downloading launcher script..."
Invoke-WebRequest -Uri $URL -OutFile $Installer -UseBasicParsing

Write-Host "✅ Installed to: $Installer" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Ensure you have podman or docker installed"
Write-Host "  2. Run: .\$Installer -Command start"
Write-Host "  3. Drop files into Documents\Inbox"
Write-Host ""
Write-Host "For Task Scheduler integration:"
Write-Host "  .\$Installer -Command install-task"
