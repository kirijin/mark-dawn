#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Tests for docx_styler.py — markdown parsing, inline runs, pandoc fallback."""
import sys
from pathlib import Path
from unittest import mock
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import docx_styler


class _FakeRun:
    def __init__(self, text):
        self.text = text
        self.bold = False
        self.italic = False
        self.font = mock.MagicMock()


class _FakePara:
    def __init__(self):
        self.runs = []
        self.style = None
        self.text = ""
        self.level = None

    def add_run(self, text=""):
        r = _FakeRun(text)
        self.runs.append(r)
        return r


class _FakeDoc:
    def __init__(self):
        self.paragraphs = []
        self.headings = []
        self.tables = []

    def add_paragraph(self, text="", style=None):
        p = _FakePara()
        p.text = text
        p.style = style
        self.paragraphs.append(p)
        return p

    def add_heading(self, text, level):
        h = _FakePara()
        h.text = text
        h.level = level
        self.headings.append(h)
        return h

    def add_table(self, rows=0, cols=0):
        t = mock.MagicMock()
        t.rows = rows
        t.cols = cols
        self.tables.append(t)
        return t


class TestInlineRun:
    def test_bold_italic_code(self):
        para = _FakePara()
        docx_styler._add_inline_run(para, "**b** *i* `c` plain")
        flags = [(r.text, r.bold, r.italic) for r in para.runs]
        assert ("b", True, False) in flags
        assert ("i", False, True) in flags
        assert ("c", False, False) in flags
        assert any(r.text.strip() == "plain" for r in para.runs)

    def test_unmatched_star_literal(self):
        para = _FakePara()
        docx_styler._add_inline_run(para, "a * b")
        assert not any(r.italic for r in para.runs)

    def test_empty_asterisks_literal(self):
        para = _FakePara()
        docx_styler._add_inline_run(para, "****")
        assert not any(r.bold for r in para.runs)


class TestBuildFromMd:
    def test_headings_and_bold_paragraph(self):
        doc = _FakeDoc()
        docx_styler._build_from_md(doc, "# H1\n\nhello **bold**\n\n- item")
        assert doc.headings[0].runs[0].text == "H1"
        assert doc.headings[0].level == 1
        assert any(r.bold for p in doc.paragraphs for r in p.runs)

    def test_code_block(self):
        doc = _FakeDoc()
        docx_styler._build_from_md(doc, "```\ndef f():\n    return 1\n```")
        styles = [p.style for p in doc.paragraphs]
        assert styles and all(s == "CodeBlock" for s in styles)

    def test_table(self):
        doc = _FakeDoc()
        docx_styler._build_from_md(doc, "| a | b |\n|---|---|\n| 1 | 2 |")
        assert doc.tables

    def test_no_boilerplate_heading(self):
        """A document with its own H1 must not gain a second title."""
        doc = _FakeDoc()
        docx_styler._build_from_md(doc, "# Real title\n\nbody")
        assert len(doc.headings) == 1


class TestFallback:
    def test_pandoc_fallback_when_no_pydocx(self, monkeypatch):
        monkeypatch.setattr(docx_styler, "HAS_PYDOCX", False)
        out = Path("/tmp/md-docx-test/out.docx")
        out.parent.mkdir(parents=True, exist_ok=True)
        with mock.patch.object(docx_styler.subprocess, "run") as run:
            run.return_value = mock.MagicMock(returncode=0)
            result = docx_styler.markdown_to_docx("# T", out)
        args = run.call_args.args[0]
        assert args[0] == "pandoc"
        assert result == out
