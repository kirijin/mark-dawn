#!/usr/bin/env bash
# ============================================================================
# mark-dawn one-command installer — Linux + macOS
# Usage:  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
#        ./install.sh [--langs eng+rus] [--data-dir ~/Docs] [--force] [--uninstall]
#
# Detects platform and delegates:
#   Linux → installs mark-dawn container launcher (needs podman/docker)
#   macOS → dispatches to install-macos.sh (version-aware)
#
# Does NOT require root / sudo.
# ============================================================================
set -eu

# --- Configuration -----------------------------------------------------------
REPO_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main"
LAUNCHER_URL="$REPO_URL/mark-dawn.sh"
MACOS_INSTALLER_URL="$REPO_URL/install-macos.sh"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/mark-dawn"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mark-dawn"
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_FILE="${CONFIG_DIR}/.install-state.json"
DEFAULT_LANGS="eng+rus"
VERSION="1.0.0"

# --- Parse arguments ---------------------------------------------------------
ARG_LANGS=""
ARG_DATA_DIR=""
ARG_UNINSTALL=false
ARG_FORCE=false
ARG_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --langs)        ARG_LANGS="$2"; shift 2 ;;
        --data-dir)     ARG_DATA_DIR="$2"; shift 2 ;;
        --install-dir)  INSTALL_DIR="$2"; INSTALL_PATH="${INSTALL_DIR}/mark-dawn"; shift 2 ;;
        --uninstall)    ARG_UNINSTALL=true; shift ;;
        --force)        ARG_FORCE=true; shift ;;
        --help|-h)      ARG_HELP=true; shift ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Help --------------------------------------------------------------------
if $ARG_HELP; then
    cat <<EOH
mark-dawn installer — usage:

  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash

Options (all optional):
  --langs LANG1+LANG2  OCR languages (default: eng+rus, interactive on first install)
  --data-dir PATH      Data directory (default: ~/Documents)
  --install-dir PATH   Install directory (default: ~/.local/bin)
  --uninstall          Remove mark-dawn launcher and config
  --force              Force re-download even if installed
  --help, -h           Show this help

Languages format: eng+rus+fra+deu+chi_sim+jpn
EOH
    exit 0
fi

# --- Color helpers (safe for piped output) -----------------------------------
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
    if [[ -f "$INSTALL_PATH" ]]; then
        rm -f "$INSTALL_PATH"
        ok "Removed launcher: $INSTALL_PATH"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        ok "Removed config: $CONFIG_FILE"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        clear_state
        ok "Removed install state"
    fi
    info "Data directories (~/Documents/Inbox, etc.) preserved."
    info "To fully remove data: rm -rf ~/Documents/Inbox ~/Documents/Research"
    printf "\n${C_GREEN}Uninstall complete.${C_RESET}\n"
    exit 0
fi

# --- Banner ------------------------------------------------------------------
printf "\n${C_CYAN}${C_BOLD}=== mark-dawn installer v${VERSION} ===${C_RESET}\n"
printf "Universal Document -> Markdown pipeline\n\n"

# --- [1/5] Detect platform ---------------------------------------------------
step "1/5" "Detecting platform..."
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       fail "Unsupported platform: $OS" ;;
esac
ok "Platform: $PLATFORM ($(uname -m))"

# macOS → delegate to macOS dispatcher
if [ "$PLATFORM" = "macos" ]; then
    step "2/5" "Delegating to macOS installer..."
    INSTALLER_TMP="$(mktemp /tmp/install-macos.XXXXXX.sh)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$MACOS_INSTALLER_URL" -o "$INSTALLER_TMP"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$INSTALLER_TMP" "$MACOS_INSTALLER_URL"
    else
        fail "Neither curl nor wget found."
    fi
    if [[ ! -s "$INSTALLER_TMP" ]] || [[ "$(wc -c < "$INSTALLER_TMP" | tr -d ' ')" -lt 200 ]]; then
        rm -f "$INSTALLER_TMP"
        fail "Downloaded installer is invalid."
    fi
    chmod +x "$INSTALLER_TMP"
    ok "macOS installer downloaded"
    step "3/5" "Running macOS installer..."
    exec "$INSTALLER_TMP" "$@"
fi

# Linux continues below -------------------------------------------------------

# --- [2/5] Check system dependencies ------------------------------------------
step "2/5" "Checking system dependencies..."
RUNTIME=""
if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
    ok "Container runtime: podman ($(podman --version 2>/dev/null | head -1))"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
    ok "Container runtime: docker ($(docker --version 2>/dev/null | head -1))"
else
    fail "Neither podman nor docker found. Install one first:
  Fedora/RHEL: sudo dnf install podman
  Debian/Ubuntu: sudo apt install podman
  Arch: sudo pacman -S podman"
