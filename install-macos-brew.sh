#!/bin/bash
# ============================================================================
# mark-dawn macOS installer — Homebrew + Python venv (pre-macOS 26)
# Installs: ocrmypdf, tesseract-lang, djvulibre, pandoc via brew
#           pymupdf4llm, markitdown, watchdog via pip in a venv
#           mark-dawn launcher to ~/.local/bin/
# ============================================================================
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main"
LAUNCHER_URL="$REPO_URL/libexec/mark-dawn-macos"
INSTALL_DIR="${MARK_DAWN_INSTALL_DIR:-/opt/mark-dawn}"
BIN_DIR="$HOME/.local/bin"
LAUNCHER_PATH="$BIN_DIR/mark-dawn"
VENV_DIR="$INSTALL_DIR/venv"
LOG_DIR="$HOME/Library/Logs/mark-dawn"
CONFIG_DIR="$HOME/Library/Application Support/mark-dawn"
LANGS="eng+rus+fra+deu+chi_sim+jpn"

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

printf "\n${C_CYAN}=== mark-dawn installer — Homebrew + Python (macOS pre-26) ===${C_RESET}\n\n"

# --- [1/8] Check Homebrew --------------------------------------------------
step "1/8" "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
    info "Homebrew not found. Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        fail "Homebrew installation failed. Install manually: https://brew.sh"
    }
    # Add brew to PATH for this session
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi
BREW_VER=$(brew --version 2>/dev/null | head -1 || echo "unknown")
ok "Homebrew ready ($BREW_VER)"

# --- [2/8] Install system packages via brew --------------------------------
step "2/8" "Installing system packages (ocrmypdf + tesseract-lang + djvulibre + pandoc)..."
info "This downloads pre-built bottles — a few minutes on typical connections."

brew install ocrmypdf tesseract-lang djvulibre pandoc 2>&1 || {
    fail "Brew install failed. Check: brew doctor"
}

# Verify critical tools
for cmd in ocrmypdf tesseract gs qpdf pandoc djvutxt; do
    if ! command -v "$cmd" &>/dev/null; then
        info "Warning: $cmd not found in PATH after brew install"
    fi
done
ok "System packages installed"

# --- [3/8] Create Python virtualenv ----------------------------------------
step "3/8" "Creating Python virtualenv at $VENV_DIR..."

if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    PYTHON=python
else
    fail "No Python found. Install with: brew install python@3.12"
fi

PY_VER=$("$PYTHON" --version 2>&1 | head -1)
info "Using $PY_VER"

mkdir -p "$INSTALL_DIR"
"$PYTHON" -m venv "$VENV_DIR"
ok "Virtualenv created"

# --- [4/8] Install Python packages -----------------------------------------
step "4/8" "Installing Python packages via pip..."
info "Packages: pymupdf4llm, markitdown[all], watchdog, python-docx, openpyxl, python-pptx"

"$VENV_DIR/bin/pip" install --upgrade pip 2>&1 | tail -1 || true
"$VENV_DIR/bin/pip" install --no-cache-dir \
    pymupdf4llm \
    "markitdown[all]" \
    watchdog \
    python-docx \
    openpyxl \
    python-pptx 2>&1 || {
    fail "pip install failed. Check network connectivity."
}

# Quick import verification
"$VENV_DIR/bin/python" -c "
import pymupdf4llm; print('  pymupdf4llm:', pymupdf4llm.__version__)
import markitdown; print('  markitdown: ready')
import watchdog; print('  watchdog:', watchdog.__version__)
import docx; print('  python-docx: ready')
" 2>&1 || info "Warning: some imports failed — features may be limited"

ok "Python packages installed and verified"

# --- [5/8] Deploy Python scripts into venv ---------------------------------
step "5/8" "Deploying Python scripts..."

