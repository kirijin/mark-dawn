#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""mark-dawn converter — PDF, DjVu, images, office docs → markdown (or DOCX).

Single canonical pipeline shared by every platform (Linux container, macOS
brew/venv, macOS Apple Container, Windows portable). The launchers pass the
same env schema everywhere:

  MARK_DAWN_OUT_DIR      output folder          (default ~/Documents/Research)
  MARK_DAWN_FAILED_DIR   failed-input folder    (default ~/Documents/Inbox_Failed)
  MARK_DAWN_LANGS        OCR language pack      (default eng+rus+fra+deu+chi_sim+jpn)
  MARK_DAWN_MAX_PAGES    scanned-render page cap (default 50)
  MARK_DAWN_MAX_DIM      max rendered dimension px (default 2400)

Usage: convert_pdf.py FILE [--docx]
Exit codes: 0 ok, 1 failure, 2 busy (another conversion holds the lock).
"""
import os, sys, shutil, subprocess, tempfile, time, hashlib, importlib, importlib.util
from pathlib import Path

import fitz
import pymupdf4llm
from PIL import Image as PImage
import docx_styler

_HOME = Path.home()
OUT_DIR = Path(os.environ.get("MARK_DAWN_OUT_DIR",    str(_HOME / "Documents" / "Research")))
FAILED  = Path(os.environ.get("MARK_DAWN_FAILED_DIR",  str(_HOME / "Documents" / "Inbox_Failed")))
OUT_DIR.mkdir(parents=True, exist_ok=True)
FAILED.mkdir(parents=True, exist_ok=True)

OCRLANGS   = os.environ.get("MARK_DAWN_LANGS", "eng+rus+fra+deu+chi_sim+jpn")
MAX_PAGES  = int(os.environ.get("MARK_DAWN_MAX_PAGES", "50"))
MAX_DIM    = int(os.environ.get("MARK_DAWN_MAX_DIM",   "2400"))
LOCK_STALE_AFTER = 30 * 60  # seconds; steal locks older than this

IMAGE_EXTS = {".tiff", ".tif", ".jpeg", ".jpg", ".png", ".bmp", ".webp"}
DOC_EXTS   = {".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

# ---------------------------------------------------------------------------
# Plugin system for handlers
# ---------------------------------------------------------------------------
# A handler is any object with `.extensions` (set of suffixes) and
# `.convert(file_path, out_md)`. Built-ins register first; plugins (entry
# points, local dir, MARK_DAWN_PLUGINS) can override them.
HANDLERS = {}


class _BuiltinHandler:
    def __init__(self, name, extensions, func_name):
        self.name = name
        self.extensions = {e.lower() for e in extensions}
        self.func_name = func_name

    def convert(self, file_path, out_md):
        globals()[self.func_name](file_path, out_md)


def _register_handler(handler):
    for ext in getattr(handler, "extensions", ()) or ():
        HANDLERS[str(ext).lower()] = handler


def _load_plugins():
    """Discover and register handlers from entry points, local dir, and env."""
    # 1. Python entry points (pip-installed packages).
    try:
        from importlib.metadata import entry_points
        eps = entry_points()
        group = eps.get("mark_dawn.handlers", []) if hasattr(eps, "get") else []
        try:
            group = eps.select(group="mark_dawn.handlers")
        except Exception:
            pass
        for ep in group:
            try:
                _register_handler(ep.load())
            except Exception as e:
                print(f"plugin load failed ({ep.name}): {e}", file=sys.stderr)
    except Exception:
        pass
    # 2. Local plugin directory.
    local_dir = Path(os.environ.get(
        "MARK_DAWN_PLUGIN_DIR",
        str(Path.home() / ".config" / "mark-dawn" / "plugins"))).expanduser()
    if local_dir.is_dir():
        for py in sorted(local_dir.glob("*.py")):
            try:
                spec = importlib.util.spec_from_file_location(py.stem, py)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                h = getattr(mod, "HANDLER", None)
                if h is None and hasattr(mod, "register"):
                    h = mod.register()
                if h is not None:
                    _register_handler(h)
            except Exception as e:
                print(f"plugin load failed ({py}): {e}", file=sys.stderr)
    # 3. Env-specified modules.
    for modname in os.environ.get("MARK_DAWN_PLUGINS", "").split(","):
        modname = modname.strip()
        if not modname:
            continue
        try:
            mod = importlib.import_module(modname)
            h = getattr(mod, "HANDLER", None)
            if h is None and hasattr(mod, "register"):
                h = mod.register()
            if h is not None:
                _register_handler(h)
        except Exception as e:
            print(f"plugin load failed ({modname}): {e}", file=sys.stderr)


# Register built-ins.
for _h in (_BuiltinHandler("pdf", {".pdf"}, "_handle_pdf"),
           _BuiltinHandler("djvu", {".djvu"}, "_handle_djvu"),
           _BuiltinHandler("image", IMAGE_EXTS, "_handle_image"),
           _BuiltinHandler("doc", DOC_EXTS, "_handle_doc")):
    _register_handler(_h)

# Windows portable layout: <install>/scripts/convert_pdf.py → <install>/.msys2
_INSTALL_DIR = Path(__file__).resolve().parent.parent
_MSYS2_MINGW = _INSTALL_DIR / ".msys2" / "mingw64" / "bin"
_MSYS2_USR   = _INSTALL_DIR / ".msys2" / "usr" / "bin"
_TESSDATA    = _INSTALL_DIR / "tessdata"


def _build_env():
    """Subprocess env; prepends MSYS2 dirs when a portable Windows install is detected."""
    env = os.environ.copy()
    extra = [d for d in (str(_MSYS2_MINGW), str(_MSYS2_USR)) if Path(d).is_dir()]
    if extra:
        env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    if _TESSDATA.is_dir():
        env["TESSDATA_PREFIX"] = str(_TESSDATA)
    return env


def _find_ocrmypdf():
    """ocrmypdf executable — PATH first, then the Python Scripts dir (Windows)."""
    exe = shutil.which("ocrmypdf")
    if exe:
        return exe
    scripts_dir = Path(sys.executable).parent / "Scripts"
    for cand in (scripts_dir / "ocrmypdf.exe", scripts_dir / "ocrmypdf"):
        if cand.is_file():
            return str(cand)
    return "ocrmypdf"


def _unique_path(directory: Path, name: str) -> Path:
    """Collision-safe name: report.md, report (1).md, report (2).md, ..."""
    candidate = directory / name
    if not candidate.exists():
        return candidate
    stem, ext = os.path.splitext(name)
    for i in range(1, 10000):
        candidate = directory / f"{stem} ({i}){ext}"
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Could not allocate a unique name for {name} in {directory}")


def _pid_alive(pid):
    """Best-effort liveness check; falls back to alive on uncertain platforms."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        # PermissionError => process exists but isn't ours; treat as alive.
        # On Windows os.kill semantics differ, so err on the side of "alive".
        return True