fi

# Check for existing installation → reinstall mode
load_state
IS_REINSTALL=false
if [[ -f "$CONFIG_FILE" ]] && [[ -n "$STATE_VERSION" ]]; then
    IS_REINSTALL=true
fi

if $IS_REINSTALL && ! $ARG_FORCE; then
    info "Existing installation detected (v${STATE_VERSION})"
    ok "Config preserved from previous install"
    # Use existing langs if none specified
    if [[ -z "$ARG_LANGS" ]] && [[ -n "${STATE_LANGS:-}" ]]; then
        ARG_LANGS="$STATE_LANGS"
    fi
fi

# --- [3/5] Configure OCR languages -------------------------------------------
step "3/5" "Configuring OCR languages..."
if [[ -n "$ARG_LANGS" ]]; then
    ok "Languages: $ARG_LANGS (from flag/config)"
elif $IS_REINSTALL && [[ -n "${STATE_LANGS:-}" ]]; then
    ARG_LANGS="$STATE_LANGS"
    ok "Languages: $ARG_LANGS (from previous install)"
elif [ -t 0 ]; then
    prompt_langs "OCR languages"
else
    ARG_LANGS="$DEFAULT_LANGS"
    info "Languages: $ARG_LANGS (default, non-interactive)"
fi

# --- [4/5] Install launcher ---------------------------------------------------
step "4/5" "Installing launcher to ${INSTALL_PATH}..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$LAUNCHER_URL" -o "$INSTALL_PATH" || fail "Download failed"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$INSTALL_PATH" "$LAUNCHER_URL" || fail "Download failed"
else
    fail "Neither curl nor wget found."
fi

chmod +x "$INSTALL_PATH"
SIZE=$(wc -c < "$INSTALL_PATH" | tr -d ' ')
if [[ "$SIZE" -lt 500 ]]; then
    rm -f "$INSTALL_PATH"
    fail "Launcher too small (${SIZE}B) — invalid download"
fi
ok "Launcher installed (${SIZE}B, executable)"

# Save config
DATA_DIR="${ARG_DATA_DIR:-$HOME/Documents}"
cat > "$CONFIG_FILE" <<EOF
# mark-dawn configuration
image="docker.io/kirijin/mark-dawn:latest"
data_dir="$DATA_DIR"
langs="$ARG_LANGS"
runtime="$RUNTIME"
EOF
chmod 600 "$CONFIG_FILE"
save_state
ok "Config saved"

# --- [5/5] Add to PATH -------------------------------------------------------
step "5/5" "Adding ${INSTALL_DIR} to PATH..."

EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        ok "$INSTALL_DIR already in PATH"
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
            ok "Added to $RC_FILE"
        else
            ok "Already in $RC_FILE"
        fi
        info "Run 'source ${RC_FILE}', then: mark-dawn start"
        ;;
esac

# Create data directories
mkdir -p "$DATA_DIR/Inbox" "$DATA_DIR/Research" "$DATA_DIR/Inbox_Failed" \
         "$DATA_DIR/Inbox/2md" "$DATA_DIR/Inbox/2docx"

# --- Verification ------------------------------------------------------------
printf "\n${C_YELLOW}Verification:${C_RESET}\n"
VERIFY_FAIL=0
[[ -x "$INSTALL_PATH" ]] && ok "Launcher executable" || { warn "Launcher not executable"; VERIFY_FAIL=1; }
command -v "$RUNTIME" >/dev/null 2>&1 && ok "Runtime: $RUNTIME" || { warn "Runtime missing"; VERIFY_FAIL=1; }
[[ -f "$CONFIG_FILE" ]] && ok "Config present" || { warn "Config missing"; VERIFY_FAIL=1; }
[[ -d "$DATA_DIR/Inbox" ]] && ok "Inbox directory" || { warn "Inbox missing"; VERIFY_FAIL=1; }
[[ -d "$DATA_DIR/Research" ]] && ok "Research directory" || { warn "Research missing"; VERIFY_FAIL=1; }

# --- Done --------------------------------------------------------------------
printf "\n${C_GREEN}${C_BOLD}=== mark-dawn installed ===${C_RESET}\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}    # start background watcher\n"
printf "  ${C_CYAN}mark-dawn status${C_RESET}   # check status\n"
printf "  ${C_CYAN}mark-dawn --help${C_RESET}    # all commands\n\n"
printf "  Inbox:    ${DATA_DIR}/Inbox\n"
printf "  Research: ${DATA_DIR}/Research\n"
printf "  Languages: ${ARG_LANGS}\n"
printf "  Runtime:   ${RUNTIME}\n\n"
