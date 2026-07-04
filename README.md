<p align="center">
  <img src="https://raw.githubusercontent.com/kirijin/mark-dawn/main/logo.png" width="200">
</p>

# BEWARE
# !!!VIBE_SLOP_HAZARD!!!

## mark-dawn

**Universal Document to Markdown Pipeline** with auto-OCR for scanned PDFs.

Converts PDF, DOCX, XLSX, PPTX, HTML, CSV, RTF to clean Markdown with:
- 🧠 Smart detection of digital vs scanned PDFs
- 🔤 OCR for 6 languages: English, Russian, French, German, Chinese (Simplified), Japanese
- 📦 Fully containerized (Podman/Docker) — works on any system
- 👁️ Folder watcher mode: drop files into Inbox, get Markdown in Research

## Quick Start (one command)


### Linux / macOS (Podman/Docker)
```bash
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
mark-dawn start
```
### Windows (PowerShell) (BROKEN. SLOP in PROGRESS) (MSYS2 Portable)
```powershell
iwr -Uri "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1" -OutFile mark-dawn.ps1
.\mark-dawn.ps1 -Command start
```

## Usage

### Linux / macOS
```
# Start the background watcher (auto-converts files in ~/Documents/Inbox)
mark-dawn start

# Stop the watcher
mark-dawn stop

# Restart the watcher
mark-dawn restart

# Convert a single file manually
mark-dawn convert /path/to/file.pdf

# Follow container logs in real-time (Ctrl+C to exit)
mark-dawn logs

# Show container status and PID
mark-dawn status

# Pull latest image from Docker Hub and restart
mark-dawn update

# Install as systemd user service (auto-start on login)
mark-dawn install-systemd

# Remove systemd service and stop container
mark-dawn uninstall

# Show help / usage information
mark-dawn help
mark-dawn --help
mark-dawn -h
```
### Windows (PowerShell)
```
# Запустить
.\mark-dawn.ps1 -Command start

# Остановить
.\mark-dawn.ps1 -Command stop

# Статус
.\mark-dawn.ps1 -Command status

# Логи
.\mark-dawn.ps1 -Command logs

# Обновить
.\mark-dawn.ps1 -Command update

# Автозапуск при входе в систему (Task Scheduler)
.\mark-dawn.ps1 -Command install-task

# После install-task управление через Task Scheduler:
Get-ScheduledTask -TaskName "mark-dawn" | Select-Object State
Stop-ScheduledTask -TaskName "mark-dawn"
Start-ScheduledTask -TaskName "mark-dawn"

# Удалить автозапуск
.\mark-dawn.ps1 -Command uninstall-task
```

## How It Works
```
    You drop a file into ~/Documents/Inbox/
    Watcher detects it (3s debounce)
    For digital PDFs (avg >100 chars/page) → pymupdf4llm → Markdown (fast)
    For scanned PDFs → ocrmypdf + Tesseract → pymupdf4llm → Markdown (slower)
    For Office files → markitdown → Markdown
    Result appears in ~/Documents/Research/<filename>.md
    Failed files moved to ~/Documents/Inbox_Failed/
```
### Directory Layout
```
~/Documents/
├── Inbox/         ← Drop files here
├── Research/      ← Converted Markdown appears here
└── Inbox_Failed/  ← Files that couldn't be converted
```
### Building Locally
```
git clone https://github.com/kirijin/mark-dawn.git
cd mark-dawn
podman build -t mark-dawn:latest .
MARK_DAWN_IMAGE=localhost/mark-dawn:latest ./mark-dawn.sh start
```