def _lock_path(file_path):
    """Lock keyed on the resolved input identity, not just the basename."""
    identity = str(Path(file_path).resolve())
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:16]
    return OUT_DIR / (".%s.lock" % digest)


def _acquire_lock(file_path):
    """Atomic O_EXCL lock; steal only when the owning PID is dead.

    Returns the lock path, or None if another (live) conversion holds it.
    """
    lock = _lock_path(file_path)
    for _ in range(2):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return lock
        except FileExistsError:
            try:
                owner_raw = lock.read_text().strip()
                owner = int(owner_raw) if owner_raw.isdigit() else None
            except FileNotFoundError:
                continue
            except OSError:
                owner = None
            if owner is not None and _pid_alive(owner):
                try:
                    age = time.time() - lock.stat().st_mtime
                except FileNotFoundError:
                    continue
                if age <= LOCK_STALE_AFTER:
                    return None
            lock.unlink(missing_ok=True)
            continue
        except FileNotFoundError:
            continue
    return None


def _release_lock(lock):
    try:
        lock.unlink(missing_ok=True)
    except Exception:
        pass



def _clean_markdown(text: str) -> str:
    """Deterministic cleanup of generated markdown (OCR-friendly)."""
    import re, unicodedata
    text = unicodedata.normalize("NFKC", text)
    # De-hyphenate line-broken words (common OCR artifact).
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)
    lines = [ln.rstrip() for ln in text.split("\n")]
    out = []
    blanks = 0
    for ln in lines:
        if ln == "":
            blanks += 1
            if blanks <= 2:
                out.append(ln)
        else:
            blanks = 0
            out.append(ln)
    text = "\n".join(out).rstrip("\n") + "\n"
    return text


