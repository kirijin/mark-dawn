#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Golden-file regression tests for the conversion pipeline.

Runs only when the real dependencies (pymupdf4llm, and ocrmypdf for scanned
inputs) are importable/executable. Otherwise skipped, so the unit suite stays
green in minimal environments.
"""
import os
import sys
import tempfile
import shutil
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "tests" / "golden"


def _normalize(text):
    lines = [ln.rstrip() for ln in text.splitlines()]
    # collapse 3+ blank lines to 2
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
    return "\n".join(out).strip() + "\n"


def _deps_ok(need_ocr=False):
    try:
        import pymupdf4llm  # noqa
    except Exception:
        return False
    if need_ocr:
        if shutil.which("ocrmypdf") is None:
            return False
    return True


@pytest.mark.parametrize("name,need_ocr", [("digital", False), ("scanned", True)])
def test_golden(name, need_ocr, tmp_path, monkeypatch):
    if not _deps_ok(need_ocr):
        pytest.skip("real conversion dependencies not available")
    if not _deps_ok(False):
        pytest.skip("pymupdf4llm not available")

    inp = GOLDEN / "inputs" / f"{name}.pdf"
    exp = GOLDEN / "expected" / f"{name}.md"
    assert inp.is_file() and exp.is_file()

    out_dir = tmp_path / "Research"
    failed_dir = tmp_path / "Failed"
    out_dir.mkdir()
    failed_dir.mkdir()
    monkeypatch.setenv("MARK_DAWN_OUT_DIR", str(out_dir))
    monkeypatch.setenv("MARK_DAWN_FAILED_DIR", str(failed_dir))
    monkeypatch.setenv("MARK_DAWN_INBOX_DIR", str(tmp_path / "Inbox"))

    sys.modules.pop("convert_pdf", None)
    sys.path.insert(0, str(ROOT))
    import convert_pdf
    convert_pdf.OUT_DIR = out_dir
    convert_pdf.FAILED = failed_dir

    argv = ["convert_pdf.py", str(inp)]
    with pytest.raises(SystemExit) as exc:
        with monkeypatch.context() as m:
            m.setattr(sys, "argv", argv)
            convert_pdf.main()
    assert exc.value.code == 0

    produced = out_dir / f"{name}.md"
    assert produced.is_file(), "no output produced"
    actual = _normalize(produced.read_text(encoding="utf-8"))
    expected = _normalize(exp.read_text(encoding="utf-8"))
    assert actual == expected, "golden mismatch for %s" % name
