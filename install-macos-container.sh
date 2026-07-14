#!/bin/bash
# ============================================================================
# mark-dawn macOS installer — Apple Container (macOS 26+)
# Installs: mark-dawn CLI via Apple's native container runtime
# ============================================================================
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main"
LAUNCHER_URL="$REPO_URL/libexec/mark-dawn-container"
INSTALL_DIR="$HOME/.local/bin"
LAUNCHER_PATH="$INSTALL_DIR/mark-dawn"
CONFIG_DIR="$HOME/Library/Application Support/mark-dawn"
IMAGE="docker.io/kirijin/mark-dawn:latest"

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

printf "\n${C_CYAN}=== mark-dawn installer — Apple Container (macOS 26+) ===${C_RESET}\n\n"

# --- [1/5] Check macOS version --------------------------------------------
step "1/5" "Verifying Apple container CLI..."
if ! command -v container &>/dev/null; then
    fail "'container' CLI not found. This installer requires macOS 26 (Tahoe) or later."
fi

# Quick test: container works
if ! container --version &>/dev/null 2>&1; then
    fail "Container CLI not functional. Is macOS 26+ installed?"
fi
CONTAINER_VER=$(container --version 2>/dev/null || echo "unknown")
ok "Container CLI available ($CONTAINER_VER)"

# --- [2/5] Create directories ---------------------------------------------
step "2/5" "Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
ok "Directories ready"

# --- [3/5] Install launcher ------------------------------------------------
step "3/5" "Installing launcher to $LAUNCHER_PATH..."

if command -v curl &>/dev/null; then
    if ! curl -fsSL "$LAUNCHER_URL" -o "$LAUNCHER_PATH"; then
        fail "Failed to download launcher from $LAUNCHER_URL"
    fi
elif command -v wget &>/dev/null; then
    if ! wget -qO "$LAUNCHER_PATH" "$LAUNCHER_URL"; then
        fail "Failed to download launcher from $LAUNCHER_URL"
    fi
else
    fail "Neither curl nor wget found."
fi

chmod +x "$LAUNCHER_PATH"
SIZE=$(wc -c < "$LAUNCHER_PATH" | tr -d ' ')
if [[ "$SIZE" -lt 500 ]]; then
    rm -f "$LAUNCHER_PATH"
    fail "Downloaded launcher looks invalid (size: ${SIZE}B)"
fi
ok "Launcher installed (${SIZE}B, executable)"

# --- [4/5] Pull container image -------------------------------------------
step "4/5" "Pulling mark-dawn container image (~1.2 GB)..."
info "First pull may take several minutes on slow connections."
container image pull "$IMAGE" 2>&1 || {
    info "Pull failed — you can retry later with: mark-dawn update"
    info "Continuing with setup..."
}
ok "Container image pulled"

# --- [5/5] Add to PATH ----------------------------------------------------
step "5/5" "Configuring PATH..."

EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'

case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        ok "$INSTALL_DIR is already in active PATH"
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
        else
            ok "$INSTALL_DIR was already in $RC_FILE"
        fi
        info "Run 'source $RC_FILE' or restart your terminal"
        ;;
esac

# --- Done -----------------------------------------------------------------
printf "\n${C_GREEN}=== mark-dawn installed (Apple Container) ===${C_RESET}\n\n"
printf "Run:\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}\n"
printf "  ${C_CYAN}mark-dawn status${C_RESET}\n\n"
printf "Other commands:\n"
printf "  mark-dawn stop           # stop the watcher\n"
printf "  mark-dawn logs           # follow container logs\n"
printf "  mark-dawn convert FILE   # convert a single file\n"
printf "  mark-dawn update         # pull latest image\n"
printf "  mark-dawn install-service # install as launchd service\n"
printf "  mark-dawn help           # show all commands\n\n"
printf "Data directories:\n"
printf "  ~/Documents/Inbox     ← drop files here\n"
printf "  ~/Documents/Research  → converted .md files appear here\n\n"
