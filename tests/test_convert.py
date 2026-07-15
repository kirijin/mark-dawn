#!/usr/bin/env python3
"""Tests for convert_pdf.py — dispatch logic, OCR, format routing."""
import sys, os, subprocess
from pathlib import Path
from unittest import mock

import pytest

# Disable real paths during tests
os.environ.setdefault("MARK_DAWN_OUT_DIR", "/tmp/md-test-out")
os.environ.setdefault("MARK_DAWN_FAILED_DIR", "/tmp/md-test-failed")

# Pre-populate module-level imports so convert_pdf.py loads without deps
_fake_fitz   = mock.MagicMock()
_fake_pymu   = mock.MagicMock()
_fake_pil    = mock.MagicMock()
sys.modules["fitz"]         = _fake_fitz
sys.modules["pymupdf4llm"]  = _fake_pymu
sys.modules["PIL"]          = _fake_pil
sys.modules["docx_styler"]  = mock.MagicMock()

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import convert_pdf

# Re-bind module references so our mocks behave as the module objects
convert_pdf.fitz        = _fake_fitz
convert_pdf.pymupdf4llm = _fake_pymu


# ---------------------------------------------------------------------------
#  Fixtures
# ---------------------------------------------------------------------------

class _MockPixmap:
    """Minimal stand-in for fitz.Pixmap used by _handle_pdf."""
    def __init__(self, width=1654, height=2339):
        self.width = width
        self.height = height
        self.samples = b"\x00" * (width * height * 3)


class _MockPage:
    """A fitz.Page that returns predictable get_text() and get_pixmap()."""
    def __init__(self, text="", rect_width=595, rect_height=842):
        self._text = text
        self._rect = mock.MagicMock(width=rect_width, height=rect_height)

    def get_text(self):
        return self._text

    def get_pixmap(self, matrix=None):
        return _MockPixmap()

    @property
    def rect(self):
        return self._rect


class _MockDocument:
    """A fitz.Document that holds _MockPage instances."""
    def __init__(self, pages=None):
        self.pages = pages or []
        self.closed = False

    def __len__(self):
        return len(self.pages)

    def __getitem__(self, i):
        return self.pages[i]

    def __iter__(self):
        return iter(self.pages)

    def close(self):
        self.closed = True

    def new_page(self, width=None, height=None):
        p = mock.MagicMock()
        p.insert_image = mock.MagicMock()
        return p

    @staticmethod
    def save(*args, **kwargs):
        pass


@pytest.fixture
def fitz_mocks():
    """Patch convert_pdf.fitz with controllable _MockDocument instances.

    Returns a dict with 'src_doc' (for the input-side call) and 'open_'
    (the patched function) so tests can customise behaviour.
    """
    src_pages = [_MockPage(text="hello " * 50)]  # avg ~250 chars/page → digital
    src_doc = _MockDocument(src_pages)
    out_doc = _MockDocument()  # empty output doc for scanned path

    def _open(path=None):
        return out_doc if path is None else src_doc

    with mock.patch.object(convert_pdf, "fitz") as ftz:
        ftz.Matrix.return_value = mock.MagicMock()
        ftz.open.side_effect = _open
        yield {"src_doc": src_doc, "out_doc": out_doc, "open_": ftz.open}


# ---------------------------------------------------------------------------
#  _ocr_pdf
# ---------------------------------------------------------------------------

class TestOcrPdf:
    """Most-used path: ocrmypdf + pymupdf4llm."""

    def test_calls_ocrmypdf_and_pymupdf4llm(self):
        pdf = Path("/tmp/dummy.pdf")
        out = Path("/tmp/out.md")
        pdf.touch()
        out.parent.mkdir(parents=True, exist_ok=True)

        with (
            mock.patch.object(convert_pdf, "subprocess") as sp,
            mock.patch.object(convert_pdf.pymupdf4llm, "to_markdown",
                              return_value="# Hello") as to_md,
        ):
            sp.run.return_value = mock.MagicMock(returncode=0)
            convert_pdf._ocr_pdf(pdf, out)

            # ocrmypdf called with --skip-text
            ocr_args = sp.run.call_args.args[0]
            assert "--skip-text" in ocr_args
            assert "ocrmypdf" == ocr_args[0]
            # pymupdf4llm called on the ocr output
            assert to_md.called
            # output written
            assert out.read_text() == "# Hello"

            out.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
