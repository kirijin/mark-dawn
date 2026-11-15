#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Unit tests for mdclean — structure repair and the readability gate.

Pure stdlib: no PDF, OCR or network dependencies. Each test pins one rule so
a regression names itself.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mdclean  # noqa: E402


# ---------------------------------------------------------------------------
# page markers
# ---------------------------------------------------------------------------

def test_ocr_page_markers_leave_heading_tree():
    src = "## Page 1\n\nFirst page body.\n\n## Page 2\n\nSecond page body.\n"
    out = mdclean.clean(src)
    assert "## Page" not in out
    assert "<!-- page 1 -->" in out and "<!-- page 2 -->" in out
    assert "First page body." in out and "Second page body." in out


def test_single_page_keeps_no_marker():
    out = mdclean.clean("## Page 1\n\nOnly page.\n")
    assert "<!-- page" not in out


def test_pdf_break_separators_removed():
    src = "Alpha paragraph.\n\n-----\n\nBeta paragraph.\n"
    out = mdclean.clean(src)
    assert "-----" not in out
    assert "Alpha paragraph." in out and "Beta paragraph." in out


# ---------------------------------------------------------------------------
# running headers / footers / page numbers
# ---------------------------------------------------------------------------

def _book(pages, header="Journal of Testing", footer="https://example.org"):
    chunks = []
    for i in range(1, pages + 1):
        chunks.append("## Page %d\n\n%s\n\nBody paragraph %d continues here.\n\n%d\n\n%s"
                      % (i, header, i, i, footer))
    return "\n\n".join(chunks)


def test_running_header_and_footer_stripped():
    out = mdclean.clean(_book(6))
    assert "Journal of Testing" not in out
    assert "https://example.org" not in out
    assert "Body paragraph 6" in out


def test_running_header_kept_when_below_page_threshold():
    src = _book(2)
    out = mdclean.clean(src)
    assert "Journal of Testing" in out


def test_page_numbers_stripped():
    out = mdclean.clean(_book(6))
    for n in range(1, 7):
        assert "\n%d\n" % n not in out


def test_inline_numbers_are_content_not_page_numbers():
    src = "## Page 1\n\nIn 1969 the network went live.\n\n## Page 2\n\nIt had 4 nodes.\n"
    out = mdclean.clean(src)
    assert "In 1969 the network went live." in out
    assert "It had 4 nodes." in out


def test_numbered_section_headings_survive():
    """A numbered heading ("1 Introduction") must not be mistaken for a folio.

    Regression: a rule that stripped any short line starting with a digit
    deleted every numbered section heading in the document.
    """
    pages = []
    for i, (num, name) in enumerate([("1", "Introduction"), ("2", "Method"),
                                     ("3", "Results"), ("4", "Discussion")], 1):
        pages.append("<!-- page %d -->\n\nJournal of Testing\n\n%s %s\n\nBody text %d."
                     % (i, num, name, i))
    out = mdclean.clean("\n\n".join(pages), title="Sample")

    assert "1 Introduction" in out
    assert "2 Method" in out
    assert "3 Results" in out
    assert "4 Discussion" in out
    # The actual running header is still removed.
    assert "Journal of Testing" not in out


# ---------------------------------------------------------------------------
# paragraphs
# ---------------------------------------------------------------------------

def test_hard_wrapped_paragraph_joined():
    src = ("# Title\n\nThis sentence continues on the next line\n"
           "and ends here. A new sentence follows.\n")
    out = mdclean.clean(src)
    assert "This sentence continues on the next line and ends here." in out


def test_hyphenated_line_break_dehyphenated():
    src = "# Title\n\nSome long hyphen-\nated word appears.\n"
    out = mdclean.clean(src)
    assert "hyphenated" in out
    assert "hyphen-\n" not in out


def test_list_and_heading_lines_not_joined():
    src = "# Title\n\n- first item\n- second item\n\n## Section\n\nBody text.\n"
    out = mdclean.clean(src)
    assert "- first item\n- second item" in out
    assert "## Section" in out


def test_fenced_code_untouched():
    src = "# Title\n\n```python\nx = 1\ny = 2\n```\n"
    out = mdclean.clean(src)
    assert "```python\nx = 1\ny = 2\n```" in out


def test_no_join_flag_preserves_wraps():
    src = "# Title\n\nOne line\ntwo line.\n"
    out = mdclean.clean(src, join_lines=False)
    assert "One line\ntwo line." in out


# ---------------------------------------------------------------------------
# headings
# ---------------------------------------------------------------------------

