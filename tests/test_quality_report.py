#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Tests for the watcher's structure-quality sidecar.

watcher.py imports watchdog at module load. Rather than stubbing it at module
scope — which would leak into test_watcher.py and break its state-file tests —
these tests reuse the real module when it imports, and skip otherwise. The
sidecar logic itself never touches the filesystem watcher.
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


@pytest.fixture(scope="module")
def watcher():
    """The real watcher module, or skip when its dependency is absent."""
    try:
        import watchdog  # noqa: F401
    except ImportError:
        pytest.skip("watchdog not installed")
    import watcher as watcher_mod
    return watcher_mod


def test_sidecar_written_for_clean_file(watcher, tmp_path):
    out = tmp_path / "doc.md"
    out.write_text("# Title\n\n## Section\n\nBody text.\n", encoding="utf-8")

    errors = watcher._quality_report(out)

    qc = tmp_path / "doc.md.qc.json"
    assert qc.is_file(), "quality sidecar must be written"
    payload = json.loads(qc.read_text(encoding="utf-8"))
    assert payload["file"] == "doc.md"
    assert payload["errors"] == 0
    assert errors == 0


def test_sidecar_reports_structure_errors(watcher, tmp_path):
    out = tmp_path / "bad.md"
    out.write_text("## Page 4\n\nBody.\n", encoding="utf-8")

    errors = watcher._quality_report(out)

    payload = json.loads((tmp_path / "bad.md.qc.json").read_text(encoding="utf-8"))
    codes = [f["code"] for f in payload["findings"]]
    assert "E004" in codes
    assert errors == payload["errors"] > 0


def test_sidecar_never_raises_on_missing_file(watcher, tmp_path):
    assert watcher._quality_report(tmp_path / "absent.md") is None