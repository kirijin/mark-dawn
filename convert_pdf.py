#!/usr/bin/env python3
"""mark-dawn converter — PDF, DjVu, images → markdown (or docx)."""
import sys, os, subprocess, tempfile, shutil
from pathlib import Path
import fitz
import pymupdf4llm
from PIL import Image as PImage
import docx_styler

# Default paths — override via env
_HOME = Path.home()
OUT_DIR   = Path(os.environ.get("MARK_DAWN_OUT_DIR",    str(_HOME / "Documents" / "Research")))
FAILED    = Path(os.environ.get("MARK_DAWN_FAILED_DIR",  str(_HOME / "Documents" / "Inbox_Failed")))
OUT_DIR.mkdir(parents=True, exist_ok=True)
FAILED.mkdir(parents=True, exist_ok=True)

OCRLANGS = os.environ.get("MARK_DAWN_LANGS", "eng+rus+fra+deu+chi_sim+jpn")
MAX_PAGES = int(os.environ.get("MARK_DAWN_MAX_PAGES", "50"))
MAX_DIM   = int(os.environ.get("MARK_DAWN_MAX_DIM",   "2400"))

IMAGE_EXTS = {".tiff", ".tif", ".jpeg", ".jpg", ".png", ".bmp", ".webp"}
DOC_EXTS   = {".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"}

def _pdf_text_ratio(path):
    """Return avg chars/page. <100 → scanned."""
    d = fitz.open(str(path))
    n = len(d)
    t = sum(len(p.get_text()) for p in d)
    d.close()
    return t / n if n else 0, n

def _ocr_pdf(pdf_path, out_md):
    """OCR a PDF, write markdown."""
    with tempfile.TemporaryDirectory() as td:
        ocr_out = Path(td) / "ocr.pdf"
        subprocess.run([
            "ocrmypdf", "--skip-text", "-l", OCRLANGS,
            "-j", "1", "--output-type", "pdf",
            str(pdf_path), str(ocr_out),
        ], capture_output=True, text=True, timeout=600, check=True)
        md = pymupdf4llm.to_markdown(str(ocr_out))
        out_md.write_text(md, encoding="utf-8")
        print("OCR complete. Converting to Markdown...")

def _md_to_docx(md_path):
    """Build high-quality docx from markdown via python-docx (or pandoc fallback)."""
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
        out_md.write_text(md, encoding="utf-8")
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

def _handle_djvu(file_path, out_md):
    print("DjVu input. Trying native text extraction...")
    # Try djvutxt
    if shutil.which("djvutxt"):
        r = subprocess.run(["djvutxt", str(file_path)], capture_output=True,
                           text=True, timeout=120)
        if r.returncode == 0 and r.stdout.strip():
            out_md.write_text(r.stdout, encoding="utf-8")
            print(f"OK: {out_md.name} (native DjVu text)")
            return
    # Try ddjvu render
    if shutil.which("ddjvu"):
        print("  No native text, rendering pages via ddjvu...")
        with tempfile.TemporaryDirectory() as td:
            pdf_path = Path(td) / "out.pdf"
            r = subprocess.run(["djvutxt", "--pagecount", str(file_path)],
                               capture_output=True, text=True, timeout=30)
            np = int(r.stdout.strip()) if r.returncode == 0 else 0
            if np == 0:
                print("  Could not determine page count", file=sys.stderr)
                sys.exit(1)
            images = []
            for i in range(min(np, MAX_PAGES)):
                ppm = Path(td) / f"p{i:04d}.ppm"
                subprocess.run(["ddjvu", "-format=ppm", "-page", str(i+1),
                                str(file_path), str(ppm)],
                               capture_output=True, timeout=120, check=True)
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
    print("  DjVu support requires djvulibre-bin (djvutxt + ddjvu)", file=sys.stderr)
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
                       capture_output=True, text=True, timeout=120)
    if r.returncode == 0 and r.stdout.strip():
        out_md.write_text(r.stdout, encoding="utf-8")
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

    out_md = OUT_DIR / f"{file_path.stem}.md"
    ext = file_path.suffix.lower()

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

if __name__ == "__main__":
    main()
