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
import os, sys, shutil, subprocess, tempfile, time
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


def _acquire_lock(stem: str):
    """Atomic O_EXCL lock in OUT_DIR; steals locks older than LOCK_STALE_AFTER.

    Returns the lock path, or None if another conversion holds it.
    """
    lock = OUT_DIR / f".{stem}.lock"
    for _ in range(2):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return lock
        except FileExistsError:
            try:
                age = time.time() - lock.stat().st_mtime
            except FileNotFoundError:
                continue  # raced with a concurrent release; retry
            if age > LOCK_STALE_AFTER:
                lock.unlink(missing_ok=True)
                continue
            return None
    return None


def _release_lock(lock):
    try:
        lock.unlink(missing_ok=True)
    except Exception:
        pass


def _atomic_write(path: Path, text: str):
    """Write via tmp+rename so a crash never leaves a half-written output."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    if path.exists():
        path.unlink()
    tmp.rename(path)


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
            _find_ocrmypdf(), "--skip-text", "-l", OCRLANGS,
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
    if avg > 100:
        md = pymupdf4llm.to_markdown(str(file_path))
        _atomic_write(out_md, md)
        print(f"Digital PDF ({int(avg)} chars/page). Converting via pymupdf4llm...")
        return

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


def main():
    if len(sys.argv) < 2:
        print("Usage: convert_pdf.py FILE [--docx]", file=sys.stderr)
        sys.exit(1)

    file_path = Path(sys.argv[1])
    want_docx = "--docx" in sys.argv

    if not file_path.exists():
        print(f"File not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    out_md = _unique_path(OUT_DIR, f"{file_path.stem}.md")
    ext = file_path.suffix.lower()

    lock = _acquire_lock(file_path.stem)
    if lock is None:
        print(f"BUSY: another conversion for '{file_path.stem}' is running", file=sys.stderr)
        sys.exit(2)

    try:
        if ext == ".pdf":
            _handle_pdf(file_path, out_md)
        elif ext == ".djvu":
            _handle_djvu(file_path, out_md)
        elif ext in IMAGE_EXTS:
            _handle_image(file_path, out_md)
        elif ext in DOC_EXTS:
            _handle_doc(file_path, out_md)
        else:
            print(f"Unsupported format: {ext}", file=sys.stderr)
            sys.exit(1)

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
