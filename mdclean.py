#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""mdclean — enforce Markdown readability rules on mark-dawn output.

Pure stdlib, deterministic, no model. Runs inside convert_pdf.py before the
atomic write, and standalone as a gate:

    python3 mdclean.py FILE.md --check      # exit 1 on hard errors
    python3 mdclean.py FILE.md -o OUT.md    # write cleaned copy
    python3 mdclean.py FILE.md              # cleaned text to stdout

Stages, in order:

  1. page split      — recover page structure from OCR markers / PDF breaks
  2. de-noise        — strip running headers, footers, page numbers
  3. page markers    — `## Page N` -> `<!-- page N -->` (out of heading tree)
  4. paragraphs      — join hard-wrapped lines into semantic one-line paragraphs
  5. headings        — one H1, no level jumps, no noise headings, synthesize
  6. tables          — pad/truncate GFM rows, guarantee a separator row
  7. frontmatter     — title/source/pages/ocr, when metadata is supplied

Finding codes emitted by analyze():

  E001  no H1
  E003  heading level jump (auto-raised)
  E004  page marker / caption left in heading position (auto-demoted)
  E005  repeated running header / footer survived the strip
  E006  inline emphasis stripped from heading text
  W001  chapter longer than max_chapter
  W002  paragraph longer than max_para
  W003  ragged table row
  W004  first paragraph after the H1 is a table or blockquote
  W005  no chapter structure — downstream splitter must fall back to size
  W006  fenced block without a language hint
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path

__all__ = ["clean", "analyze", "split_pages", "render_frontmatter", "main"]

# ---------------------------------------------------------------------------
# Patterns
# ---------------------------------------------------------------------------

# OCR path emits "## Page 12"; pymupdf4llm emits "-----" between pages.
PAGE_MARK = re.compile(r"^##[ \t]*Page[ \t]+(\d+)[ \t]*$", re.M)
# Our own injected provenance (pymupdf4llm page_chunks path).
PAGE_COMMENT = re.compile(r"^<!--[ \t]*page[ \t]+(\d+)[ \t]*-->[ \t]*$", re.M)
PDF_BREAK = re.compile(r"^-{3,5}[ \t]*$", re.M)

HEADING = re.compile(r"^(#{1,6})[ \t]+(\S.*?)[ \t]*#*[ \t]*$")
H1 = re.compile(r"^#[ \t]+\S")

# Headings that are really captions or conversion debris.
NOISE_HEADING = re.compile(
    r"^#{1,6}[ \t]*(?:"
    r"page[ \t]*\d+"
    r"|figure[ \t]*\d+|fig\.?[ \t]*\d+|plate[ \t]*\d+"
    r"|table[ \t]*\d+"
    r"|изображение|рисунок|рис\.?[ \t]*\d+|таблица"
    r")\b",
    re.I,
)

# A bare number, optionally dash-wrapped: a page number, not content.
PAGE_NUM = re.compile(r"^[ \t]*(?:[-–—]{1,2}[ \t]*)?\d{1,4}[ \t]*(?:[-–—]{1,2})?[ \t]*$")

FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*(\S*)")
LIST_ITEM = re.compile(r"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\S")
QUOTE = re.compile(r"^[ \t]*>")
TABLE_ROW = re.compile(r"^[ \t]*\|")
HTML_COMMENT = re.compile(r"^[ \t]*<!--")
HR = re.compile(r"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$")

# Text that ends a sentence; kept for reference by callers that need it.
HARD_END = ".!?…;:"
CLOSERS = "\"'”’»)]}"

# Strong chapter openers — used only when the document has no headings at all.
CHAPTER_OPENER = re.compile(
    r"^(?:"
    r"chapter|chap\.?|part|book|section|appendix"
    r"[ \t]+[0-9]+[a-z]?(?:[.:—–-][ \t]|\b)"
    r"|chapter[ \t]+[ivxlcdm]+\b"
    r"|глава[ \t]+\d+"
    r"|часть[ \t]+\d+"
    r"|第[0-9一二三四五六七八九十百零〇]+[章节篇部卷]"
    r"|\d{1,2}[.)][ \t]+\S"
    r"|[ivxlcdm]{1,6}[.)][ \t]+\S"
    r")",
    re.I,
)

