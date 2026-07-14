#!/bin/bash
# ============================================================================
# mark-dawn macOS installer — Apple Container (macOS 26+)
# ============================================================================
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main"
LAUNCHER_URL="$REPO_URL/libexec/mark-dawn-container"
IMAGE="${MARK_DAWN_IMAGE:-docker.io/kirijin/mark-dawn:latest}"
INSTALL_DIR="$HOME/.local/bin"
LAUNCHER_PATH="$INSTALL_DIR/mark-dawn"
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --langs)        ARG_LANGS="$2"; shift 2 ;;
        --data-dir)     ARG_DATA_DIR="$2"; shift 2 ;;
        --uninstall)    ARG_UNINSTALL=true; shift ;;
        --force)        ARG_FORCE=true; shift ;;
        --help|-h)      ARG_HELP=true; shift ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

if $ARG_HELP; then
    cat <<EOH
mark-dawn macOS installer (26+, Apple Container) — usage:

  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install-macos-container.sh | bash

Options:
  --langs LANG1+LANG2  OCR languages (set via env var at runtime; for reference)
  --data-dir PATH      Data directory (default: ~/Documents)
  --force              Force re-pull image
  --uninstall          Remove launcher and config
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
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        ok "Removed config"
    fi
    clear_state
    info "Data directories preserved. To remove container image:"
    info "  container rm dock://$(echo "$IMAGE" | sed 's|docker.io/||' | sed 's/:latest//' | awk '{print $0":latest"}')"
    printf "\n${C_GREEN}Uninstall complete.${C_RESET}\n"
    exit 0
fi

# --- Banner ------------------------------------------------------------------
printf "\n${C_CYAN}${C_BOLD}=== mark-dawn installer — macOS (Apple Container) v${VERSION} ===${C_RESET}\n\n"

# --- [1/5] macOS version check -----------------------------------------------
step "1/5" "Checking macOS version..."
if ! command -v sw_vers &>/dev/null; then
    fail "Not macOS."
fi
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "0")
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d'.' -f1)
if [[ "$MACOS_MAJOR" -lt 26 ]] && ! $ARG_FORCE; then
    info "macOS pre-26 detected. Apple Container requires macOS 26+."
    info "Use the brew+venv installer instead:"
    info "  curl -fsSL $REPO_URL/install-macos-brew.sh | bash"
    info "Continuing anyway (--force)."
fi
ok "macOS $MACOS_VER ($([ "$MACOS_MAJOR" -ge 26 ] && echo "Apple Container ready" || echo "pre-26 — container may not be available"))"

# --- [2/5] Check container CLI -----------------------------------------------
step "2/5" "Checking container CLI..."
if command -v container &>/dev/null; then
    info "Apple Container CLI found"
    CONTAINER_CMD="container"
elif command -v podman &>/dev/null; then
    warn "Apple Container not found. Fallback to podman (heavier)."
    CONTAINER_CMD="podman"
else
    fail "No container runtime found. Install Apple Container or podman first."
fi
ok "Container: $CONTAINER_CMD"

# --- Reinstall detection ----------------------------------------------------
load_state
IS_REINSTALL=false
if [[ -f "$LAUNCHER_PATH" ]] && [[ -f "$STATE_FILE" ]] && [[ -n "$STATE_VERSION" ]]; then
    IS_REINSTALL=true
fi

if $IS_REINSTALL && ! $ARG_FORCE; then
    info "Existing installation detected (v${STATE_VERSION})"
    if [[ -z "$ARG_LANGS" ]] && [[ -n "${STATE_LANGS:-}" ]]; then
        ARG_LANGS="$STATE_LANGS"
        ok "Using previous language config: $ARG_LANGS"
    fi
fi

# --- [3/5] Configure OCR languages -------------------------------------------
step "3/5" "Configuring OCR languages..."
if [[ -n "$ARG_LANGS" ]]; then
    ok "Languages: $ARG_LANGS (from flag/config)"
elif $IS_REINSTALL && [[ -n "${STATE_LANGS:-}" ]]; then
    ARG_LANGS="$STATE_LANGS"
    ok "Languages: $ARG_LANGS (preserved from previous install)"
elif [ -t 0 ]; then
    prompt_langs "OCR languages (set at runtime via MARK_DAWN_LANGS)"
else
    ARG_LANGS="$DEFAULT_LANGS"
    info "Languages: $ARG_LANGS (default, settable at runtime)"
fi

# --- [4/5] Pull container image ----------------------------------------------
step "4/5" "Pulling container image: $IMAGE..."
if $IS_REINSTALL && ! $ARG_FORCE; then
    # Quick check — does the image exist locally?
    if $CONTAINER_CMD images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qF "$IMAGE" 2>/dev/null; then
        ok "Image already cached locally"
        info "Use --force to re-pull"
    else
        info "Image not cached — pulling..."
        $CONTAINER_CMD pull "$IMAGE" 2>&1 | tail -3 || {
            fail "Failed to pull $IMAGE. Check network or runtime."
        }
        ok "Image pulled"
    fi
else
    $CONTAINER_CMD pull "$IMAGE" 2>&1 | tail -3 || {
        fail "Failed to pull $IMAGE. Check network or runtime."
    }
    ok "Image pulled"
fi

# --- [5/5] Install launcher --------------------------------------------------
step "5/5" "Installing launcher to ${LAUNCHER_PATH}..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

if command -v curl &>/dev/null; then
    curl -fsSL "$LAUNCHER_URL" -o "$LAUNCHER_PATH.tmp" || fail "Download failed"
elif command -v wget &>/dev/null; then
    wget -qO "$LAUNCHER_PATH.tmp" "$LAUNCHER_URL" || fail "Download failed"
else
    fail "Neither curl nor wget found."
fi

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
cat > "$CONFIG_FILE" <<EOF
# mark-dawn configuration — generated $(date)
data_dir="$DATA_DIR"
langs="$ARG_LANGS"
image="$IMAGE"
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
    *":$INSTALL_DIR:"*) ok "$INSTALL_DIR already in PATH" ;;
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
            ok "Added $INSTALL_DIR to $RC"
        fi
        info "Run 'source $RC', then: mark-dawn start"
        ;;
esac

# --- Verification ------------------------------------------------------------
printf "\n${C_YELLOW}Verification:${C_RESET}\n"
VFAIL=0
[[ -x "$LAUNCHER_PATH" ]] && ok "Launcher executable" || { warn "Launcher missing"; VFAIL=1; }
[[ -f "$CONFIG_FILE" ]] && ok "Config present" || { warn "Config missing"; VFAIL=1; }
$CONTAINER_CMD images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qF "$IMAGE" && ok "Image cached" || warn "Image not cached"

# --- Done --------------------------------------------------------------------
printf "\n${C_GREEN}${C_BOLD}=== mark-dawn installed ===${C_RESET}\n\n"
printf "  ${C_CYAN}mark-dawn start${C_RESET}      # start background watcher\n"
printf "  ${C_CYAN}mark-dawn status${C_RESET}     # check status\n"
printf "  ${C_CYAN}mark-dawn install-service${C_RESET}  # launchd auto-start\n\n"
printf "  Image:    ${IMAGE}\n"
printf "  Inbox:    ${DATA_DIR}/Inbox\n"
printf "  Research: ${DATA_DIR}/Research\n"
printf "  Languages: ${ARG_LANGS} (at runtime via MARK_DAWN_LANGS)\n"
printf "  Launcher: ${LAUNCHER_PATH}\n\n"
