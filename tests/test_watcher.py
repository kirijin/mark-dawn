#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Tests for watcher.py — debounce queue, 2docx routing, retry, failed moves."""
import os, sys, time, json, shutil
from pathlib import Path
from unittest import mock
import pytest

# Fake watchdog before import (not installed in CI/test envs)
sys.modules["watchdog"] = mock.MagicMock()
sys.modules["watchdog.observers"] = mock.MagicMock()
sys.modules["watchdog.events"] = mock.MagicMock()

_tmp = Path("/tmp/md-watcher-test")
os.environ["MARK_DAWN_INBOX_DIR"] = str(_tmp / "Inbox")
os.environ["MARK_DAWN_OUT_DIR"] = str(_tmp / "Research")
os.environ["MARK_DAWN_FAILED_DIR"] = str(_tmp / "Failed")
os.environ["MARK_DAWN_STATE_FILE"] = str(_tmp / "state.json")
os.environ.pop("MARK_DAWN_PID", None)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import watcher


@pytest.fixture(autouse=True)
def clean_state():
    watcher._pending = {}
    watcher._state["last"] = []
    shutil.rmtree(_tmp, ignore_errors=True)
    _tmp.mkdir(parents=True, exist_ok=True)
    watcher.INBOX.mkdir(parents=True, exist_ok=True)
    watcher.RESEARCH.mkdir(parents=True, exist_ok=True)
    watcher.FAILED.mkdir(parents=True, exist_ok=True)
    (watcher.INBOX / "2docx").mkdir(parents=True, exist_ok=True)
    yield
    shutil.rmtree(_tmp, ignore_errors=True)


class TestUniquePath:
    def test_collision_free(self):
        d = _tmp / "out"
        d.mkdir(parents=True, exist_ok=True)
        p1 = watcher._unique_path(d, "report.md")
        p1.write_text("x")
        p2 = watcher._unique_path(d, "report.md")
        assert p2.name == "report (1).md"
        assert p1 != p2


class TestTouch:
    def test_supported_ext(self):
        f = watcher.INBOX / "doc.pdf"
        f.touch()
        watcher._touch(f)
        assert f in watcher._pending

    def test_hidden_skipped(self):
        f = watcher.INBOX / ".DS_Store"
        f.touch()
        watcher._touch(f)
        assert f not in watcher._pending

    def test_unsupported_skipped(self):
        f = watcher.INBOX / "notes.txt"
        f.touch()
        watcher._touch(f)
        assert f not in watcher._pending

    def test_outside_inbox_skipped(self):
        f = _tmp / "elsewhere.pdf"
        f.touch()
        watcher._touch(f)
        assert f not in watcher._pending

    def test_2docx_subdir_touched(self):
        f = watcher.INBOX / "2docx" / "doc.pdf"
        f.touch()
        watcher._touch(f)
        assert f in watcher._pending


class TestParseOutputName:
    def test_ok_line(self):
        assert watcher._parse_output_name("x\nOK: report.md\n") == "report.md"

    def test_no_ok(self):
        assert watcher._parse_output_name("busy\n") is None

    def test_empty(self):
        assert watcher._parse_output_name("") is None


class TestConvert:
    def _mk(self, name="report.pdf"):
        p = watcher.INBOX / name
        p.write_bytes(b"%PDF-1.4 fake")
        return p

    def test_routes_2docx_with_flag(self):
        p = self._mk("doc.pdf")
        p2 = watcher.INBOX / "2docx" / p.name
        p.rename(p2)
        with mock.patch.object(watcher.subprocess, "run") as run:
            run.return_value = mock.MagicMock(returncode=0, stdout="OK: doc.md\n", stderr="")
            (watcher.RESEARCH / "doc.md").write_text("# ok")
            out = watcher._convert(p2)
        args = run.call_args.args[0]
        assert args[-1] == "--docx"
        assert out == watcher.RESEARCH / "doc.md"
        assert not p2.exists()  # source removed on success

    def test_busy_exit2_is_retryable(self):
        p = self._mk("busy.pdf")
        with mock.patch.object(watcher.subprocess, "run") as run:
            run.return_value = mock.MagicMock(returncode=2, stdout="", stderr="busy")
            assert watcher._convert(p) == "busy"  # sentinel, not a failure
        assert p.exists()  # not moved, not deleted

    def test_failure(self):
        p = self._mk("bad.pdf")
        with mock.patch.object(watcher.subprocess, "run") as run:
            run.return_value = mock.MagicMock(returncode=1, stdout="", stderr="boom\nroot cause")
            assert watcher._convert(p) is None
        assert p.exists()

    def test_success_but_no_output(self):
        p = self._mk("ghost.pdf")
        with mock.patch.object(watcher.subprocess, "run") as run:
            run.return_value = mock.MagicMock(returncode=0, stdout="OK: ghost.md\n", stderr="")
            assert watcher._convert(p) is None
        assert p.exists()