def test_h1_synthesized_from_title_when_absent():
    src = "# " + "word " * 200 + "\n\nBody text of a substantial document.\n"
    out = mdclean.clean(src.replace("# word", "word"), title="Untitled Work")
    assert out.startswith("# Untitled Work\n")


def test_no_synthesized_h1_for_fragment():
    # A one-line fragment is not a work; inventing a title from the filename
    # would claim structure the document never had.
    out = mdclean.clean("Just a body paragraph.\n", title="Untitled Work")
    assert not out.startswith("# ")
    assert out.strip() == "Just a body paragraph."


def test_extra_h1_demoted():
    src = "# First\n\nText.\n\n# Second\n\nMore text.\n"
    out = mdclean.clean(src)
    # Multiple H1s are legitimate for books: chapters are peers and the
    # downstream splitter keys on H1 boundaries.
    h1s = [ln for ln in out.splitlines() if ln.startswith("# ")]
    assert len(h1s) == 2
    assert "# First" in out and "# Second" in out


def test_level_jump_raised():
    src = "# Title\n\n#### Deep immediately\n\nBody.\n"
    out = mdclean.clean(src)
    assert "## Deep immediately" in out


def test_caption_heading_demoted_to_italic():
    src = "# Title\n\n## Real Section\n\n### Figure 3\n\nBody.\n"
    out = mdclean.clean(src)
    assert "### Figure 3" not in out
    assert "*Figure 3*" in out


def test_russian_caption_heading_demoted():
    src = "# Название\n\n## Раздел\n\n### Рисунок 2\n\nТекст.\n"
    out = mdclean.clean(src)
    assert "*Рисунок 2*" in out


def test_chapter_openers_promoted_when_no_headings():
    src = ("Chapter 1\n\nOpening text.\n\nChapter 2\n\nMore text.\n")
    out = mdclean.clean(src)
    assert "## Chapter 1" in out
    assert "## Chapter 2" in out


def test_chapter_openers_not_promoted_when_headings_exist():
    src = ("# Book\n\n## Chapter 1\n\nOpening text.\n\nChapter 2\n\nMore.\n")
    out = mdclean.clean(src)
    assert out.count("## Chapter") == 1


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------

def test_table_separator_inserted():
    src = "| A | B |\n| 1 | 2 |\n"
    out = mdclean.clean(src)
    lines = [ln for ln in out.splitlines() if ln.startswith("|")]
    assert len(lines) == 3
    assert set(lines[1].replace("|", "").strip()) <= set("-: ")


def test_ragged_rows_padded():
    src = "| A | B | C |\n| --- | --- | --- |\n| 1 |\n"
    out = mdclean.clean(src)
    rows = [ln for ln in out.splitlines() if ln.startswith("|")]
    widths = {ln.count("|") for ln in rows}
    assert len(widths) == 1


def test_table_not_mangled_into_prose():
    src = "# T\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
    out = mdclean.clean(src)
    assert out.count("| A | B |") == 1


# ---------------------------------------------------------------------------
# frontmatter
# ---------------------------------------------------------------------------

def test_frontmatter_rendered_with_metadata():
    out = mdclean.clean("# T\n\nBody.\n",
                        meta={"title": "Book", "source": "a.pdf", "pages": 3,
                              "ocr": True, "converted": "2026-11-15"})
    assert out.startswith("---\n")
    assert 'source: "a.pdf"' in out or "source: a.pdf" in out
    assert "pages: 3" in out
    assert "ocr: true" in out


def test_frontmatter_quotes_values_with_colons():
    fm = mdclean.render_frontmatter({"title": "A: B"})
    assert '"A: B"' in fm


# ---------------------------------------------------------------------------
# idempotence
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("src", [
    "# T\n\nBody paragraph one.\n\n## S\n\nMore text.\n",
    "## Page 1\n\nBody.\n\n## Page 2\n\nMore.\n",
    "| A | B |\n| 1 | 2 |\n",
    "# T\n\n- a\n- b\n\n```py\nx=1\n```\n",
])
def test_clean_is_idempotent(src):
    once = mdclean.clean(src)
    twice = mdclean.clean(once)
    assert once == twice


@pytest.mark.parametrize("src", ["", "\n", "   ", "\n\n\n"])
def test_clean_is_idempotent_on_empty(src):
    """Regression: an unconditional trailing newline made empty input grow."""
    once = mdclean.clean(src)
    assert once == ""
    assert mdclean.clean(once) == ""


def test_clean_preserves_frontmatter_on_second_pass():
    """Regression: a second pass ate the YAML block and turned `---` into prose."""
    once = mdclean.clean("# T\n\n" + "body text. " * 40,
                         meta={"source": "x.pdf", "pages": 2})
    twice = mdclean.clean(once)
    assert twice == once
    assert twice.startswith("---\n")
    assert "source: x.pdf" in twice


