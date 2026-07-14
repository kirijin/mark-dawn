#!/bin/bash
# ============================================================================
# mark-dawn macOS installer — Homebrew + Python venv (pre-macOS 26)
# ============================================================================
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main"
LAUNCHER_URL="$REPO_URL/libexec/mark-dawn-macos"
INSTALL_DIR="${MARK_DAWN_INSTALL_DIR:-/opt/mark-dawn}"
BIN_DIR="$HOME/.local/bin"
LAUNCHER_PATH="$BIN_DIR/mark-dawn"
VENV_DIR="$INSTALL_DIR/venv"
CONFIG_DIR="$HOME/Library/Application Support/mark-dawn"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/.install-state.json"
DEFAULT_LANGS="eng+rus"
VERSION="1.0.0"

# --- Parse arguments ---------------------------------------------------------
ARG_LANGS=""
ARG_DATA_DIR=""
ARG_UNINSTALL=false
ARG_FORCE=false
ARG_HELP=false
ARG_SKIP_BREW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --langs)        ARG_LANGS="$2"; shift 2 ;;
        --data-dir)     ARG_DATA_DIR="$2"; shift 2 ;;
        --install-dir)  INSTALL_DIR="$2"; VENV_DIR="$INSTALL_DIR/venv"; shift 2 ;;
        --uninstall)    ARG_UNINSTALL=true; shift ;;
        --force)        ARG_FORCE=true; shift ;;
        --skip-brew)    ARG_SKIP_BREW=true; shift ;;
        --help|-h)      ARG_HELP=true; shift ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

if $ARG_HELP; then
    cat <<EOH
mark-dawn macOS installer (pre-26) — usage:

  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
  # or directly:
  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install-macos-brew.sh | bash

Options:
  --langs LANG1+LANG2  OCR languages (default: eng+rus, interactive on first install)
  --data-dir PATH      Data directory (default: ~/Documents)
  --install-dir PATH   Python venv location (default: /opt/mark-dawn)
  --skip-brew          Skip brew install (use existing packages)
  --uninstall          Remove mark-dawn and its venv
  --force              Re-download even if installed
  --help, -h           Show this help
EOH
    exit 0
fi

# --- Color helpers -----------------------------------------------------------
if [ -t 1 ]; then
    C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
    C_RED="\033[31m";    C_RESET="\033[0m"; C_BOLD="\033[1m"
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""; C_BOLD=""
fi

step()  { printf "${C_CYAN}[%s]${C_RESET} %s\n" "$1" "$2"; }
ok()    { printf "${C_GREEN}OK:${C_RESET}  %s\n" "$1"; }
info()  { printf "${C_YELLOW}>>${C_RESET} %s\n" "$1"; }
fail()  { printf "${C_RED}FAIL:${C_RESET} %s\n" "$1" >&2; exit 1; }
warn()  { printf "${C_RED}WARN:${C_RESET} %s\n" "$1" >&2; }

# --- State management --------------------------------------------------------
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        STATE_LANGS=$(sed -n 's/.*"langs": *"\([^"]*\)".*/\1/p' "$STATE_FILE" 2>/dev/null || echo "")
        STATE_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$STATE_FILE" 2>/dev/null || echo "")
        STATE_DATA_DIR=$(sed -n 's/.*"data_dir": *"\([^"]*\)".*/\1/p' "$STATE_FILE" 2>/dev/null || echo "")
    fi
}