# A caption line ("Figure 1 ...", "Table 2: ...", "Рисунок 3 ..."). Kept as
# its own block even when the source PDF gives it no blank line above.
CAPTION = re.compile(
    r"^(?:figure|fig\.?|table|plate|exhibit|scheme|chart|graph"
    r"|рисунок|рис\.?|таблица|схема|график|диаграмма)"
    r"[ \t]*\d+\b",
    re.I,
)

# Documents shorter than this are not worth running structure repair on.
MIN_PAGE_COUNT_FOR_HEADERS = 3
REPEAT_RATIO = 0.6

# Below this many characters, a document is a fragment, not a work: giving it
# a synthesized H1 invents structure that was never there. Filename-derived
# titles are only trustworthy for substantial documents.
MIN_SYNTH_CHARS = 600


# ---------------------------------------------------------------------------
# Page structure
# ---------------------------------------------------------------------------

def split_pages(text: str):
    """Return [(page_number_or_None, body_text), ...].

    Recognises every shape the pipeline produces: OCR's `## Page N` markers,
    our own `<!-- page N -->` provenance (injected by the page_chunks path),
    and pymupdf4llm's `-----` page separators. Anything else is a single
    unlabeled page.
    """
    match = PAGE_MARK.search(text) or PAGE_COMMENT.search(text)
    pattern = PAGE_MARK if PAGE_MARK.search(text) else PAGE_COMMENT
    if match:
        parts = pattern.split(text)
        pages = []
        head = parts[0].strip()
        if head:
            pages.append((None, head))
        for i in range(1, len(parts) - 1, 2):
            pages.append((int(parts[i]), parts[i + 1]))
        return pages
    if PDF_BREAK.search(text):
        return [(None, chunk) for chunk in PDF_BREAK.split(text)]
    return [(None, text)]


def _page_lines(body: str):
    return [ln.rstrip() for ln in body.splitlines()]


def _body_lines(lines):
    """Drop leading/trailing blanks so boundary detection is stable."""
    start, end = 0, len(lines)
    while start < end and not lines[start].strip():
        start += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    return lines[start:end]


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip()).lower()


def _page_key(s: str) -> str:
    """Boundary-line key, with folio digits neutralised.

    A footer like "1 Vol. 12, No. 3" differs per page only in its page
    number, so the key must collapse digits or repetition detection never
    fires. Collapsing digits *everywhere* is wrong: it would equate
    "Paragraph 1 continues" with "Paragraph 2 continues". So digits are
    neutralised only when the line is folio-shaped — a number at its start
    or at its end.
    """
    norm = _norm(s)
    stripped = norm.rstrip(".,;:)]}\"'")
    starts_folio = bool(re.match(r"^\d{1,4}\b", norm))
    ends_folio = bool(re.search(r"\b\d{1,4}$", stripped))
    if not (starts_folio or ends_folio):
        return norm
    return re.sub(r"\b\d{1,4}\b", "#", norm)


# ---------------------------------------------------------------------------
# 2. de-noise
# ---------------------------------------------------------------------------

def _repeated_boundary_lines(pages):
    """Lines that appear at the same page boundary on most pages.

    Returns (header_texts, footer_texts) as normalized strings. Only fires
    when there are enough pages to establish a pattern — a 2-page scan with a
    coincidental match is not a running header.
    """
    total = len(pages)
    if total < MIN_PAGE_COUNT_FOR_HEADERS:
        return set(), set()

    def tally(which):
        counts = {}
        for _num, body in pages:
            # Folio lines are dropped before tallying, otherwise the page
            # number is picked as the footer and the real footer survives.
            lines = _body_lines(_strip_page_numbers(_page_lines(body)))
            if not lines:
                continue
            seen = set()
            for candidate in ([lines[0]] if which == "head" else [lines[-1]]):
                if len(candidate) > 120 or HEADING.match(candidate):
                    continue
                seen.add(_page_key(candidate))
            for key in seen:
                counts[key] = counts.get(key, 0) + 1
        return {k for k, v in counts.items() if v / total >= REPEAT_RATIO and k}

    return tally("head"), tally("tail")


def _strip_repeated(lines, headers, footers):
    out = []
    for ln in lines:
        key = _page_key(ln)
        if key and (key in headers or key in footers):
            continue
        out.append(ln)
    return out


