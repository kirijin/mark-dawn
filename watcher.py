#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""mark-dawn watcher — monitors Inbox for new files, converts automatically.

Shared by every platform (Linux container, macOS brew/venv, macOS Apple
Container, Windows portable). All conversion goes through convert_pdf.py so
the conversion logic exists in exactly one place; this file only watches,
debounces, retries, and moves files.

Env schema (same one every launcher passes):
  MARK_DAWN_INBOX_DIR    watch folder         (default ~/Documents/Inbox)
  MARK_DAWN_OUT_DIR      output folder        (default ~/Documents/Research)
  MARK_DAWN_FAILED_DIR   failed-input folder  (default ~/Documents/Inbox_Failed)
  MARK_DAWN_CONVERTER    convert_pdf.py path  (default: this script's directory)
  MARK_DAWN_PID          pid file to write    (Windows launcher relies on it)
  MARK_DAWN_STATE_FILE   JSON status file     (the `status` command reads it)
"""
import os, sys, time, json, subprocess
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

_HOME = Path.home()
INBOX    = Path(os.environ.get("MARK_DAWN_INBOX_DIR",   str(_HOME / "Documents" / "Inbox")))
RESEARCH = Path(os.environ.get("MARK_DAWN_OUT_DIR",     str(_HOME / "Documents" / "Research")))
FAILED   = Path(os.environ.get("MARK_DAWN_FAILED_DIR",  str(_HOME / "Documents" / "Inbox_Failed")))
CONVERT  = Path(os.environ.get("MARK_DAWN_CONVERTER",   str(Path(__file__).resolve().parent / "convert_pdf.py")))
PID_FILE = Path(os.environ["MARK_DAWN_PID"]) if os.environ.get("MARK_DAWN_PID") else None
STATE_FILE = Path(os.environ["MARK_DAWN_STATE_FILE"]) if os.environ.get("MARK_DAWN_STATE_FILE") else None

INBOX_ROOT = str(INBOX.resolve())

DEBOUNCE = 3.0        # seconds without modification before a file is processed
RETRY_DELAY = 30.0    # base backoff between failed attempts
MAX_ATTEMPTS = 3      # attempts before the file is moved to Inbox_Failed
CONVERT_TIMEOUT = 900

SUPPORTED = {".pdf", ".djvu", ".tiff", ".tif", ".jpeg", ".jpg", ".png",
             ".bmp", ".webp", ".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

# path -> {"seen": float, "attempts": int, "ready_at": float}
_pending = {}

_state = {"pid": os.getpid(), "started": "", "inbox": str(INBOX),
          "pending": 0, "updated": "", "last": []}


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)


def _save_state():
    if not STATE_FILE:
        return
    try:
        _state["pending"] = len(_pending)
        _state["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(_state, indent=1), encoding="utf-8")
    except Exception:
        pass


def _note_result(name, status, out):
    _state["last"] = ([
        {"time": time.strftime("%H:%M:%S"), "file": name,
         "status": status, "out": out}
    ] + _state["last"])[:5]


def _unique_path(directory: Path, name: str) -> Path:
    candidate = directory / name
    if not candidate.exists():
        return candidate
    stem, ext = os.path.splitext(name)
    for i in range(1, 10000):
        candidate = directory / f"{stem} ({i}){ext}"
        if not candidate.exists():
            return candidate
    return directory / f"{stem}.{int(time.time())}{ext}"


def _touch(p):
    p = Path(p)
    if p.is_dir() or p.name.startswith(".") or p.suffix.lower() not in SUPPORTED:
        return
    try:
        if not str(p.resolve()).startswith(INBOX_ROOT + os.sep):
            return  # files moved OUT of the inbox are not our job
    except OSError:
        return
    if p not in _pending:
        _pending[p] = {"seen": time.time(), "attempts": 0, "ready_at": time.time()}
        log(f"Detected: {p.name}")
    else:
        # Modification resets the debounce window (mid-copy file).
        _pending[p]["seen"] = time.time()
        _pending[p]["ready_at"] = time.time()


def _stable_size(p, settle=0.5):
    """True when the file size is unchanged across `settle` seconds."""
    try:
        s1 = p.stat().st_size
    except OSError:
        return False
    time.sleep(settle)
    try:
        return p.stat().st_size == s1
    except OSError:
        return False


def _parse_output_name(stdout):
    """Last 'OK: <name>' line printed by convert_pdf.py."""
    for line in reversed((stdout or "").splitlines()):
        if line.startswith("OK: "):
            return line[4:].strip()
    return None


def _convert(path):
    """Convert one file. Returns Path on success, 'busy' when the lock is held
    elsewhere (retryable, never a failure), None on real failure."""
    args = [sys.executable, str(CONVERT), str(path)]
    if path.parent.name.lower() == "2docx":
        args.append("--docx")
    try:
        result = subprocess.run(args, capture_output=True, text=True,
                                timeout=CONVERT_TIMEOUT)
    except subprocess.TimeoutExpired:
        log(f"Timeout: {path.name}")
        return None
    except Exception as e:
        log(f"Error: {path.name}: {e}")
        return None

    if result.returncode == 2:
        log(f"Busy (lock held), will retry: {path.name}")
        return "busy"  # retryable — NOT a failure, never counts toward Failed

    if result.returncode != 0:
        tail = (result.stderr or "").strip().splitlines()
        detail = tail[-1] if tail else f"exit {result.returncode}"
        log(f"FAIL: {path.name}: {detail}")
        return None

    name = _parse_output_name(result.stdout)
    out = RESEARCH / name if name else None
    if out and out.exists():
        path.unlink(missing_ok=True)
        return out
    log(f"FAIL: {path.name}: conversion reported success but no output file")
    return None


def _move_failed(path):
    try:
        FAILED.mkdir(parents=True, exist_ok=True)
        dest = _unique_path(FAILED, path.name)
        path.rename(dest)
        log(f"FAIL: {path.name} moved to {dest.name} after {MAX_ATTEMPTS} attempts")
        _note_result(path.name, "failed", dest.name)
    except Exception as e:
        log(f"Could not move {path.name} to Inbox_Failed: {e}")


def process_file(path):
    result = _convert(path)
    if isinstance(result, str):  # "busy" sentinel — lock held elsewhere
        return "busy"
    if isinstance(result, Path):
        log(f"OK: {path.name} -> {result.name}")
        _note_result(path.name, "ok", result.name)
        return True
    return False


def _process_pending(now):
    """One sweep of the pending queue. Returns the number of files handled."""
    handled = 0
    for p, info in list(_pending.items()):
        if not p.exists():
            _pending.pop(p, None)
            continue
        if now < info["ready_at"]:
            continue
        if not _stable_size(p):
            info["ready_at"] = now + 1.0
            continue
        _pending.pop(p, None)
        handled += 1
        result = process_file(p)
        if result is True:
            continue
        if isinstance(result, str):  # "busy" — lock held, not a failure
            # Another conversion holds the lock for this stem — the file is
            # fine, so it never counts toward the Failed move. Reschedule
            # without touching the attempt counter.
            info["ready_at"] = now + RETRY_DELAY
            _pending[p] = info
            continue
        info["attempts"] += 1
        if info["attempts"] < MAX_ATTEMPTS:
            info["ready_at"] = now + RETRY_DELAY * info["attempts"]
            _pending[p] = info
            log(f"Retry {info['attempts']}/{MAX_ATTEMPTS} in "
                f"{int(RETRY_DELAY * info['attempts'])}s: {p.name}")
        else:
            _move_failed(p)
    return handled


def _backlog():
    """Pick up files that were already in the inbox before we started."""
    try:
        for p in INBOX.rglob("*"):
            if p.is_file():
                _touch(p)
    except Exception as e:
        log(f"Backlog scan error: {e}")
    if _pending:
        log(f"Backlog: {len(_pending)} file(s) already in inbox")


class InboxHandler(FileSystemEventHandler):
    def on_created(self, e):
        if not e.is_directory:
            _touch(e.src_path)

    def on_moved(self, e):
        if not e.is_directory:
            _touch(e.dest_path)

    def on_modified(self, e):
        if not e.is_directory:
            _touch(e.src_path)


def main():
    for d in (INBOX, RESEARCH, FAILED):
        d.mkdir(parents=True, exist_ok=True)

    if PID_FILE:
        try:
            tmp = PID_FILE.with_name(PID_FILE.name + ".tmp")
            tmp.write_text(str(os.getpid()))
            tmp.rename(PID_FILE)
        except Exception as e:
            log(f"WARNING: could not write PID file: {e}")

    _state["started"] = time.strftime("%Y-%m-%d %H:%M:%S")
    log(f"mark-dawn watcher started (PID {os.getpid()})")
    log(f"Watching: {INBOX} (recursive)")
    log(f"Output:   {RESEARCH}")
    log(f"Failed:   {FAILED}")
    _save_state()

    handler = InboxHandler()
    observer = Observer()
    observer.schedule(handler, str(INBOX), recursive=True)
    observer.start()

    _backlog()

    try:
        while True:
            time.sleep(1.0)
            _process_pending(time.time())
            _save_state()
    except KeyboardInterrupt:
        print("\n[*] Stopping watcher...", flush=True)
        observer.stop()

    observer.join()
    _state["stopped"] = time.strftime("%Y-%m-%d %H:%M:%S")
    _save_state()


if __name__ == "__main__":
    main()
