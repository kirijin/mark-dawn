#!/usr/bin/env python3
import time, subprocess, sys, os  # ← os здесь, глобально!
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

INBOX = Path("/data/Inbox")
RESEARCH = Path("/data/Research")
FAILED = Path("/data/Inbox_Failed")
CONVERT_SCRIPT = Path("/usr/local/bin/convert_pdf.py")
DEBOUNCE = 3.0

class InboxHandler(FileSystemEventHandler):
    def __init__(self):
        self.pending = {}
    def _touch(self, p):
        p = Path(p)
        if p.suffix.lower() in ('.pdf', '.docx', '.xlsx', '.pptx', '.html', '.csv', '.rtf'):
            self.pending[p] = time.time()
    def on_created(self, e):
        if not e.is_directory:
            self._touch(e.src_path)
            print(f"[+] New file detected: {Path(e.src_path).name}")
    def on_moved(self, e):
        if not e.is_directory:
            self._touch(e.dest_path)
    def on_modified(self, e):
        if not e.is_directory:
            self._touch(e.src_path)

def process_file(file_path: Path):
    ext = file_path.suffix.lower()
    try:
        if ext == ".pdf":
            result = subprocess.run(
                [sys.executable, str(CONVERT_SCRIPT), str(file_path)],
                timeout=700
            )
            if result.returncode == 0 and (RESEARCH / f"{file_path.stem}.md").exists():
                file_path.unlink(missing_ok=True)
                return True
        elif ext in (".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"):
            result = subprocess.run(
                ["markitdown", str(file_path)],
                capture_output=True, text=True, timeout=120,
                env={**os.environ, "PYTHONIOENCODING": "utf-8"}  # ← теперь os доступен
            )
            if result.returncode == 0 and result.stdout:
                (RESEARCH / f"{file_path.stem}.md").write_text(result.stdout, encoding="utf-8")
                file_path.unlink(missing_ok=True)
                return True
    except Exception as e:
        print(f"[-] Exception processing {file_path.name}: {e}")
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
    observer.schedule(handler, str(INBOX), recursive=False)
    observer.start()
    print(f"[*] mark-dawn watcher started")
    print(f"[*] Watching: {INBOX}")
    print(f"[*] Output:   {RESEARCH}")
    print(f"[*] Failed:   {FAILED}")
    try:
        while True:
            time.sleep(1.0)
            now = time.time()
            ready = [p for p, t in list(handler.pending.items()) if now - t >= DEBOUNCE and p.exists()]
            if ready:
                for p in ready:
                    handler.pending.pop(p, None)
                    print(f"[~] Processing: {p.name}")
                    process_file(p)
    except KeyboardInterrupt:
        print("[*] Stopping watcher...")
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