def _strip_page_numbers(lines):
    return [ln for ln in lines if not PAGE_NUM.match(ln)]


# ---------------------------------------------------------------------------
# 4. paragraphs
# ---------------------------------------------------------------------------

def _is_wrappable(ln: str) -> bool:
    """True for a line that can take part in a paragraph join."""
    s = ln.strip()
    if not s:
        return False
    if HEADING.match(ln) or LIST_ITEM.match(ln) or QUOTE.match(ln):
        return False
    if TABLE_ROW.match(ln) or HTML_COMMENT.match(ln) or HR.match(ln):
        return False
    if FENCE.match(ln):
        return False
    return True


def _ends_sentence(s: str) -> bool:
    """True when a line ends a sentence and must not be joined forward.

    The conservative reading is correct here: a false positive splits a
    paragraph (cheap, still readable), a false negative fuses two paragraphs
    (expensive, destroys structure). So only a terminator followed by
    whitespace-then-capital, or a closing quote after a terminator, counts.
    """
    s = s.rstrip()
    if not s:
        return True
    if s[-1] in HARD_END:
        return True
    if s[-1] in CLOSERS and len(s) > 1 and s[-2] in HARD_END:
        return True
    return False


def _join_paragraphs(lines):
    """Join hard-wrapped lines into one line per paragraph.

    The blank line is the paragraph delimiter — not the sentence terminator.
    That distinction matters: real PDFs wrap mid-paragraph and put a full stop
    on interior lines, so breaking on '.' would shatter paragraphs that were
    never broken. pymupdf4llm and OCR both preserve blank lines between blocks,
    so the blank line is the only signal that is actually reliable.
    """
    out = []
    buffer = None
    in_fence = False

    def flush():
        nonlocal buffer
        if buffer is not None:
            out.append(buffer)
            buffer = None

    for ln in lines:
        if FENCE.match(ln):
            flush()
            in_fence = not in_fence
            out.append(ln)
            continue
        if in_fence:
            out.append(ln)
            continue
        if not ln.strip():
            flush()
            out.append("")
            continue
        if not _is_wrappable(ln):
            flush()
            out.append(ln)
            continue
        stripped = ln.strip()
        # A caption starts its own block even when the source gave it no
        # blank line above — fusing "Figure 3 ..." into body prose is the
        # single most common structure loss in generated markdown.
        if CAPTION.match(stripped):
            flush()
            out.append("")
            out.append(stripped)
            out.append("")
            continue
        buffer = stripped if buffer is None else buffer + " " + stripped
    flush()
    return out


# ---------------------------------------------------------------------------
# 5. headings
# ---------------------------------------------------------------------------

def _synthesize_headings(lines, title):
    """Give a headingless document a skeleton.

    Strong chapter openers are promoted only when the document has zero
    headings — that is the one case where text-only detection is safe enough.
    """
    out = []
    for ln in lines:
        m = HEADING.match(ln)
        if m:
            out.append(ln)
            continue
        s = ln.strip()
        if s and len(s) <= 90 and CHAPTER_OPENER.match(s):
            if out and out[-1].strip():
                out.append("")
            out.append("## " + s)
            out.append("")
            continue
        out.append(ln)
    return out


