#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Tests for mdclean against real converter output.

Builds PDFs on disk with pymupdf and runs the actual conversion path, so these
cover the seam between producer and cleaner — where the metadata-key mismatch
that silently disabled page de-noise actually lived.
"""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

pymupdf = pytest.importorskip("pymupdf")

HEADER = "Journal of Document Engineering"
FOOTER = "Vol. 12, No. 3"


def _book(path: Path, pages=5, chapter="Chapter One"):
    doc = pymupdf.open()
    for i in range(1, pages + 1):
        page = doc.new_page()
        page.insert_text((72, 30), HEADER, fontsize=8, fontname="helv")
        page.insert_text((72, 60), chapter, fontsize=16, fontname="hebo")
        y = 95
        for line in [
            "Document conversion pipelines lose structure at every",
            "stage, and the loss is rarely visible until retrieval",
            "quality drops. This paragraph wraps across three lines.",
        ]:
            page.insert_text((72, y), line, fontsize=10, fontname="helv")
            y += 15
        page.insert_text((72, 780), str(i), fontsize=8, fontname="helv")
        page.insert_text((200, 780), FOOTER, fontsize=8, fontname="helv")
    doc.save(str(path))
    doc.close()
    return path


@pytest.fixture
def book_pdf(tmp_path):
    return _book(tmp_path / "book.pdf")


def test_page_provenance_injected(book_pdf):
    convert_pdf = pytest.importorskip("convert_pdf")
    md = convert_pdf._pdf_markdown(book_pdf)
    assert "<!-- page 1 -->" in md
    assert "<!-- page 5 -->" in md


def test_running_header_and_footer_removed(book_pdf, tmp_path):
    """The end-to-end contract: a running header must not reach the output."""
    convert_pdf = pytest.importorskip("convert_pdf")
    import mdclean

    md = convert_pdf._pdf_markdown(book_pdf)
    cleaned = mdclean.clean(md, title="book")

    assert HEADER not in cleaned
    assert FOOTER not in cleaned
    # Page numbers must not survive as standalone lines.
    assert "\n3\n" not in cleaned


def test_output_passes_gate(book_pdf):
    convert_pdf = pytest.importorskip("convert_pdf")
    import mdclean

    cleaned = mdclean.clean(convert_pdf._pdf_markdown(book_pdf), title="book")
    errors = [(c, m) for s, c, m in mdclean.analyze(cleaned) if s == "E"]
    assert errors == [], "converted output must satisfy the gate: %s" % errors


def test_paragraph_joining_preserves_content(book_pdf):
    convert_pdf = pytest.importorskip("convert_pdf")
    import mdclean

    cleaned = mdclean.clean(convert_pdf._pdf_markdown(book_pdf), title="book")
    # Wrapped lines become one paragraph; no content is lost.
    assert "lose structure at every stage, and the loss is rarely visible" in cleaned
    assert "three lines." in cleaned


def test_converter_writes_frontmatter(book_pdf, tmp_path, monkeypatch):
    convert_pdf = pytest.importorskip("convert_pdf")
    out_dir = tmp_path / "Research"
    out_dir.mkdir()
    monkeypatch.setattr(convert_pdf, "OUT_DIR", out_dir)

    convert_pdf._handle_pdf(book_pdf, out_dir / "book.md")

    text = (out_dir / "book.md").read_text(encoding="utf-8")
    assert text.startswith("---\n")
    assert "source: book.pdf" in text
    assert "pages: 5" in text


def test_empty_ocr_result_stays_empty(tmp_path):
    """A blank document must not gain an invented heading."""
    convert_pdf = pytest.importorskip("convert_pdf")
    out = tmp_path / "blank.md"
    convert_pdf._atomic_write(out, "", ocr=True, source="blank.pdf", page_count=1)
    assert out.read_text(encoding="utf-8").strip() == ""