def _llm_cleanup(text: str) -> str:
    """Optional LLM cleanup pass; no-op unless configured."""
    url = os.environ.get("MARK_DAWN_LLM_URL", "").strip()
    if not url:
        return text
    try:
        import urllib.request, json as _json
        data = _json.dumps({"text": text}).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = _json.loads(resp.read().decode("utf-8"))
        return payload.get("text", text)
    except Exception as e:
        print(f"LLM cleanup failed, keeping cleaned markdown: {e}", file=sys.stderr)
        return text


def _atomic_write(path: Path, text: str):
    """Clean, optionally keep raw, then atomically replace the output."""
    raw = text
    text = _clean_markdown(text)
    if os.environ.get("MARK_DAWN_LLM_CLEANUP") == "1":
        text = _llm_cleanup(text)
    if os.environ.get("MARK_DAWN_KEEP_RAW") == "1":
        try:
            path.with_name(path.name + ".raw").write_text(raw, encoding="utf-8")
        except OSError:
            pass
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)  # atomic on the same filesystem; no unlink window


def _pdf_text_ratio(path):
    """Return (avg chars/page, page count). <100 → scanned."""
    d = fitz.open(str(path))
    n = len(d)
    t = sum(len(p.get_text()) for p in d)
    d.close()
    return t / n if n else 0, n


def _ocr_pdf(pdf_path, out_md):
    """OCR a PDF via ocrmypdf, write markdown."""
    with tempfile.TemporaryDirectory() as td:
        ocr_out = Path(td) / "ocr.pdf"
        subprocess.run([
            _find_ocrmypdf(), "--skip-text", "--deskew", "--clean", "-l", OCRLANGS,
            "-j", "1", "--output-type", "pdf",
            str(pdf_path), str(ocr_out),
        ], capture_output=True, text=True, timeout=600, check=True,
           env=_build_env())
        md = pymupdf4llm.to_markdown(str(ocr_out))
        _atomic_write(out_md, md)
        print("OCR complete. Converting to Markdown...")


def _md_to_docx(md_path):
    """Build a styled docx from markdown via python-docx (or pandoc fallback)."""
    from docx_styler import HAS_PYDOCX
    docx = md_path.with_suffix(".docx")
    if HAS_PYDOCX:
        md_text = md_path.read_text(encoding="utf-8")
        docx_styler.markdown_to_docx(md_text, docx)
        print(f"  Also wrote {docx.name} (python-docx, styled)")
    elif shutil.which("pandoc"):
        subprocess.run(["pandoc", str(md_path), "-o", str(docx)],
                       capture_output=True, timeout=120, check=True)
        print(f"  Also wrote {docx.name} (pandoc fallback)")
    else:
        print("  --docx skipped: needs python-docx or pandoc", file=sys.stderr)