# Copy convert_pdf.py, watcher.py, docx_styler.py into the venv bin dir
SCRIPT_BASE="$VENV_DIR/bin"
for script in convert_pdf.py watcher.py docx_styler.py; do
    URL="$REPO_URL/$script"
    DEST="$SCRIPT_BASE/$script"
    if command -v curl &>/dev/null; then
        curl -fsSL "$URL" -o "$DEST"
    elif command -v wget &>/dev/null; then
        wget -qO "$DEST" "$URL"
    else
        fail "Need curl or wget"
    fi
    chmod +x "$DEST"
done

ok "Python scripts deployed to $SCRIPT_BASE"

# --- [6/8] Install launcher -------------------------------------------------
step "6/8" "Installing launcher to $LAUNCHER_PATH..."

mkdir -p "$BIN_DIR"

# Download and customize the launcher with the install dir
if command -v curl &>/dev/null; then
    curl -fsSL "$LAUNCHER_URL" -o "$LAUNCHER_PATH.tmp"
elif command -v wget &>/dev/null; then
    wget -qO "$LAUNCHER_PATH.tmp" "$LAUNCHER_URL"
else
    fail "Need curl or wget"
fi

# Set the install dir in the launcher
sed -i '' "s|MARK_DAWN_INSTALL_DIR:-/opt/mark-dawn|MARK_DAWN_INSTALL_DIR:-${INSTALL_DIR}|" "$LAUNCHER_PATH.tmp" 2>/dev/null || true

mv "$LAUNCHER_PATH.tmp" "$LAUNCHER_PATH"
chmod +x "$LAUNCHER_PATH"

SIZE=$(wc -c < "$LAUNCHER_PATH" | tr -d ' ')
if [[ "$SIZE" -lt 500 ]]; then
    rm -f "$LAUNCHER_PATH"
    fail "Downloaded launcher looks invalid (size: ${SIZE}B)"
fi
ok "Launcher installed (${SIZE}B, executable)"

# --- [7/8] Create data directories -----------------------------------------
step "7/8" "Creating data directories..."
mkdir -p "$HOME/Documents/Inbox" "$HOME/Documents/Research" "$HOME/Documents/Inbox_Failed" \
         "$HOME/Documents/Inbox/2md" "$HOME/Documents/Inbox/2docx"
ok "Data directories ready"

# --- [8/8] Add to PATH -----------------------------------------------------
step "8/8" "Configuring PATH..."

EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

case ":$PATH:" in
    *":$BIN_DIR:"*)
        ok "$BIN_DIR is already in active PATH"
        ;;
    *)
        CURRENT_SHELL="$(basename "$SHELL")"
        case "$CURRENT_SHELL" in
            zsh)  RC_FILE="$HOME/.zshrc" ;;
            bash) RC_FILE="$HOME/.bashrc" ;;
            *)    RC_FILE="$HOME/.profile" ;;
        esac

        if ! grep -qxF "$EXPORT_LINE" "$RC_FILE" 2>/dev/null; then
            echo "" >> "$RC_FILE"
            echo "# Added by mark-dawn installer" >> "$RC_FILE"
            echo "$EXPORT_LINE" >> "$RC_FILE"
            ok "Added $BIN_DIR to $RC_FILE"
        else
            ok "$BIN_DIR was already in $RC_FILE"
        fi
        info "Run 'source $RC_FILE' or restart your terminal"
        ;;
esac

# --- Done ------------------------------------------------------------------
printf "\n${C_GREEN}=== mark-dawn installed (Homebrew + Python) ===${C_RESET}\n\n"
printf "Run:\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}\n"
printf "  ${C_CYAN}mark-dawn status${C_RESET}\n\n"
printf "Other commands:\n"
printf "  mark-dawn stop           # stop the watcher\n"
printf "  mark-dawn logs           # follow watcher logs\n"
printf "  mark-dawn convert FILE   # convert a single file\n"
printf "  mark-dawn update         # update Python packages and restart\n"
printf "  mark-dawn install-service # install as launchd service\n"
printf "  mark-dawn help           # show all commands\n\n"
printf "Data directories:\n"
printf "  ~/Documents/Inbox     ← drop files here\n"
printf "  ~/Documents/Research  → converted .md files appear here\n\n"