def _clean_heading_text(text: str) -> str:
    """Strip inline emphasis and trailing hashes from heading text.

    pymupdf4llm marks headings bold ("# **Method**"); the markers are
    conversion noise — a heading is already emphasised by its level.
    Returns '' when the heading is made only of markers.
    """
    text = text.strip()
    prev = None
    while prev != text:
        prev = text
        text = re.sub(r"\*\*(.+?)\*\*", r"\1", text, flags=re.S).strip()
    # Leftover unbalanced marker runs ("**", "__", "*") are not a title.
    text = re.sub(r"(?<!\w)__(.+?)__(?!\w)", r"\1", text)
    text = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"\1", text)
    text = re.sub(r"(?<!\w)_(?!_)(.+?)(?<!_)_(?!\w)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = text.strip()
    if text and set(text) <= set("*_`~ \t"):
        return ""
    return text


def _normalize_headings(lines, title):
    """No caption headings, no level jumps, one H1 minimum.

    Multiple H1s are legitimate and preserved: a book's chapters are peers,
    and the downstream splitter keys on H1 boundaries. Only a document with
    zero H1s gets one synthesized.

    Returns (lines, fixed_codes).
    """
    fixed = set()

    # Caption / debris headings -> plain italic paragraph.
    kept = []
    for ln in lines:
        if NOISE_HEADING.match(ln):
            m = HEADING.match(ln)
            label = _clean_heading_text(m.group(2)) if m else ln.lstrip("#").strip()
            kept.append("*%s*" % label)
            fixed.add("E004")
            continue
        m = HEADING.match(ln)
        if m:
            level = len(m.group(1))
            cleaned = _clean_heading_text(m.group(2))
            if not cleaned:
                # A heading made only of markers carries no title. Emitting
                # it would produce a bare "## " and a nameless section.
                kept.append("")
                fixed.add("E006")
                continue
            if cleaned != m.group(2):
                ln = "#" * level + " " + cleaned
                fixed.add("E006")
        kept.append(ln)
    lines = kept

    # No H1 at all -> synthesize one, but only for a document substantial
    # enough to be a work. A one-line fragment gets no invented title.
    if not any(H1.match(ln) for ln in lines):
        body_text = "\n".join(ln for ln in lines if not HTML_COMMENT.match(ln))
        if len(body_text.strip()) >= MIN_SYNTH_CHARS:
            head = (title or "").strip()
            if not head:
                for ln in lines:
                    if ln.strip() and not HTML_COMMENT.match(ln):
                        head = ln.strip().lstrip("#").strip()
                        break
            if head:
                lines = ["# " + head, ""] + lines
                fixed.add("E001")

    # Raise level jumps: H1 -> H3 is a jump, H2 -> H4 is a jump.
    prev = 0
    for i, ln in enumerate(lines):
        m = HEADING.match(ln)
        if not m:
            continue
        level = len(m.group(1))
        if prev and level > prev + 1:
            lines[i] = "#" * (prev + 1) + " " + ln[level:].lstrip()
            level = prev + 1
            fixed.add("E003")
        prev = level

    return lines, fixed


# ---------------------------------------------------------------------------
# 6. tables
# ---------------------------------------------------------------------------

def _cells(row: str):
    s = row.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip() for c in s.split("|")]


def _render_row(cells):
    return "| " + " | ".join(cells) + " |"


def _normalize_tables(lines):
    out = []
    i = 0
    n = len(lines)
    while i < n:
        if not TABLE_ROW.match(lines[i]):
            out.append(lines[i])
            i += 1
            continue
        block = []
        while i < n and TABLE_ROW.match(lines[i]):
            block.append(lines[i])
            i += 1
        if len(block) < 2:
            out.extend(block)
            continue
        rows = [_cells(r) for r in block]
        width = max(len(r) for r in rows)
        width = max(width, len(rows[0]))
        rows = [r + [""] * (width - len(r)) for r in rows]
        sep = ["---"] * width
        if len(rows) > 1 and not all(set(c) <= set("-: ") for c in rows[1]):
            rows.insert(1, sep)
        elif len(rows) > 1:
            rows[1] = sep
        out.extend(_render_row(r) for r in rows)
    return out


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

def _italicize_captions(lines):
    """Mark standalone caption lines with emphasis.

    A caption is a short line that names a figure or table and is not already
    formatted. Emphasis keeps it out of the prose flow for a reader and makes
    it visibly distinct from body text.
    """
    out = []
    for ln in lines:
        s = ln.strip()
        if (CAPTION.match(s) and len(s) <= 300
                and not s.startswith(("*", "_", "|", ">", "!", "`"))
                and not HEADING.match(ln)):
            out.append("*%s*" % s)
            continue
        out.append(ln)
    return out