def _handle_pdf(file_path, out_md):
    avg, n = _pdf_text_ratio(file_path)
    if n == 0:
        print("PDF has no pages; nothing to convert.", file=sys.stderr)
        sys.exit(1)
    if avg > 100:
        pages = None
        if n > MAX_PAGES:
            pages = list(range(MAX_PAGES))
            print(f"WARNING: digital PDF has {n} pages; processing first "
                  f"{MAX_PAGES}. Set MARK_DAWN_MAX_PAGES to raise the cap.",
                  file=sys.stderr)
        md = pymupdf4llm.to_markdown(str(file_path), pages=pages)
        _atomic_write(out_md, md)
        print(f"Digital PDF ({int(avg)} chars/page). Converting via pymupdf4llm...")
        return

    if n > MAX_PAGES:
        print(f"WARNING: scanned PDF has {n} pages; processing first {MAX_PAGES}. "
              f"Set MARK_DAWN_MAX_PAGES to raise the cap.", file=sys.stderr)
    print(f"Scanned PDF ({int(avg)} chars/page). Rendering pages for OCR...")
    doc = fitz.open(str(file_path))
    ppi = 200
    zoom = ppi / 72
    out_doc = fitz.open()
    for i in range(min(n, MAX_PAGES)):
        pix = doc[i].get_pixmap(matrix=fitz.Matrix(zoom, zoom))
        w, h = pix.width, pix.height
        if w > MAX_DIM or h > MAX_DIM:
            s = min(MAX_DIM / w, MAX_DIM / h)
            pix = doc[i].get_pixmap(matrix=fitz.Matrix(zoom * s, zoom * s))
        sr = doc[i].rect  # source page rect in points
        page = out_doc.new_page(width=sr.width, height=sr.height)
        page.insert_image(page.rect, pixmap=pix)
    doc.close()
    rendered = len(out_doc)
    if rendered == 0:
        _ocr_pdf(file_path, out_md)
        return
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
        tmp_pdf = Path(f.name)
    out_doc.save(str(tmp_pdf), garbage=4, deflate=True)
    out_doc.close()
    print(f"  Rendered {rendered} page(s) via fitz rasterization")
    _ocr_pdf(tmp_pdf, out_md)
    tmp_pdf.unlink(missing_ok=True)


def _djvu_page_count(file_path):
    """Page count via djvused -e n; 0 when unavailable. (djvutxt has no --pagecount.)"""
    if shutil.which("djvused"):
        r = subprocess.run(["djvused", str(file_path), "-e", "n"],
                           capture_output=True, text=True, timeout=30, env=_build_env())
        if r.returncode == 0 and r.stdout.strip().isdigit():
            return int(r.stdout.strip())
    return 0


def _handle_djvu(file_path, out_md):
    print("DjVu input. Trying native text extraction...")
    if shutil.which("djvutxt"):
        r = subprocess.run(["djvutxt", str(file_path)], capture_output=True,
                           text=True, timeout=120, env=_build_env())
        if r.returncode == 0 and r.stdout.strip():
            _atomic_write(out_md, r.stdout)
            print(f"OK: {out_md.name} (native DjVu text)")
            return
    if shutil.which("ddjvu"):
        print("  No native text, rendering pages via ddjvu...")
        with tempfile.TemporaryDirectory() as td:
            pdf_path = Path(td) / "out.pdf"
            np = _djvu_page_count(file_path)
            if np == 0:
                print("  Could not determine page count", file=sys.stderr)
                sys.exit(1)
            images = []
            for i in range(min(np, MAX_PAGES)):
                ppm = Path(td) / f"p{i:04d}.ppm"
                subprocess.run(["ddjvu", "-format=ppm", "-page", str(i + 1),
                                str(file_path), str(ppm)],
                               capture_output=True, timeout=120, check=True,
                               env=_build_env())
                if ppm.exists():
                    img = PImage.open(str(ppm))
                    w, h = img.size
                    if w > MAX_DIM or h > MAX_DIM:
                        s = min(MAX_DIM / w, MAX_DIM / h)
                        img = img.resize((int(w * s), int(h * s)), PImage.LANCZOS)
                    img.info["dpi"] = (200, 200)
                    # Materialise pixels before the source PPM is unlinked (PIL is
                    # lazy; otherwise save() may read from a deleted file).
                    img.load()
                    images.append(img)
                    ppm.unlink()
            if images:
                images[0].save(str(pdf_path), save_all=True,
                               append_images=images[1:], format="PDF")
                print(f"  Rendered {len(images)} page(s) via ddjvu")
                _ocr_pdf(pdf_path, out_md)
                return
    print("  DjVu support requires djvulibre-bin (djvutxt + ddjvu + djvused)", file=sys.stderr)
    sys.exit(1)