class TestProcessPending:
    def test_ready_processed(self):
        p = watcher.INBOX / "a.pdf"
        p.touch()
        watcher._pending[p] = {"seen": 0, "attempts": 0, "ready_at": 0}
        with (
            mock.patch.object(watcher, "_stable_size", return_value=True),
            mock.patch.object(watcher, "process_file", return_value=True),
        ):
            n = watcher._process_pending(time.time())
        assert n == 1
        assert p not in watcher._pending

    def test_not_ready_skipped(self):
        p = watcher.INBOX / "w.pdf"
        p.touch()
        watcher._pending[p] = {"seen": 0, "attempts": 0, "ready_at": time.time() + 999}
        with mock.patch.object(watcher, "process_file") as pf:
            watcher._process_pending(time.time())
        pf.assert_not_called()

    def test_busy_never_counts_toward_failed(self):
        """A lock collision is not a failure: no attempt increment, no Failed
        move, no matter how many times it stays busy."""
        p = watcher.INBOX / "busy2.pdf"
        p.touch()
        watcher._pending[p] = {"seen": 0, "attempts": 0, "ready_at": 0}
        with (
            mock.patch.object(watcher, "_stable_size", return_value=True),
            mock.patch.object(watcher, "process_file", return_value="busy"),
            mock.patch.object(watcher, "_move_failed") as mf,
        ):
            for i in range(10):
                watcher._process_pending(time.time() + 1000 * (i + 1))
        assert mf.call_count == 0
        assert p in watcher._pending
        assert watcher._pending[p]["attempts"] == 0

    def test_failure_retries_then_failed(self):
        p = watcher.INBOX / "r.pdf"
        p.touch()
        watcher._pending[p] = {"seen": 0, "attempts": 0, "ready_at": 0}
        with (
            mock.patch.object(watcher, "_stable_size", return_value=True),
            mock.patch.object(watcher, "process_file", return_value=False),
            mock.patch.object(watcher, "_move_failed") as mf,
        ):
            watcher._process_pending(time.time())           # attempt 1 → retry
            assert mf.call_count == 0
            assert p in watcher._pending
            assert watcher._pending[p]["attempts"] == 1
            watcher._process_pending(time.time() + 1000)    # attempt 2 → retry
            assert watcher._pending[p]["attempts"] == 2
            watcher._process_pending(time.time() + 2000)    # attempt 3 → failed
        assert mf.call_count == 1
        assert p not in watcher._pending


class TestMoveFailed:
    def test_collision_safe_name(self):
        p = watcher.INBOX / "dup.pdf"
        p.touch()
        (watcher.FAILED / "dup.pdf").write_bytes(b"existing")
        watcher._move_failed(p)
        assert not p.exists()
        assert (watcher.FAILED / "dup (1).pdf").exists()


class TestBacklog:
    def test_preexisting_files_picked_up(self):
        (watcher.INBOX / "old.pdf").touch()
        (watcher.INBOX / "2docx" / "old2.docx").touch()
        watcher._backlog()
        assert len(watcher._pending) == 2


class TestStateFile:
    def test_save_state_writes_json(self):
        watcher._save_state()
        sf = watcher.STATE_FILE
        assert sf is not None
        d = json.loads(sf.read_text(encoding="utf-8"))
        assert "pid" in d
        assert "pending" in d
        assert "last" in d
