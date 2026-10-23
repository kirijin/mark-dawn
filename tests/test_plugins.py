#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Plugin system tests."""
import os
import sys
import tempfile
from pathlib import Path

import pytest

# convert_pdf.py imports fitz/pymupdf4llm/PIL at module load; mock them only in
# minimal CI environments (no PyMuPDF) so the plugin tests can import the
# module. In a full environment, leave the real modules in place.
from unittest import mock as _mock
for _name in ("fitz", "pymupdf4llm", "PIL"):
    try:
        __import__(_name)
    except Exception:
        sys.modules.setdefault(_name, _mock.MagicMock())
_real_docx = sys.modules.get("docx_styler")
if _real_docx is None:
    try:
        __import__("docx_styler")
        _real_docx = sys.modules.get("docx_styler")
    except Exception:
        sys.modules["docx_styler"] = _mock.MagicMock()
        _real_docx = None
if _real_docx is None and "docx_styler" not in sys.modules:
    sys.modules["docx_styler"] = _mock.MagicMock()

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def test_plugin_registration_via_env(tmp_path, monkeypatch):
    # Make examples/ importable.
    monkeypatch.syspath_prepend(str(ROOT))
    monkeypatch.setenv("MARK_DAWN_PLUGINS", "examples.plugin_txt")
    sys.modules.pop("convert_pdf", None)
    import convert_pdf
    convert_pdf._load_plugins()

    assert ".txt" in convert_pdf.HANDLERS
    h = convert_pdf.HANDLERS[".txt"]
    assert h.name == "txt"

    inp = tmp_path / "note.txt"
    inp.write_text("hello plugin", encoding="utf-8")
    out = tmp_path / "note.md"
    h.convert(inp, out)
    assert out.read_text(encoding="utf-8") == "hello plugin"


def test_plugin_local_dir(tmp_path, monkeypatch):
    plugin_dir = tmp_path / "plugins"
    plugin_dir.mkdir()
    (plugin_dir / "upper.py").write_text(
        "from pathlib import Path\n"
        "class H:\n"
        "    name='upper'; extensions={'.up'}\n"
        "    def convert(self, file_path, out_md):\n"
        "        out_md.write_text(Path(file_path).read_text().upper(), encoding='utf-8')\n"
        "HANDLER = H()\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("MARK_DAWN_PLUGIN_DIR", str(plugin_dir))
    sys.modules.pop("convert_pdf", None)
    import convert_pdf
    convert_pdf._load_plugins()

    assert ".up" in convert_pdf.HANDLERS
    inp = tmp_path / "a.up"
    inp.write_text("hi", encoding="utf-8")
    out = tmp_path / "a.md"
    convert_pdf.HANDLERS[".up"].convert(inp, out)
    assert out.read_text(encoding="utf-8") == "HI"