def _handle_image(file_path, out_md):
    print(f"Image input ({file_path.suffix}). Converting via PIL+ocrmypdf...")
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
        tmp_pdf = Path(f.name)
    try:
        img = PImage.open(str(file_path)).convert("RGB")
        img.save(str(tmp_pdf), "PDF", resolution=300)
        _ocr_pdf(tmp_pdf, out_md)
    finally:
        tmp_pdf.unlink(missing_ok=True)


def _handle_doc(file_path, out_md):
    """Office docs via markitdown."""
    print(f"Document input ({file_path.suffix}). Converting via markitdown...")
    r = subprocess.run(["markitdown", str(file_path)],
                       capture_output=True, text=True, timeout=120, env=_build_env())
    if r.returncode == 0 and r.stdout.strip():
        _atomic_write(out_md, r.stdout)
        print(f"OK: {out_md.name}")
    else:
        print(f"markitdown failed (exit {r.returncode})", file=sys.stderr)
        sys.exit(1)




def _check_input(file_path, ext):
    """Input hygiene: size cap + magic bytes. Returns (ok, message)."""
    max_mb = int(os.environ.get("MARK_DAWN_MAX_INPUT_MB", "200"))
    try:
        size = file_path.stat().st_size
    except OSError as e:
        return False, "cannot stat input: %s" % e
    if size > max_mb * 1024 * 1024:
        return False, "input too large: %d bytes > %d MB (MARK_DAWN_MAX_INPUT_MB)" % (size, max_mb)
    try:
        head = file_path.read_bytes()[:8]
    except OSError as e:
        return False, "cannot read input: %s" % e
    if ext == ".pdf" and not head.startswith(b"%PDF"):
        return False, "not a PDF (bad magic bytes)"
    if ext == ".djvu" and not head.startswith(b"AT&TFORM"):
        return False, "not a DjVu (bad magic bytes)"
    return True, ""


def main():
    if len(sys.argv) < 2:
        print("Usage: convert_pdf.py FILE [--docx]", file=sys.stderr)
        sys.exit(1)

    args = sys.argv[1:]
    want_docx = "--docx" in args
    langs_override = None
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--docx":
            i += 1
            continue
        if a == "--langs":
            if i + 1 >= len(args):
                print("Usage: convert_pdf.py FILE [--docx] [--langs LANGS]", file=sys.stderr)
                sys.exit(1)
            langs_override = args[i + 1]
            i += 2
            continue
        if a.startswith("--langs="):
            langs_override = a.split("=", 1)[1]
            i += 1
            continue
        positional.append(a)
        i += 1

    if not positional:
        print("Usage: convert_pdf.py FILE [--docx] [--langs LANGS]", file=sys.stderr)
        sys.exit(1)
    file_path = Path(positional[0])

    if langs_override:
        global OCRLANGS
        OCRLANGS = langs_override

    if not file_path.exists():
        print(f"File not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    ok, msg = _check_input(file_path, file_path.suffix.lower())
    if not ok:
        print(msg, file=sys.stderr)
        sys.exit(1)

    out_md = _unique_path(OUT_DIR, f"{file_path.stem}.md")
    ext = file_path.suffix.lower()

    lock = _acquire_lock(file_path)
    if lock is None:
        print(f"BUSY: another conversion for '{file_path.stem}' is running", file=sys.stderr)
        sys.exit(2)

    _load_plugins()

    handler = HANDLERS.get(ext)
    if handler is None:
        print(f"Unsupported format: {ext}", file=sys.stderr)
        sys.exit(1)
    try:
        handler.convert(file_path, out_md)

        if want_docx:
            _md_to_docx(out_md)

        print(f"OK: {out_md.name}")
        sys.exit(0)
    except subprocess.TimeoutExpired:
        print("Timeout: operation took too long", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        _release_lock(lock)


if __name__ == "__main__":
    main()