def clean(text: str, *, ocr: bool = False, meta=None, title=None,
          join_lines: bool = True, normalize_tables: bool = True) -> str:
    """Normalize converted Markdown for downstream navigation and RAG."""
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    # Already-processed input: strip the frontmatter before re-normalizing, so
    # a second pass does not eat the YAML block and turn its `---` fences into
    # prose. `meta` re-supplies it, or the original is preserved verbatim.
    existing_fm = None
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            existing_fm = text[4:end]
            text = text[end + 5:]

    # De-hyphenate words broken across a line end, before anything else.
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)

    pages = split_pages(text)
    multi = len(pages) > 1

    headers, footers = _repeated_boundary_lines(pages)
    cleaned_pages = []
    for _num, body in pages:
        lines = _page_lines(body)
        if multi:
            # Folio removal is only meaningful when the input actually has
            # page structure. On a single-page document a bare numeric line
            # ("42", a year, a data value) is content, not a page number.
            lines = _strip_page_numbers(lines)
        lines = _strip_repeated(lines, headers, footers)
        cleaned_pages.append(lines)

    if multi:
        # Rebuild with page provenance kept as an HTML comment: invisible to
        # heading parsers, readable to a human auditor.
        chunks = []
        for (num, _body), lines in zip(pages, cleaned_pages):
            marker = "<!-- page %s -->" % num if num else None
            body = "\n".join(lines).strip()
            chunks.append((marker + "\n\n" + body).strip() if marker else body)
        text = "\n\n".join(chunks)
    else:
        text = "\n".join(cleaned_pages[0])

    lines = text.splitlines()

    if join_lines:
        lines = _join_paragraphs(lines)

    if not any(HEADING.match(ln) for ln in lines):
        lines = _synthesize_headings(lines, title)

    lines, _fixed = _normalize_headings(lines, title)

    if normalize_tables:
        lines = _normalize_tables(lines)

    lines = _italicize_captions(lines)

    body = "\n".join(lines)
    body = re.sub(r"\n{3,}", "\n\n", body).strip()
    # An empty document stays empty. Appending a newline unconditionally made
    # clean() non-idempotent on empty and whitespace-only input.
    if body:
        body += "\n"

    if meta is not None:
        body = render_frontmatter(meta) + "\n" + body
    elif existing_fm is not None:
        # Preserve the original block verbatim rather than regenerating it.
        body = "---\n" + existing_fm + "\n---\n" + body
    return body


def render_frontmatter(meta) -> str:
    """Minimal YAML frontmatter. Values are quoted only when needed."""
    if not meta:
        return ""
    order = ["title", "source", "pages", "ocr", "converted"]
    keys = [k for k in order if k in meta] + [k for k in meta if k not in order]
    out = ["---"]
    for key in keys:
        value = meta[key]
        if isinstance(value, bool):
            out.append("%s: %s" % (key, "true" if value else "false"))
        elif isinstance(value, (int, float)):
            out.append("%s: %s" % (key, value))
        else:
            text = str(value)
            needs_quote = text != text.strip() or any(c in text for c in ":#\"'\n")
            out.append('%s: "%s"' % (key, text.replace('"', '\\"'))
                       if needs_quote else "%s: %s" % (key, text))
    out.append("---")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# gate
# ---------------------------------------------------------------------------