#  _pdf_text_ratio
# ---------------------------------------------------------------------------

class TestPdfTextRatio:
    def test_digital(self, fitz_mocks):
        fitz_mocks["src_doc"].pages = [_MockPage(text="A" * 300)]
        avg, n = convert_pdf._pdf_text_ratio(Path("/tmp/dummy.pdf"))
        assert avg > 100
        assert n == 1

    def test_scanned(self, fitz_mocks):
        fitz_mocks["src_doc"].pages = [_MockPage(text="")]
        avg, n = convert_pdf._pdf_text_ratio(Path("/tmp/dummy.pdf"))
        assert avg == 0
        assert n == 1

    def test_empty_doc(self, fitz_mocks):
        fitz_mocks["src_doc"].pages = []
        avg, n = convert_pdf._pdf_text_ratio(Path("/tmp/dummy.pdf"))
        assert avg == 0
        assert n == 0


# ---------------------------------------------------------------------------
#  _handle_pdf  — dispatch to digital vs scanned vs empty
# ---------------------------------------------------------------------------

class TestHandlePdf:

    def test_digital_path(self, fitz_mocks):
        """avg > 100 → pymupdf4llm.to_markdown directly."""
        fitz_mocks["src_doc"].pages = [_MockPage(text="hello " * 100)]
        out = Path("/tmp/md-test-out/digital_readme.md")

        with mock.patch.object(convert_pdf.pymupdf4llm, "to_markdown",
                                return_value="# Digital") as to_md:
            convert_pdf._handle_pdf(Path("/tmp/dummy.pdf"), out)

            assert to_md.called
            assert out.read_text() == "# Digital"
            out.unlink(missing_ok=True)

    def test_scanned_path(self, fitz_mocks):
        """avg <= 100 → render pages, call ocrmypdf."""
        fitz_mocks["src_doc"].pages = [
            _MockPage(text=""),
            _MockPage(text=""),
        ]
        # Rendering produces 2 pages
        out_doc = _MockDocument([mock.MagicMock(), mock.MagicMock()])
        fitz_mocks["open_"].side_effect = lambda path=None: out_doc if path is None else fitz_mocks["src_doc"]

        out = Path("/tmp/md-test-out/scanned_out.md")
        ocr_md_path = Path("/tmp/md-test-out/scanned_out.md")

        with (
            mock.patch.object(convert_pdf, "_ocr_pdf") as ocr,
            mock.patch.object(convert_pdf, "tempfile") as tf,
        ):
            tf.NamedTemporaryFile.return_value.__enter__.return_value.name = "/tmp/_rendered.pdf"
            convert_pdf._handle_pdf(Path("/tmp/dummy.pdf"), out)

        # _ocr_pdf called with temp rendered PDF
        assert ocr.called
        assert str(ocr.call_args.args[0]).endswith("_rendered.pdf") or ocr.call_args.args[0] == Path("/tmp/_rendered.pdf")

    def test_scanned_zero_pages(self, fitz_mocks):
        """rendered == 0 → _ocr_pdf called with original path (no rendering)."""
        fitz_mocks["src_doc"].pages = []  # n = 0 → loop never runs → out_doc empty
        out = Path("/tmp/md-test-out/empty.md")

        with (
            mock.patch.object(convert_pdf, "_ocr_pdf") as ocr,
            mock.patch.object(convert_pdf, "tempfile"),
        ):
            convert_pdf._handle_pdf(Path("/tmp/dummy.pdf"), out)

        # _ocr_pdf called with original file_path, not a temp
        assert ocr.called
        assert str(ocr.call_args.args[0]) == "/tmp/dummy.pdf"


