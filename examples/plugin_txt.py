# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
"""Example plugin: convert .txt files to Markdown (identity copy).

Drop this file into ~/.config/mark-dawn/plugins/ or set
MARK_DAWN_PLUGINS=examples.plugin_txt (when importable) to enable.
"""
from pathlib import Path


class TxtHandler:
    name = "txt"
    extensions = {".txt"}

    def can_handle(self, path):
        return Path(path).suffix.lower() in self.extensions

    def convert(self, file_path, out_md):
        text = Path(file_path).read_text(encoding="utf-8", errors="replace")
        out_md.write_text(text, encoding="utf-8")


HANDLER = TxtHandler()
