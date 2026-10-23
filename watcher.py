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
import os, sys, time, json, subprocess, signal, threading, http.server, socketserver
from concurrent.futures import ThreadPoolExecutor
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
# restored attempt counts from a previous (crashed) run
_restored = {}
_pending_lock = threading.Lock()
_state_lock = threading.Lock()
_inflight = set()
_executor = None

_state = {"pid": os.getpid(), "started": "", "inbox": str(INBOX),
          "pending": 0, "updated": "", "last": [], "status": "idle", "current": ""}


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)


def _save_state():
    if not STATE_FILE:
        return
    with _state_lock:
        try:
            _state["pending"] = len(_pending)
            _state["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
            _state["queue"] = [
                {"path": str(p), "seen": info["seen"], "attempts": info["attempts"],
                 "ready_at": info["ready_at"]}
                for p, info in _pending.items()
            ]
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            tmp = STATE_FILE.with_name(STATE_FILE.name + ".tmp")
            tmp.write_text(json.dumps(_state, indent=1), encoding="utf-8")
            os.replace(tmp, STATE_FILE)
        except Exception:
            pass
        return


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


def _worker(p, info):
    """Process one ready file in a worker thread; handle retry/busy/failed."""
    global _pending
    result = process_file(p)
    if result is True:
        return
    if isinstance(result, str):  # "busy"
        info["ready_at"] = time.time() + RETRY_DELAY
        with _pending_lock:
            _pending[p] = info
        return
    info["attempts"] += 1
    if info["attempts"] < MAX_ATTEMPTS:
        info["ready_at"] = time.time() + RETRY_DELAY * info["attempts"]
        with _pending_lock:
            _pending[p] = info
        log(f"Retry {info['attempts']}/{MAX_ATTEMPTS} in "
            f"{int(RETRY_DELAY * info['attempts'])}s: {p.name}")
    else:
        _move_failed(p)


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
        _state["status"] = "converting"
        _state["current"] = p.name
        _save_state()
        result = process_file(p)
        _state["status"] = "idle"
        _state["current"] = ""
        _save_state()
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
    # Load saved attempt counts from a previous run.
    global _restored
    try:
        if STATE_FILE and STATE_FILE.is_file():
            data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            for q in data.get("queue", []) or []:
                _restored[q["path"]] = q
    except Exception:
        _restored = {}

    try:
        for p in INBOX.rglob("*"):
            if p.is_file():
                _touch(p)
                if str(p) in _restored:
                    saved = _restored[str(p)]
                    if p in _pending:
                        _pending[p]["attempts"] = int(saved.get("attempts", 0))
                        _pending[p]["ready_at"] = float(saved.get("ready_at", _pending[p]["ready_at"]))
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


_STOP = False


def _request_stop(signum, frame):
    global _STOP
    _STOP = True



class _StatusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] not in ("/", "/status"):
            self.send_response(404)
            self.end_headers()
            return
        try:
            body = json.dumps(_state, ensure_ascii=False).encode("utf-8")
        except Exception:
            body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def _start_status_server(port):
    try:
        httpd = socketserver.ThreadingTCPServer(("0.0.0.0", port), _StatusHandler)
        httpd.daemon_threads = True
        httpd.serve_forever()
    except Exception as e:
        log(f"Status server failed to start on port {port}: {e}")



def main():
    global _STOP
    signal.signal(signal.SIGTERM, _request_stop)
    signal.signal(signal.SIGINT, _request_stop)
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

    global _executor
    workers = int(os.environ.get("MARK_DAWN_WORKERS", "1"))
    if workers < 1:
        workers = 1
    _executor = ThreadPoolExecutor(max_workers=workers)
    log(f"Worker pool: {workers} concurrent conversion(s)")

    status_port = int(os.environ.get("MARK_DAWN_STATUS_PORT", "0"))
    if status_port > 0:
        threading.Thread(target=_start_status_server, args=(status_port,), daemon=True).start()
        log(f"Status endpoint: http://0.0.0.0:{status_port}/status")

    _backlog()

    try:
        if workers == 1:
            while not _STOP:
                time.sleep(1.0)
                _process_pending(time.time())
                _save_state()
        else:
            while not _STOP:
                time.sleep(1.0)
                now = time.time()
                ready = []
                with _pending_lock:
                    for p, info in list(_pending.items()):
                        if not p.exists():
                            del _pending[p]
                            continue
                        if now < info["ready_at"]:
                            continue
                        if not _stable_size(p):
                            info["ready_at"] = now + 1.0
                            continue
                        del _pending[p]
                        ready.append((p, info))
                for p, info in ready:
                    if len(_inflight) >= workers:
                        info["ready_at"] = now + 1.0
                        with _pending_lock:
                            _pending[p] = info
                        continue
                    fut = _executor.submit(_worker, p, info)
                    _inflight[fut] = p
                done = [f for f in list(_inflight) if f.done()]
                for f in done:
                    _inflight.pop(f, None)
                    try:
                        f.result()
                    except Exception as e:
                        log(f"worker error: {e}")
                _save_state()
    except KeyboardInterrupt:
        _request_stop(signal.SIGINT, None)

    log("Stopping watcher...")
    if _executor is not None:
        _executor.shutdown(wait=True, cancel_futures=False)
    observer.stop()
    observer.join()
    _state["stopped"] = time.strftime("%Y-%m-%d %H:%M:%S")
    _save_state()
    if PID_FILE:
        try:
            PID_FILE.unlink(missing_ok=True)
        except Exception:
            pass


if __name__ == "__main__":
    main()