# ---------------------------------------------------------------------------
#  _handle_djvu
# ---------------------------------------------------------------------------

class TestHandleDjVu:

    def test_native_text(self):
        """djvutxt produces text → written as md."""
        out = Path("/tmp/md-test-out/djvu_native.md")
        with (
            mock.patch.object(convert_pdf.shutil, "which", return_value="/usr/bin/djvutxt"),
            mock.patch.object(convert_pdf.subprocess, "run") as run,
        ):
            run.return_value = mock.MagicMock(returncode=0, stdout="Native text\n")
            convert_pdf._handle_djvu(Path("/tmp/doc.djvu"), out)

        assert out.read_text() == "Native text\n"
        out.unlink(missing_ok=True)

    def test_ddjvu_render(self):
        """djvutxt available but empty → falls through to ddjvu."""
        out = Path("/tmp/md-test-out/djvu_render.md")
        with (
            mock.patch.object(convert_pdf.shutil, "which",
                              side_effect=lambda x: f"/usr/bin/{x}"),
            mock.patch.object(convert_pdf, "subprocess") as sp,
            mock.patch.object(convert_pdf, "PImage") as pil,
            mock.patch.object(convert_pdf, "_ocr_pdf") as ocr,
            mock.patch.object(convert_pdf.Path, "exists", return_value=True),
            mock.patch.object(convert_pdf.Path, "unlink", return_value=None),
        ):
            sp.run.side_effect = [
                mock.MagicMock(returncode=0, stdout=""),       # djvutxt (empty)
                mock.MagicMock(returncode=0, stdout="1"),       # --pagecount
                mock.MagicMock(returncode=0, stdout=""),         # ddjvu
            ]
            pil_img = mock.MagicMock()
            pil_img.size = (800, 1000)
            pil.open.return_value = pil_img

            convert_pdf._handle_djvu(Path("/tmp/doc.djvu"), out)

        # Should have called ddjvu and then _ocr_pdf
        ddjvu_call = sp.run.call_args_list[2].args[0]
        assert "ddjvu" in ddjvu_call[0]
        assert ocr.called

    def test_no_tools_exits(self):
        """Neither djvutxt nor ddjvu → sys.exit(1)."""
        out = Path("/tmp/md-test-out/djvu_notools.md")
        with (
            mock.patch.object(convert_pdf.shutil, "which", return_value=None),
            pytest.raises(SystemExit) as exc,
        ):
            convert_pdf._handle_djvu(Path("/tmp/doc.djvu"), out)
        assert exc.value.code == 1


# ---------------------------------------------------------------------------
#  _handle_image
# ---------------------------------------------------------------------------

class TestHandleImage:

    def test_creates_pdf_and_ocrs(self):
        out = Path("/tmp/md-test-out/img_out.md")
        with (
            mock.patch.object(convert_pdf, "PImage") as pil,
            mock.patch.object(convert_pdf, "_ocr_pdf") as ocr,
            mock.patch.object(convert_pdf, "tempfile") as tf,
        ):
            tf.NamedTemporaryFile.return_value.__enter__.return_value.name = "/tmp/_img.pdf"
            pil.open.return_value.convert.return_value = pil.open.return_value
            convert_pdf._handle_image(Path("/tmp/photo.jpg"), out)

        assert ocr.called
        assert str(ocr.call_args.args[0]) == "/tmp/_img.pdf"


# ---------------------------------------------------------------------------
#  _handle_doc  (markitdown)
# ---------------------------------------------------------------------------

class TestHandleDoc:

    def test_success(self):
        out = Path("/tmp/md-test-out/doc_out.md")
        with mock.patch.object(convert_pdf.subprocess, "run") as run:
            run.return_value = mock.MagicMock(returncode=0, stdout="# Converted\n")
            convert_pdf._handle_doc(Path("/tmp/report.docx"), out)

        assert out.read_text() == "# Converted\n"
        out.unlink(missing_ok=True)

    def test_failure_exits(self):
        out = Path("/tmp/md-test-out/doc_fail.md")
        with (
            mock.patch.object(convert_pdf.subprocess, "run") as run,
            pytest.raises(SystemExit) as exc,
        ):
            run.return_value = mock.MagicMock(returncode=1, stdout="")
            convert_pdf._handle_doc(Path("/tmp/broken.docx"), out)

        assert exc.value.code == 1


