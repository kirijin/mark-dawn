<p align="center">
  <img src="https://raw.githubusercontent.com/kirijin/mark-dawn/main/logo.png" width="200">
</p>

# **mark-dawn**
***Universal Document → Markdown Pipeline*** with auto-OCR for scanned PDFs.

Converts PDF, DOCX, XLSX, PPTX, HTML, CSV, RTF — drop a file, get clean Markdown.

| Platform | Status | Install |
|----------|--------|---------|
| Linux    | ✅ Stable (container) | `curl -fsSL ...install.sh \| bash` |
| macOS 26+ | ✅ New (Apple Container) | `curl -fsSL ...install-macos-container.sh \| bash` |
| macOS pre-26 | ✅ New (Homebrew + venv) | `curl -fsSL ...install.sh \| bash` |
| Windows  | ❌ Mature but rough (MSYS2 portable) | `iwr -Uri ...install.ps1` |

## Install

### 🐧 Linux (Podman/Docker)
```bash
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
```
### 🍎 macOS 26+ (Apple Container — native, ~51 MB idle)
```bash
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install-macos-container.sh | bash
```
Apple's own container runtime. Per-container microVMs via Virtualization.framework. Lightest option on macOS 26 Tahoe+.

### 🍎 macOS pre-26 (Homebrew + Python venv — zero VM overhead)
```bash
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
```
Detects your macOS version automatically. Installs ocrmypdf, tesseract-lang, djvulibre, pandoc via Homebrew; pymupdf4llm, markitdown, watchdog in a Python venv. Runs as native processes — no container VM.

### 🪟 Windows (PowerShell — MSYS2 portable)
```powershell
iwr -Uri "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1" -OutFile "$env:TEMP\mark-dawn.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\mark-dawn.ps1"
```

## Use it

**Linux / macOS** — same commands everywhere:
```
# Start the background watcher (auto-converts files in ~/Documents/Inbox)
mark-dawn start

# Stop the watcher
mark-dawn stop

# Convert a single file manually
mark-dawn convert /path/to/file.pdf

# Convert to DOCX (needs pandoc)
mark-dawn convert /path/to/file.pdf --docx

# Follow logs in real-time (Ctrl+C to exit)
mark-dawn logs

# Show status
mark-dawn status

# Pull latest image / update packages and restart
mark-dawn update

# Install as launchd user service (macOS) or systemd service (Linux)
mark-dawn install-service   # macOS
mark-dawn install-systemd   # Linux

# Show help
mark-dawn help
mark-dawn --help
```

**Windows (PowerShell):**
```powershell
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" start
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" status
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" convert "C:\path\to\file.pdf"
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" stop
& "$env:USERPROFILE\mark-dawn\mark-dawn.bat" install-task
```

## Features

- **Smart PDF detection** — digital PDFs (pymupdf4llm, fast) vs scanned PDFs (ocrmypdf + Tesseract, OCR)
- **6 languages** — English, Russian, French, German, Chinese (Simplified), Japanese
- **DjVu support** — native text extraction via djvutxt, fallback render+OCR via ddjvu
- **Image input** — TIFF, JPEG, PNG, BMP, WebP → OCR pipeline
- **Office docs** — DOCX, XLSX, PPTX via markitdown
- **DOCX output** — `--docx` flag converts Markdown to styled DOCX
- **Folder watcher** — drop files into Inbox, get .md (or .docx) in Research
- **2docx subfolder** — files placed in `Inbox/2docx/` auto-convert to DOCX

## How It Works

```
~/Documents/
├── Inbox/         ← Drop files here
│   ├── 2md/       → Converted to .md
│   └── 2docx/     → Converted to .docx
├── Research/      ← Converted Markdown/DOCX appears here
└── Inbox_Failed/  ← Files that couldn't be converted
```

1. Drop a file into `Inbox/`
2. Watcher detects it (3s debounce)
3. Digital PDF (avg >100 chars/page) → pymupdf4llm → Markdown (fast)
4. Scanned PDF → ocrmypdf + Tesseract → pymupdf4llm → Markdown (slower, OCR)
5. Office files → markitdown → Markdown
6. Result appears in `Research/`. Original deleted from Inbox.

## Building Locally

```bash
git clone https://github.com/kirijin/mark-dawn.git
cd mark-dawn

# Container image (Linux / macOS 26+)
podman build -t mark-dawn:latest .
MARK_DAWN_IMAGE=localhost/mark-dawn:latest ./mark-dawn.sh start

# Or run Python scripts directly (any platform with dependencies)
pip install -r requirements.txt
python3 convert_pdf.py ~/doc.pdf
```

## Behind the scenes

| Component | Linux | macOS 26+ | macOS pre-26 | Windows |
|-----------|-------|-----------|--------------|---------|
| Runtime | podman/docker | Apple Container | Native (no VM) | Native (MSYS2) |
| Idle RAM | ~0 (before first start) | ~51 MB | ~50 MB (Python) | ~80 MB (Python) |
| OCR | Tesseract in image | Tesseract in image | Tesseract via brew | Tesseract via MSYS2 |
| Watcher | systemd user service | launchd | launchd | Scheduled task |
| Install | curl \| bash | curl \| bash | curl \| bash | PowerShell |

## Credits

- [pymupdf4llm](https://pypi.org/project/pymupdf4llm/) — PDF → Markdown via MuPDF
- [markitdown](https://pypi.org/project/markitdown/) — Office docs → Markdown (Microsoft)
- [ocrmypdf](https://github.com/ocrmypdf/ocrmypdf) — OCR pipeline for scanned PDFs
- [Tesseract](https://github.com/tesseract-ocr/tesseract) — OCR engine
- [djvulibre](https://djvu.sourceforge.net/) — DjVu support
