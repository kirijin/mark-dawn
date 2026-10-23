# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT

# Compatibility entry point. The orchestrator lives in mark-dawn.ps1 and its
# modules live under windows/. This shim keeps old one-liner URLs working.

$modules = @("00-bootstrap.ps1","10-steps.ps1","20-commands.ps1",
             "30-templates.ps1","40-ui.ps1")

if ($PSCommandPath) {
    $root = Split-Path $PSCommandPath -Parent
    $real = Join-Path $root "mark-dawn.ps1"
    & $real @args
} else {
    $tmp = Join-Path $env:TEMP ("mark-dawn-installer-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp "windows") -Force | Out-Null
    try {
        $base = "https://raw.githubusercontent.com/kirijin/mark-dawn/main"
        Invoke-WebRequest -Uri "$base/mark-dawn.ps1" -UseBasicParsing -OutFile (Join-Path $tmp "mark-dawn.ps1") -ErrorAction Stop
        foreach ($m in $modules) {
            Invoke-WebRequest -Uri "$base/windows/$m" -UseBasicParsing -OutFile (Join-Path $tmp "windows" $m) -ErrorAction Stop
        }
        & (Join-Path $tmp "mark-dawn.ps1") @args
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
