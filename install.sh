#!/usr/bin/env bash
# ============================================================================
# mark-dawn one-command installer for Linux / macOS
# Usage:  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
#
# Installs:
#   - mark-dawn launcher script into ~/.local/bin/mark-dawn
#   - Makes it executable
#   - Checks for podman or docker runtime
#   - Adds ~/.local/bin to PATH hint if missing
#
# Does NOT require root / sudo.
# ============================================================================
set -eu

# --- Configuration -----------------------------------------------------------
LAUNCHER_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/mark-dawn"
REPO="kirijin/mark-dawn"

# --- Color helpers (safe for piped output) -----------------------------------
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

# --- Banner ------------------------------------------------------------------
printf "\n${C_CYAN}=== mark-dawn installer ===${C_RESET}\n"
printf "Universal Document -> Markdown pipeline\n\n"

# --- [1/4] Detect platform ---------------------------------------------------
step "1/4" "Detecting platform..."
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       fail "Unsupported platform: $OS (only Linux and macOS are supported)" ;;
esac
ok "Platform: $PLATFORM ($OS)"

# --- [2/4] Check for podman or docker ----------------------------------------
step "2/4" "Checking for container runtime..."
RUNTIME=""
if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
else
    cat >&2 <<EOF
${C_RED}FAIL:${C_RESET} Neither podman nor docker found.

Install one of them first:
  Linux (Fedora/RHEL):  sudo dnf install podman
  Linux (Ubuntu/Debian): sudo apt install podman
  Linux (Arch):         sudo pacman -S podman
  macOS:                brew install podman
  Any:                  https://podman-desktop.io/

Then re-run this installer.
EOF
    exit 1
fi
ok "Runtime: $RUNTIME"

# --- [3/4] Install launcher to ~/.local/bin ----------------------------------
step "3/4" "Installing launcher to $INSTALL_PATH..."
mkdir -p "$INSTALL_DIR"

# Download method: prefer curl, fallback to wget
if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$LAUNCHER_URL" -o "$INSTALL_PATH"; then
        fail "Failed to download launcher from $LAUNCHER_URL"
    fi
elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$INSTALL_PATH" "$LAUNCHER_URL"; then
        fail "Failed to download launcher from $LAUNCHER_URL"
    fi
else
    fail "Neither curl nor wget found. Install one and retry."
fi

chmod +x "$INSTALL_PATH"

# Sanity check: file exists, is executable, has reasonable size
if [ ! -x "$INSTALL_PATH" ]; then
    fail "Launcher is not executable after install"
fi
SIZE=$(wc -c < "$INSTALL_PATH" | tr -d ' ')
if [ "$SIZE" -lt 500 ]; then
    rm -f "$INSTALL_PATH"
    fail "Downloaded launcher looks invalid (size: ${SIZE}B). Check network/URL."
fi
ok "Launcher installed (${SIZE}B, executable)"

# --- [4/4] Add to PATH automatically ----------------------------------------
step "4/4" "Configuring PATH..."

EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        ok "$INSTALL_DIR is already in active PATH"
        ;;
    *)
        # Detect shell and pick the right config file
        CURRENT_SHELL="$(basename "$SHELL")"
        case "$CURRENT_SHELL" in
            zsh)  RC_FILE="$HOME/.zshrc" ;;
            bash) RC_FILE="$HOME/.bashrc" ;;
            *)    RC_FILE="$HOME/.profile" ;; # Fallback for sh/fish/others
        esac

        # Add to file only if it's not already there (prevents duplicates)
        if ! grep -qxF "$EXPORT_LINE" "$RC_FILE" 2>/dev/null; then
            echo "" >> "$RC_FILE"
            echo "# Added by mark-dawn installer" >> "$RC_FILE"
            echo "$EXPORT_LINE" >> "$RC_FILE"
            ok "Added $INSTALL_DIR to $RC_FILE"
        else
            ok "$INSTALL_DIR was already in $RC_FILE"
        fi
        
        # Subshell trap: we still must tell them to reload
        info "Run 'source $RC_FILE' or restart your terminal, then run: mark-dawn start"
        ;;
esac

# --- Done --------------------------------------------------------------------
printf "\n${C_GREEN}=== mark-dawn installed ===${C_RESET}\n\n"

printf "Run:\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}\n\n"

printf "Other commands:\n"
printf "  mark-dawn stop          # stop the watcher\n"
printf "  mark-dawn logs          # follow logs\n"
printf "  mark-dawn status        # show status\n"
printf "  mark-dawn update        # pull latest image and restart\n"
printf "  mark-dawn help          # show all commands\n\n"