def test_bare_number_survives_single_page_document():
    """Regression: folio stripping deleted content lines like `42`.

    Page-number removal is only meaningful when the input has page structure;
    on a one-page document a bare number is data.
    """
    src = "# Data\n\nProse intro that is long enough to be a document.\n\n42\n\nMore prose.\n"
    out = mdclean.clean(src)
    assert "42" in out


def test_folio_still_stripped_from_page_aware_document():
    """The fix above must not disable de-noise where it belongs."""
    pages = "\n\n".join("<!-- page %d -->\n\nJournal of Testing\n\nBody %d.\n\n%d"
                        % (i, i, i) for i in range(1, 7))
    out = mdclean.clean(pages)
    assert "Journal of Testing" not in out
    assert "\n3\n" not in out


# ---------------------------------------------------------------------------
# gate
# ---------------------------------------------------------------------------

def test_gate_flags_missing_h1():
    # A substantial document with no H1 at all is a real defect.
    findings = mdclean.analyze("## Only H2\n\n" + ("Body text. " * 100) + "\n")
    assert any(code == "E001" for _s, code, _m in findings)


def test_gate_accepts_fragment_without_h1():
    findings = mdclean.analyze("## Only H2\n\nBody.\n")
    assert not any(code == "E001" for _s, code, _m in findings)


def test_gate_flags_page_marker_heading():
    findings = mdclean.analyze("# T\n\n## Page 3\n\nBody.\n")
    assert any(code == "E004" for _s, code, _m in findings)


def test_gate_accepts_multiple_h1():
    findings = mdclean.analyze("# One\n\nBody.\n\n# Two\n\nMore.\n")
    assert not any(code in ("E001", "E002") for _s, code, _m in findings)


def test_gate_flags_repeated_running_header():
    body = "\n\n".join("<!-- page %d -->\n\nJournal of Testing\n\nBody %d."
                       % (i, i) for i in range(1, 7))
    findings = mdclean.analyze(body)
    assert any(code == "E005" for _s, code, _m in findings)


def test_gate_ignores_prose_repeated_across_pages():
    # The same sentence inside the body is not a running header; only the
    # page boundary lines are candidates. Here every boundary differs.
    body = "\n\n".join(
        "<!-- page %d -->\n\n# Chapter %d\n\nSome prose here. Body text %d is unique."
        % (i, i, i) for i in range(1, 7))
    findings = mdclean.analyze(body)
    assert not any(code == "E005" for _s, code, _m in findings)


def test_gate_flags_identical_boundary_line_regardless_of_prose():
    # A line that really does repeat at every page boundary is a header,
    # even when it reads like prose — that is the definition being detected.
    body = "\n\n".join("<!-- page %d -->\n\nSome prose here.\n\nUnique %d."
                       % (i, i) for i in range(1, 7))
    findings = mdclean.analyze(body)
    assert any(code == "E005" for _s, code, _m in findings)


def test_gate_flags_level_jump():
    findings = mdclean.analyze("# T\n\n#### Jump\n\nBody.\n")
    assert any(code == "E003" for _s, code, _m in findings)


def test_gate_flags_long_chapter():
    body = "word " * 1500
    findings = mdclean.analyze("# T\n\n## Big\n\n" + body + "\n")
    assert any(code == "W001" for _s, code, _m in findings)


def test_gate_flags_missing_chapters():
    findings = mdclean.analyze("# T\n\nOne long body with no sections.\n")
    assert any(code == "W005" for _s, code, _m in findings)


def test_clean_output_passes_gate():
    # The book fixture is a real multi-page document: de-noise must leave it
    # with chapter structure and no hard errors.
    src = _book(6) + "\n## Conclusion\n\nFinal thoughts.\n"
    cleaned = mdclean.clean(src, title="Test Book")
    errors = [(c, m) for s, c, m in mdclean.analyze(cleaned) if s == "E"]
    assert errors == [], "clean() output must not trip hard errors: %s" % errors

def test_emphasis_only_heading_is_dropped():
    """Regression: `## **` survived as a nameless heading with a bare `## `."""
    out = mdclean.clean("# Title\n\nbody text here.\n\n## **\n\nmore body text.\n")
    assert "## **" not in out
    assert "# " in out  # the real H1 survives
    lines = [ln for ln in out.splitlines() if ln.startswith("#")]
    assert lines == ["# Title"], lines


def test_emphasis_only_heading_text_is_empty():
    assert mdclean._clean_heading_text("**") == ""
    assert mdclean._clean_heading_text("___") == ""
