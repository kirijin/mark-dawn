#!/bin/bash
# ============================================================================
# mark-dawn macOS version dispatcher
# Detects macOS version and routes to the right installer.
# ============================================================================
set -euo pipefail

# --- Color helpers ---------------------------------------------------------
if [ -t 1 ]; then
    C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
    C_RED="\033[31m";    C_RESET="\033[0m"
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

step()  { printf "${C_CYAN}[%s]${C_RESET} %s\n" "$1" "$2"; }
ok()    { printf "${C_GREEN}OK:${C_RESET} %s\n" "$1"; }
info()  { printf "${C_YELLOW}>>${C_RESET} %s\n" "$1"; }
fail()  { printf "${C_RED}FAIL:${C_RESET} %s\n" "$1" >&2; exit 1; }

# --- Detect macOS version --------------------------------------------------
step "1/3" "Detecting macOS version..."
if ! command -v sw_vers &>/dev/null; then
    fail "Not macOS. This installer is for macOS only."
fi

MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "0")
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d'.' -f1)

ok "macOS $MACOS_VERSION (major: $MACOS_MAJOR)"

# --- Route to the right installer ------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$MACOS_MAJOR" -ge 26 ]]; then
    step "2/3" "macOS 26+ detected — using Apple Container path"
    echo ""
    echo "  Apple's native container CLI ships with macOS 26 Tahoe."
    echo "  Lightweight per-container microVMs. ~51 MB idle RAM."
    echo ""

    INSTALLER="$SCRIPT_DIR/install-macos-container.sh"
    if [[ ! -f "$INSTALLER" ]]; then
        # When piped via curl, script dir may not resolve. Try PATH lookup.
        INSTALLER="$(dirname "$0")/install-macos-container.sh"
    fi
    if [[ ! -f "$INSTALLER" ]]; then
        # Fallback: download from raw GitHub
        INSTALLER_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main/install-macos-container.sh"
        INSTALLER="/tmp/install-macos-container.sh"
        if command -v curl &>/dev/null; then
            curl -fsSL "$INSTALLER_URL" -o "$INSTALLER"
        elif command -v wget &>/dev/null; then
            wget -qO "$INSTALLER" "$INSTALLER_URL"
        else
            fail "Need curl or wget to download installer"
        fi
        chmod +x "$INSTALLER"
    fi
    exec "$INSTALLER"
else
    step "2/3" "macOS pre-26 detected — using Homebrew + Python venv path"
    echo ""
    echo "  Installs native tools via Homebrew (ocrmypdf, djvulibre, pandoc)."
    echo "  Creates Python virtualenv for pymupdf4llm, markitdown, watchdog."
    echo "  Zero VM overhead — runs as native macOS processes."
    echo ""

    INSTALLER="$SCRIPT_DIR/install-macos-brew.sh"
    if [[ ! -f "$INSTALLER" ]]; then
        INSTALLER="$(dirname "$0")/install-macos-brew.sh"
    fi
    if [[ ! -f "$INSTALLER" ]]; then
        INSTALLER_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main/install-macos-brew.sh"
        INSTALLER="/tmp/install-macos-brew.sh"
        if command -v curl &>/dev/null; then
            curl -fsSL "$INSTALLER_URL" -o "$INSTALLER"
        elif command -v wget &>/dev/null; then
            wget -qO "$INSTALLER" "$INSTALLER_URL"
        else
            fail "Need curl or wget to download installer"
        fi
        chmod +x "$INSTALLER"
    fi
    exec "$INSTALLER"
fi