save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
{
  "version": "$VERSION",
  "langs": "${ARG_LANGS:-$DEFAULT_LANGS}",
  "data_dir": "${ARG_DATA_DIR:-$DATA_DIR}",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

clear_state() {
    rm -f "$STATE_FILE"
}

# --- Interactive prompt with timeout -----------------------------------------
prompt_langs() {
    local prompt="$1 [${DEFAULT_LANGS}]: "
    local input=""
    if [ -t 0 ]; then
        printf "${C_CYAN}?${C_RESET} ${C_BOLD}%s${C_RESET}" "$prompt"
        read -r -t 10 input 2>/dev/null || true
    fi
    ARG_LANGS="${input:-$DEFAULT_LANGS}"
    ok "Languages: $ARG_LANGS"
}

# --- Uninstall ---------------------------------------------------------------
if $ARG_UNINSTALL; then
    printf "\n${C_YELLOW}=== mark-dawn uninstall ===${C_RESET}\n\n"
    if [[ -f "$LAUNCHER_PATH" ]]; then
        rm -f "$LAUNCHER_PATH"
        ok "Removed launcher: $LAUNCHER_PATH"
    fi
    # Unload launchd service if installed
    PLIST="$HOME/Library/LaunchAgents/com.mark-dawn.watcher.plist"
    if [[ -f "$PLIST" ]]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        ok "Removed launchd service"
    fi
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        ok "Removed installation: $INSTALL_DIR"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        ok "Removed config"
    fi
    clear_state
    info "Data directories preserved (~/Documents/Inbox, Research, etc.)"
    printf "\n${C_GREEN}Uninstall complete.${C_RESET}\n"
    exit 0
fi

# --- Banner ------------------------------------------------------------------
printf "\n${C_CYAN}${C_BOLD}=== mark-dawn installer — macOS (Homebrew + Python) v${VERSION} ===${C_RESET}\n\n"

# --- [1/7] macOS version check -----------------------------------------------
step "1/7" "Checking macOS version..."
if ! command -v sw_vers &>/dev/null; then
    fail "Not macOS. This installer is for macOS only."
fi
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "0")
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d'.' -f1)
if [[ "$MACOS_MAJOR" -ge 26 ]] && ! $ARG_FORCE; then
    info "macOS 26+ detected — consider the Apple Container path for lower overhead:"
    info "  curl -fsSL $REPO_URL/install-macos-container.sh | bash"
    info "Continuing with brew+venv path (--force to suppress this)."
fi
ok "macOS $MACOS_VER"

# --- [2/7] Check Homebrew ----------------------------------------------------
step "2/7" "Checking Homebrew..."
if $ARG_SKIP_BREW; then
    info "Skipping brew operations (--skip-brew)"
elif command -v brew &>/dev/null; then
    ok "Homebrew: $(brew --version 2>/dev/null | head -1)"
else
    info "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        fail "Homebrew install failed. Try manually: https://brew.sh"
    }
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
fi

# --- Reinstall detection ----------------------------------------------------
load_state
IS_REINSTALL=false
if [[ -d "$INSTALL_DIR" ]] && [[ -f "$STATE_FILE" ]] && [[ -n "$STATE_VERSION" ]]; then
    IS_REINSTALL=true
fi

if $IS_REINSTALL && ! $ARG_FORCE; then
    info "Existing installation detected at $INSTALL_DIR (v${STATE_VERSION})"
    if [[ -z "$ARG_LANGS" ]] && [[ -n "${STATE_LANGS:-}" ]]; then
        ARG_LANGS="$STATE_LANGS"
        ok "Using previous language config: $ARG_LANGS"
    fi
    if [[ -f "$VENV_DIR/bin/python" ]]; then
        ok "Python venv intact"
    fi
fi

# --- [3/7] Configure OCR languages -------------------------------------------
step "3/7" "Configuring OCR languages..."
if [[ -n "$ARG_LANGS" ]]; then
    ok "Languages: $ARG_LANGS (from flag/config)"
elif $IS_REINSTALL && [[ -n "${STATE_LANGS:-}" ]]; then
    ARG_LANGS="$STATE_LANGS"
    ok "Languages: $ARG_LANGS (preserved from previous install)"
elif [ -t 0 ]; then
    prompt_langs "OCR languages"
else
    ARG_LANGS="$DEFAULT_LANGS"
    info "Languages: $ARG_LANGS (default, non-interactive)"
fi