def analyze(text: str, *, max_chapter: int = 5000, max_para: int = 1200):
    """Return [(severity, code, message), ...] for already-cleaned Markdown."""
    found = []
    lines = text.splitlines()

    h1s = [i for i, ln in enumerate(lines, 1) if H1.match(ln)]
    # A short document legitimately has no H1 — a heading is only expected
    # where one was synthesizable. Reporting E001 for a fragment would make
    # the gate noisy on exactly the inputs that are already fine.
    if not h1s and len(text.strip()) >= MIN_SYNTH_CHARS:
        found.append(("E", "E001", "no H1 heading"))

    prev = 0
    for i, ln in enumerate(lines, 1):
        m = HEADING.match(ln)
        if not m:
            continue
        level = len(m.group(1))
        if prev and level > prev + 1:
            found.append(("E", "E003", "heading level jump H%d -> H%d at line %d"
                          % (prev, level, i)))
        prev = level

    for i, ln in enumerate(lines, 1):
        if re.match(r"^#{1,6}[ \t]*page[ \t]*\d+", ln, re.I):
            found.append(("E", "E004", "page marker in heading position, line %d" % i))
        elif NOISE_HEADING.match(ln):
            found.append(("E", "E004", "caption heading, line %d: %r"
                          % (i, ln.strip()[:50])))

    # Running headers that survived: a short line repeated on many pages.
    # Count per page so a phrase that recurs inside prose is not mistaken for
    # a running header.
    page_count = max(1, len(re.findall(r"^<!--[ \t]*page[ \t]*\d+", text, re.M)))
    if page_count >= MIN_PAGE_COUNT_FOR_HEADERS:
        seen = {}
        for chunk in re.split(r"^<!--[ \t]*page[ \t]*\d+[^>]*-->[ \t]*$",
                              text, flags=re.M):
            lines_in_chunk = [ln.strip() for ln in chunk.splitlines() if ln.strip()]
            if not lines_in_chunk:
                continue
            for candidate in (lines_in_chunk[0], lines_in_chunk[-1]):
                if len(candidate) > 120 or HEADING.match(candidate):
                    continue
                key = _page_key(candidate)
                seen[key] = seen.get(key, 0) + 1
        for key, count in seen.items():
            if key and count / page_count >= REPEAT_RATIO and count >= 3:
                found.append(("E", "E005", "repeated page boundary line survived: %r"
                              % key[:60]))

    in_fence = False
    fence_plain_at = None
    for i, ln in enumerate(lines, 1):
        m = FENCE.match(ln)
        if not m:
            continue
        if not in_fence:
            in_fence = True
            fence_plain_at = None if m.group(2) else i
        else:
            in_fence = False
            if fence_plain_at:
                found.append(("W", "W006", "fence without language, line %d" % fence_plain_at))

    # Chapter sizes, split on H2.
    chapter, start = None, 0
    for i, ln in enumerate(lines, 1):
        m = re.match(r"^##[ \t]+(\S)", ln)
        if m:
            if chapter is not None:
                size = len("\n".join(lines[start:i - 1]))
                if size > max_chapter:
                    found.append(("W", "W001", "chapter %r is %d chars (line %d)"
                                  % (chapter[:40], size, start)))
            chapter, start = ln[3:].strip(), i
    if chapter is not None:
        size = len("\n".join(lines[start:]))
        if size > max_chapter:
            found.append(("W", "W001", "chapter %r is %d chars (line %d)"
                          % (chapter[:40], size, start)))

    for i, ln in enumerate(lines, 1):
        if len(ln) > max_para and not TABLE_ROW.match(ln) and not FENCE.match(ln):
            found.append(("W", "W002", "paragraph of %d chars at line %d" % (len(ln), i)))

    for i, ln in enumerate(lines, 1):
        if TABLE_ROW.match(ln) and ln.count("|") and not ln.rstrip().endswith("|"):
            found.append(("W", "W003", "table row not closed, line %d" % i))

    if h1s:
        first = h1s[0]
        for ln in lines[first:first + 4]:
            if TABLE_ROW.match(ln):
                found.append(("W", "W004", "first block after H1 is a table"))
                break
            if QUOTE.match(ln):
                found.append(("W", "W004", "first block after H1 is a blockquote"))
                break

    # Chapter structure = something to split on. The downstream splitter uses
    # H1 when there are at least two, else H2 — so either count qualifies.
    if len(h1s) < 2 and not re.search(r"^##[ \t]+\S", text, re.M):
        found.append(("W", "W005", "no chapter structure; splitter must fall back to size"))

    return found


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Normalize/gate Markdown for navigation.")
    ap.add_argument("file")
    ap.add_argument("-o", "--output")
    ap.add_argument("--check", action="store_true",
                    help="report findings; exit 1 on any hard error")
    ap.add_argument("--no-join", action="store_true", help="keep hard line wraps")
    ap.add_argument("--title", default=None)
    args = ap.parse_args(argv)

    path = Path(args.file)
    text = path.read_text(encoding="utf-8")
    cleaned = clean(text, title=args.title, join_lines=not args.no_join)

    if args.check:
        findings = analyze(cleaned)
        for severity, code, msg in findings:
            print("%s %s: %s" % (severity, code, msg), file=sys.stderr)
        errors = sum(1 for s, _c, _m in findings if s == "E")
        print("%d error(s), %d warning(s)" % (errors, len(findings) - errors),
              file=sys.stderr)
        return 1 if errors else 0

    if args.output:
        Path(args.output).write_text(cleaned, encoding="utf-8")
    else:
        sys.stdout.write(cleaned)
    return 0


if __name__ == "__main__":
    sys.exit(main())