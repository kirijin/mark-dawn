<p align="center">
  <img src="https://raw.githubusercontent.com/kirijin/mark-dawn/main/logo.png" width="200">
</p>

# !BEWARE! SLOPPING IN PROGRESS. SUBJECT TO CONSTANT CHANGE UNTIL IT "AT LEAST WORKS"!

## **mark-dawn**
***a vibe-slopped portable ocr solution for nix & win***

**Universal Document to Markdown Pipeline** with auto-OCR for scanned PDFs.

Converts PDF, DOCX, XLSX, PPTX, HTML, CSV, RTF to clean Markdown with:
- 🧠 Smart detection of digital vs scanned PDFs
- 🔤 OCR for 6 languages: English, Russian, French, German, Chinese (Simplified), Japanese
- 📦 Fully containerized (Podman/Docker) — works on any system
- 👁️ Folder watcher mode: drop files into Inbox, get Markdown in Research


### Install it

**Linux (Podman/Docker)** // ***the only working version rn***
```bash
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
```
**Windows (PowerShell) *(BROKEN. SLOP in PROGRESS)* (MSYS2 Portable)**
```powershell
iwr -Uri "https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.ps1" -OutFile "$env:TEMP\install.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install.ps1"
```
**??MacOS??** ***in the slops rn***
```sh
```

### Use it

**Linux / macOS**
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

**Windows (PowerShell)**
```
# Start watcher
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" start

# Check status
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" status

# Follow logs
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" logs

# Convert single file
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" convert "C:\path\to\file.pdf"

# Stop
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" stop

# Update dependencies
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" update

# Auto-start on login (requires Admin PowerShell)
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" install-task
```


**How It Works**

- You drop a file into ~/Documents/Inbox/
- Watcher detects it (3s debounce)
- For digital PDFs (avg >100 chars/page) → pymupdf4llm → Markdown (fast)
- For scanned PDFs → ocrmypdf + Tesseract → pymupdf4llm → Markdown (slower)
- For Office files → markitdown → Markdown
- Result appears in ~/Documents/Research/<filename>.md
- Failed files moved to ~/Documents/Inbox_Failed/


**Directory Layout**
```
~/Documents/
├── Inbox/         ← Drop files here
├── Research/      ← Converted Markdown appears here
└── Inbox_Failed/  ← Files that couldn't be converted
```
**Building Locally**
```
git clone https://github.com/kirijin/mark-dawn.git
cd mark-dawn
podman build -t mark-dawn:latest .
MARK_DAWN_IMAGE=localhost/mark-dawn:latest ./mark-dawn.sh start
```