# --- [4/7] Install system packages via brew ----------------------------------
if ! $ARG_SKIP_BREW; then
    step "4/7" "Installing system packages via brew..."
    info "ocrmypdf + tesseract-lang + djvulibre + pandoc"

    BREW_UPGRADE=""
    $ARG_FORCE && BREW_UPGRADE="--overwrite"

    if $IS_REINSTALL && ! $ARG_FORCE; then
        # Quick check: are critical tools present?
        MISSING=""
        for cmd in ocrmypdf tesseract pandoc djvutxt; do
            command -v "$cmd" &>/dev/null || MISSING="$MISSING $cmd"
        done
        if [[ -z "$MISSING" ]]; then
            ok "All system tools already installed (use --force to reinstall)"
        else
            info "Missing:${MISSING} — installing..."
            brew install ocrmypdf tesseract-lang djvulibre pandoc 2>&1 | tail -3 || true
            ok "System packages installed"
        fi
    else
        brew install ocrmypdf tesseract-lang djvulibre pandoc 2>&1 | tail -3 || {
            warn "Brew install had issues — some tools may need manual install"
        }
        ok "System packages installed"
    fi

    # Verify
    for cmd in ocrmypdf tesseract pandoc djvutxt; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "$cmd not found in PATH after brew install"
        fi
    done
fi

# --- [5/7] Python virtualenv --------------------------------------------------
step "5/7" "Setting up Python virtualenv..."

if $IS_REINSTALL && [[ -f "$VENV_DIR/bin/python" ]] && ! $ARG_FORCE; then
    ok "Virtualenv already exists at $VENV_DIR"
else
    PYTHON=""
    for p in python3 python; do
        command -v "$p" &>/dev/null && PYTHON="$p" && break
    done
    if [[ -z "$PYTHON" ]]; then
        info "Python not found. Installing via brew..."
        brew install python@3.12
        PYTHON="python3"
    fi
    PY_VER=$("$PYTHON" --version 2>&1)
    info "Using $PY_VER"

    mkdir -p "$INSTALL_DIR"
    "$PYTHON" -m venv "$VENV_DIR"
    ok "Virtualenv created at $VENV_DIR"
fi

# --- [6/7] Install Python packages -------------------------------------------
step "6/7" "Installing Python packages..."

PIP_PACKAGES=("pymupdf4llm" "markitdown[all]" "watchdog" "python-docx" "openpyxl" "python-pptx")

if $IS_REINSTALL && ! $ARG_FORCE; then
    # Quick verify: check if imports work
    if "$VENV_DIR/bin/python" -c "import pymupdf4llm, markitdown, watchdog, docx" 2>/dev/null; then
        ok "Python packages already installed and importable (use --force to reinstall)"
    else
        info "Some packages missing — reinstalling..."
        "$VENV_DIR/bin/pip" install --upgrade pip 2>&1 | tail -1 || true
        "$VENV_DIR/bin/pip" install --no-cache-dir "${PIP_PACKAGES[@]}" 2>&1 | tail -3 || {
            fail "pip install failed. Check network."
        }
        ok "Python packages installed"
    fi
else
    "$VENV_DIR/bin/pip" install --upgrade pip 2>&1 | tail -1 || true
    "$VENV_DIR/bin/pip" install --no-cache-dir "${PIP_PACKAGES[@]}" 2>&1 | tail -3 || {
        fail "pip install failed. Check network."
    }
    ok "Python packages installed"
fi

# Verify imports
for mod in pymupdf4llm markitdown watchdog docx; do
    if "$VENV_DIR/bin/python" -c "import $mod" 2>/dev/null; then
        : ok
    else
        warn "Import failed: $mod"
    fi
done

# Deploy Python scripts
for script in convert_pdf.py watcher.py docx_styler.py; do
    URL="$REPO_URL/$script"
    DEST="$VENV_DIR/bin/$script"
    if command -v curl &>/dev/null; then
        curl -fsSL "$URL" -o "$DEST" 2>/dev/null || warn "Failed to download $script"
    elif command -v wget &>/dev/null; then
        wget -qO "$DEST" "$URL" 2>/dev/null || warn "Failed to download $script"
    fi
    chmod +x "$DEST" 2>/dev/null || true
done
ok "Python scripts deployed"

# --- [7/7] Install launcher ---------------------------------------------------
step "7/7" "Installing launcher to ${LAUNCHER_PATH}..."

mkdir -p "$BIN_DIR"

