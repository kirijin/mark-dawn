#!/usr/bin/env python3
"""mark-dawn watcher — monitors Inbox for new files, converts automatically."""
import time, subprocess, sys, os
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

_HOME = Path.home()
INBOX    = Path(os.environ.get("MARK_DAWN_INBOX_DIR",   str(_HOME / "Documents" / "Inbox")))
RESEARCH = Path(os.environ.get("MARK_DAWN_OUT_DIR",     str(_HOME / "Documents" / "Research")))
FAILED   = Path(os.environ.get("MARK_DAWN_FAILED_DIR",  str(_HOME / "Documents" / "Inbox_Failed")))
CONVERT  = Path(os.environ.get("MARK_DAWN_CONVERTER",   "/usr/local/bin/convert_pdf.py"))
DEBOUNCE = 3.0

# Extensions handled by convert_pdf.py
ALL_EXTS = {".pdf", ".djvu", ".tiff", ".tif", ".jpeg", ".jpg", ".png",
            ".bmp", ".webp", ".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

class InboxHandler(FileSystemEventHandler):
    def __init__(self):
        self.pending = {}

    def _touch(self, p):
        p = Path(p)
        ext = p.suffix.lower()
        # Skip hidden files and macOS metadata
        if p.name.startswith(".") or p.name == ".DS_Store":
            return
        if ext in ALL_EXTS:
            self.pending[p] = time.time()

    def on_created(self, e):
        if not e.is_directory:
            self._touch(e.src_path)
            print(f"[+] New: {Path(e.src_path).name}")

    def on_moved(self, e):
        if not e.is_directory:
            self._touch(e.dest_path)

    def on_modified(self, e):
        if not e.is_directory:
            self._touch(e.src_path)

def process_file(file_path: Path):
    ext = file_path.suffix.lower()

    # Detect Inbox subdirectory for output format routing
    args = [sys.executable, str(CONVERT), str(file_path)]
    try:
        parent = file_path.resolve().parent
        # If file is in .../Inbox/2docx/, add --docx flag
        if parent.name.lower() == "2docx":
            args.append("--docx")

        print(f"[~] Converting: {file_path.name}")
        if ext in ALL_EXTS:
            if ext in {".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"} \
               and parent.name.lower() != "2docx":
                # Office docs → markitdown (faster than convert_pdf.py for these)
                result = subprocess.run(
                    ["markitdown", str(file_path)],
                    capture_output=True, text=True, timeout=120,
                    env={**os.environ, "PYTHONIOENCODING": "utf-8"}
                )
                if result.returncode == 0 and result.stdout.strip():
                    (RESEARCH / f"{file_path.stem}.md").write_text(
                        result.stdout, encoding="utf-8")
                    file_path.unlink(missing_ok=True)
                    print(f"[✓] {file_path.stem}.md")
                    return True
                print(f"  markitdown failed ({result.returncode}), trying convert_pdf.py...")
                # Fall through to convert_pdf.py

            result = subprocess.run(args, timeout=700)
            if result.returncode == 0:
                file_path.unlink(missing_ok=True)
                print(f"[✓] {file_path.stem}.md")
                return True

    except subprocess.TimeoutExpired:
        print(f"[-] Timeout: {file_path.name}")
    except Exception as e:
        print(f"[-] Error: {file_path.name}: {e}")

    # Move to failed
    try:
        file_path.rename(FAILED / file_path.name)
    except Exception:
        pass
    return False

def main():
    INBOX.mkdir(parents=True, exist_ok=True)
    RESEARCH.mkdir(parents=True, exist_ok=True)
    FAILED.mkdir(parents=True, exist_ok=True)

    handler = InboxHandler()
    observer = Observer()
    observer.schedule(handler, str(INBOX), recursive=True)  # watch subdirs
    observer.start()

    print(f"[*] mark-dawn watcher started")
    print(f"[*] Watching: {INBOX} (recursive)")
    print(f"[*] Output:   {RESEARCH}")
    print(f"[*] Failed:   {FAILED}")

    try:
        while True:
            time.sleep(1.0)
            now = time.time()
            ready = [p for p, t in list(handler.pending.items())
                     if now - t >= DEBOUNCE and p.exists()]
            for p in ready:
                handler.pending.pop(p, None)
                process_file(p)
    except KeyboardInterrupt:
        print("\n[*] Stopping watcher...")
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
