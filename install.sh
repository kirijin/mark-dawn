#!/usr/bin/env bash
# ============================================================================
# mark-dawn one-command installer — Linux + macOS
# Usage:  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash
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
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/mark-dawn"

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

# --- [1/3] Detect platform ---------------------------------------------------
step "1/3" "Detecting platform..."
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       fail "Unsupported platform: $OS (only Linux and macOS are supported)" ;;
esac
ok "Platform: $PLATFORM ($OS)"

# --- macOS branch ------------------------------------------------------------
if [ "$PLATFORM" = "macos" ]; then
    step "2/3" "Downloading macOS installer..."
    INSTALLER_TMP="$(mktemp /tmp/install-macos.XXXXXX.sh)"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$MACOS_INSTALLER_URL" -o "$INSTALLER_TMP"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$INSTALLER_TMP" "$MACOS_INSTALLER_URL"
    else
        fail "Neither curl nor wget found."
    fi

    if [ ! -s "$INSTALLER_TMP" ] || [ "$(wc -c < "$INSTALLER_TMP" | tr -d ' ')" -lt 200 ]; then
        rm -f "$INSTALLER_TMP"
        fail "Downloaded installer is empty or invalid."
    fi

    chmod +x "$INSTALLER_TMP"
    ok "macOS installer downloaded"
    step "3/3" "Running macOS installer..."

    # Run the dispatcher — it detects macOS version and picks the right path
    # (Apple Container for 26+, Homebrew+venv for pre-26)
    "$INSTALLER_TMP"
    rm -f "$INSTALLER_TMP"
    exit 0
fi

# --- Linux branch ------------------------------------------------------------

# --- [2/3] Check for podman or docker ----------------------------------------
step "2/3" "Checking for container runtime..."
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

Then re-run this installer.
EOF
    exit 1
fi
ok "Runtime: $RUNTIME"

# --- [3/3] Install launcher to ~/.local/bin ----------------------------------
step "3/3" "Installing launcher to $INSTALL_PATH..."
mkdir -p "$INSTALL_DIR"

if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$LAUNCHER_URL" -o "$INSTALL_PATH"; then
        fail "Failed to download launcher from $LAUNCHER_URL"
    fi
elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$INSTALL_PATH" "$LAUNCHER_URL"; then
        fail "Failed to download launcher from $LAUNCHER_URL"
    fi
else
    fail "Neither curl nor wget found."
fi

chmod +x "$INSTALL_PATH"

SIZE=$(wc -c < "$INSTALL_PATH" | tr -d ' ')
if [ "$SIZE" -lt 500 ]; then
    rm -f "$INSTALL_PATH"
    fail "Downloaded launcher looks invalid (size: ${SIZE}B). Check URL."
fi
ok "Launcher installed (${SIZE}B, executable)"

# --- Add to PATH -------------------------------------------------------------
step "4/4" "Configuring PATH..."
EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        ok "$INSTALL_DIR is already in PATH"
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
            ok "Added $INSTALL_DIR to $RC_FILE"
        fi
        info "Run 'source $RC_FILE', then: mark-dawn start"
        ;;
esac

# --- Done --------------------------------------------------------------------
printf "\n${C_GREEN}=== mark-dawn installed ===${C_RESET}\n\n"
printf "Run:\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}\n\n"
printf "Other commands:\n"
printf "  mark-dawn stop     # stop the watcher\n"
printf "  mark-dawn logs     # follow logs\n"
printf "  mark-dawn status   # show status\n"
printf "  mark-dawn update   # pull latest image and restart\n"
printf "  mark-dawn help     # show all commands\n\n"
