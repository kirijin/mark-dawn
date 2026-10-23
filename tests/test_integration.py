#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Integration tests that use real dependencies (Pillow, etc.).

Skipped automatically when the dependency is missing, so the unit suite stays
green in minimal CI environments.
"""
import os
import tempfile
from pathlib import Path

import pytest

PIL = pytest.importorskip("PIL")
from PIL import Image as PImage


def test_pil_lazy_load_materialise(tmp_path):
    """F1 regression guard: pixels must be materialised before the source is
    unlinked, otherwise a later save() reads from a deleted handle."""
    src = tmp_path / "src.png"
    img = PImage.new("RGB", (32, 32), (12, 34, 56))
    img.save(src)

    opened = PImage.open(src)
    assert opened.size == (32, 32)
    opened.load()          # materialise
    src.unlink()           # source gone
    out = tmp_path / "out.png"
    opened.save(out)       # must not raise
    assert out.is_file() and out.stat().st_size > 0
