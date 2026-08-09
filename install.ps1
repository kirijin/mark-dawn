# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT

# Compatibility entry point — the full installer lives in mark-dawn.ps1.
# This shim keeps old one-liner URLs (iwr ... | iex) and local copies working
# without duplicating any installer logic.
#
# When executed as a file, forward to the sibling installer.
# When piped via iex (no $PSCommandPath), fetch mark-dawn.ps1 to a temp file
# and run that.

if ($PSCommandPath) {
    $real = Join-Path (Split-Path $PSCommandPath -Parent) "mark-dawn.ps1"
    & $real @args
} else {
    $tmp = Join-Path $env:TEMP ("mark-dawn-installer-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.ps1" -UseBasicParsing -OutFile $tmp -ErrorAction Stop
        & $tmp @args
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}