if command -v curl &>/dev/null; then
    curl -fsSL "$LAUNCHER_URL" -o "$LAUNCHER_PATH.tmp" || fail "Download failed"
elif command -v wget &>/dev/null; then
    wget -qO "$LAUNCHER_PATH.tmp" "$LAUNCHER_URL" || fail "Download failed"
else
    fail "Neither curl nor wget found."
fi

# Set the install dir in the launcher
sed -i '' "s|MARK_DAWN_INSTALL_DIR:-/opt/mark-dawn|MARK_DAWN_INSTALL_DIR:-${INSTALL_DIR}|" "$LAUNCHER_PATH.tmp" 2>/dev/null || true

mv "$LAUNCHER_PATH.tmp" "$LAUNCHER_PATH"
chmod +x "$LAUNCHER_PATH"

SIZE=$(wc -c < "$LAUNCHER_PATH" | tr -d ' ')
if [[ "$SIZE" -lt 500 ]]; then
    rm -f "$LAUNCHER_PATH"
    fail "Launcher too small (${SIZE}B)"
fi
ok "Launcher installed (${SIZE}B, executable)"

# Save config
DATA_DIR="${ARG_DATA_DIR:-$HOME/Documents}"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
# mark-dawn configuration — generated $(date)
data_dir="$DATA_DIR"
langs="$ARG_LANGS"
EOF
chmod 600 "$CONFIG_FILE"
save_state
ok "Config saved"

# Data directories
mkdir -p "$DATA_DIR/Inbox" "$DATA_DIR/Research" "$DATA_DIR/Inbox_Failed" \
         "$DATA_DIR/Inbox/2md" "$DATA_DIR/Inbox/2docx"

# PATH
EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
case ":$PATH:" in
    *":$BIN_DIR:"*) ok "$BIN_DIR already in PATH" ;;
    *)
        CURRENT_SHELL="$(basename "$SHELL")"
        case "$CURRENT_SHELL" in
            zsh)  RC="$HOME/.zshrc" ;;
            bash) RC="$HOME/.bashrc" ;;
            *)    RC="$HOME/.profile" ;;
        esac
        if ! grep -qxF "$EXPORT_LINE" "$RC" 2>/dev/null; then
            echo "" >> "$RC"
            echo "# Added by mark-dawn installer" >> "$RC"
            echo "$EXPORT_LINE" >> "$RC"
            ok "Added $BIN_DIR to $RC"
        fi
        info "Run 'source $RC', then: mark-dawn start"
        ;;
esac

# --- Verification ------------------------------------------------------------
printf "\n${C_YELLOW}Verification:${C_RESET}\n"
VFAIL=0
[[ -x "$LAUNCHER_PATH" ]] && ok "Launcher executable" || { warn "Launcher missing"; VFAIL=1; }
[[ -f "$VENV_DIR/bin/python" ]] && ok "Python venv" || { warn "Venv missing"; VFAIL=1; }
[[ -f "$CONFIG_FILE" ]] && ok "Config present" || { warn "Config missing"; VFAIL=1; }
"$VENV_DIR/bin/python" -c "import pymupdf4llm" 2>/dev/null && ok "pymupdf4llm importable" || warn "pymupdf4llm import failed"
command -v tesseract &>/dev/null && ok "Tesseract available" || warn "tesseract not in PATH"
command -v pandoc &>/dev/null && ok "pandoc available" || warn "pandoc not in PATH"

# --- Done --------------------------------------------------------------------
printf "\n${C_GREEN}${C_BOLD}=== mark-dawn installed ===${C_RESET}\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}      # start background watcher\n"
printf "  ${C_CYAN}mark-dawn status${C_RESET}     # check status\n"
printf "  ${C_CYAN}mark-dawn install-service${C_RESET}  # launchd auto-start\n\n"
printf "  Venv:     ${VENV_DIR}\n"
printf "  Inbox:    ${DATA_DIR}/Inbox\n"
printf "  Research: ${DATA_DIR}/Research\n"
printf "  Languages: ${ARG_LANGS}\n"
printf "  Launcher: ${LAUNCHER_PATH}\n\n"
