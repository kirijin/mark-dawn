# !!!VIBE_CODE_HAZARD!!!

## mark-dawn

**Universal Document to Markdown Pipeline** with auto-OCR for scanned PDFs.

Converts PDF, DOCX, XLSX, PPTX, HTML, CSV, RTF to clean Markdown with:
- 🧠 Smart detection of digital vs scanned PDFs
- 🔤 OCR for 6 languages: English, Russian, French, German, Chinese (Simplified), Japanese
- 📦 Fully containerized (Podman/Docker) — works on any system
- 👁️ Folder watcher mode: drop files into Inbox, get Markdown in Research

## Quick Start (one command)



```bash
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.sh -o mark-dawn
chmod +x mark-dawn
./mark-dawn start
```

```powershell
iwr -Uri "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1" -OutFile mark-dawn.ps1
.\mark-dawn.ps1 -Command start
```


## Requirements: Podman or Docker installed.


## Usage
### Auto-convert files dropped into ~/Documents/Inbox
./mark-dawn start

### Convert a single file
./mark-dawn convert ~/Downloads/paper.pdf

### Follow logs
./mark-dawn logs

### Stop
./mark-dawn stop

### Auto-start on boot (Linux)
./mark-dawn install-systemd

### Update image
./mark-dawn update

### How It Works

    You drop a file into ~/Documents/Inbox/
    Watcher detects it (3s debounce)
    For digital PDFs (avg >100 chars/page) → pymupdf4llm → Markdown (fast)
    For scanned PDFs → ocrmypdf + Tesseract → pymupdf4llm → Markdown (slower)
    For Office files → markitdown → Markdown
    Result appears in ~/Documents/Research/<filename>.md
    Failed files moved to ~/Documents/Inbox_Failed/

### Directory Layout

~/Documents/
├── Inbox/         ← Drop files here
├── Research/      ← Converted Markdown appears here
└── Inbox_Failed/  ← Files that couldn't be converted

### Building Locally

git clone https://github.com/kirijin/mark-dawn.git
cd mark-dawn
podman build -t mark-dawn:latest .
MARK_DAWN_IMAGE=localhost/mark-dawn:latest ./mark-dawn.sh start