# ---------------------------------------------------------------------------
#  main() — dispatch routing, --docx, errors
# ---------------------------------------------------------------------------

class TestMain:

    _tests_dir = Path("/tmp/md-test-main")

    @classmethod
    def setup_class(cls):
        cls._tests_dir.mkdir(parents=True, exist_ok=True)
        for ext in [".pdf", ".djvu", ".jpg", ".png", ".tiff", ".webp",
                    ".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"]:
            (cls._tests_dir / f"doc{ext}").touch()

    @mock.patch.object(convert_pdf, "_handle_pdf")
    def test_routes_pdf(self, h):
        with (
            mock.patch.object(sys, "argv",
                               ["convert_pdf.py", str(self._tests_dir / "doc.pdf")]),
            pytest.raises(SystemExit),
        ):
            convert_pdf.main()
        assert h.called

    @mock.patch.object(convert_pdf, "_handle_djvu")
    def test_routes_djvu(self, h):
        with (
            mock.patch.object(sys, "argv",
                               ["convert_pdf.py", str(self._tests_dir / "doc.djvu")]),
            pytest.raises(SystemExit),
        ):
            convert_pdf.main()
        assert h.called

    @mock.patch.object(convert_pdf, "_handle_image")
    def test_routes_image(self, h):
        for ext in [".jpg", ".png", ".tiff", ".webp"]:
            h.reset_mock()
            with (
                mock.patch.object(sys, "argv",
                                   ["convert_pdf.py",
                                    str(self._tests_dir / f"doc{ext}")]),
                pytest.raises(SystemExit),
            ):
                convert_pdf.main()
            assert h.called, f"{ext} not routed to _handle_image"

    @mock.patch.object(convert_pdf, "_handle_doc")
    def test_routes_doc(self, h):
        for ext in [".docx", ".xlsx", ".pptx", ".html", ".csv", ".rtf"]:
            h.reset_mock()
            with (
                mock.patch.object(sys, "argv",
                                   ["convert_pdf.py",
                                    str(self._tests_dir / f"doc{ext}")]),
                pytest.raises(SystemExit),
            ):
                convert_pdf.main()
            assert h.called, f"{ext} not routed to _handle_doc"

    def test_unsupported_format_exits(self):
        with (
            mock.patch.object(sys, "argv", ["convert_pdf.py", "/tmp/foo.bar"]),
            pytest.raises(SystemExit) as exc,
        ):
            convert_pdf.main()
        assert exc.value.code == 1

    def test_file_not_found_exits(self):
        with (
            mock.patch.object(sys, "argv", ["convert_pdf.py", "/tmp/nonexistent.pdf"]),
            pytest.raises(SystemExit) as exc,
        ):
            convert_pdf.main()
        assert exc.value.code == 1

    @mock.patch.object(convert_pdf, "_handle_pdf")
    @mock.patch.object(convert_pdf, "_md_to_docx")
    def test_docx_flag(self, md2d, h):
        with (
            mock.patch.object(sys, "argv",
                               [f"convert_pdf.py",
                                str(self._tests_dir / "doc.pdf"), "--docx"]),
            pytest.raises(SystemExit),
        ):
            convert_pdf.main()
        assert h.called
        assert md2d.called

    @mock.patch.object(convert_pdf, "_handle_pdf")
    def test_timeout_exits(self, h):
        h.side_effect = subprocess.TimeoutExpired(cmd="ocrmypdf", timeout=10)
        with (
            mock.patch.object(sys, "argv", ["convert_pdf.py", "/tmp/doc.pdf"]),
            pytest.raises(SystemExit) as exc,
        ):
            convert_pdf.main()
        assert exc.value.code == 1
