#!/bin/bash
# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT
set -euo pipefail
[[ -n "${MARK_DAWN_DEBUG:-}" ]] && set -x

# ============================================================================
# mark-dawn — Universal Document → Markdown/DOCX Pipeline
# Linux container edition (podman/docker)
# macOS delegates to the native launcher installed by install-macos*.sh
# ============================================================================

# --- macOS guard: delegate to native launcher if installed --------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
    # Check for macOS-native launcher installed by the macOS installer
    for candidate in \
        "$HOME/.local/bin/mark-dawn" \
        "/opt/mark-dawn/bin/mark-dawn" \
        "/usr/local/bin/mark-dawn"; do
        if [[ -x "$candidate" ]] && [[ "$(basename "$(readlink "$candidate" 2>/dev/null || echo "$candidate")")" != "mark-dawn.sh" ]]; then
            exec "$candidate" "$@"
        fi
    done
    echo "ERROR: mark-dawn is a native macOS tool on this platform."
    echo "Install it with:"
    echo "  curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/install.sh | bash"
    echo ""
    echo "This script ($0) is the Linux container launcher."
    exit 1
fi

IMAGE="${MARK_DAWN_IMAGE:-docker.io/kirijin/mark-dawn:latest}"
DATA_DIR="${MARK_DAWN_DATA_DIR:-${HOME}/Documents}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mark-dawn"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_DIR="$DATA_DIR/.logs"
LOG_FILE="$LOG_DIR/mark-dawn.log"

mkdir -p "$LOG_DIR" "$CONFIG_DIR"

# shellcheck disable=SC1090  # dynamic config source by design
# --- Config helpers ----------------------------------------------------------
load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    IMAGE="${MARK_DAWN_IMAGE:-${image:-$IMAGE}}"
    DATA_DIR="${MARK_DAWN_DATA_DIR:-${data_dir:-$DATA_DIR}}"
    LANGS="${MARK_DAWN_LANGS:-${langs:-eng+rus+fra+deu+chi_sim+jpn}}"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# mark-dawn configuration — generated $(date)
image="$IMAGE"
data_dir="$DATA_DIR"
langs="$LANGS"
EOF
    chmod 600 "$CONFIG_FILE"
}

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err() { echo "$*" >&2; }

# --- Runtime detection -------------------------------------------------------
detect_runtime() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else
        err "Error: neither podman nor docker found"
        err "Install with: sudo dnf install podman  # Fedora"
        err "             sudo apt install podman   # Debian/Ubuntu"
        exit 1
    fi
}

# --- Container helpers -------------------------------------------------------
RUNTIME=$(detect_runtime)
volumes() { echo "-v $DATA_DIR/Inbox:/data/Inbox:Z -v $DATA_DIR/Research:/data/Research:Z -v $DATA_DIR/Inbox_Failed:/data/Inbox_Failed:Z"; }

# The pipeline reads these inside the container; without them watcher/convert
# fall back to $HOME/Documents (root) which is not volume-mounted.
container_env() {
    echo "-e MARK_DAWN_INBOX_DIR=/data/Inbox -e MARK_DAWN_OUT_DIR=/data/Research -e MARK_DAWN_FAILED_DIR=/data/Inbox_Failed"
}

pull_image() {
    if ! $RUNTIME pull "$IMAGE" 2>/dev/null; then
        if $RUNTIME image exists "$IMAGE" 2>/dev/null; then
            log "Using cached image"
        else
            err "Error: could not pull $IMAGE and no local copy exists"
            err "Check your network connection and the MARK_DAWN_IMAGE setting."
            exit 1
        fi
    fi
}

ensure_dirs() {
    mkdir -p "$DATA_DIR/Inbox" "$DATA_DIR/Research" "$DATA_DIR/Inbox_Failed" \
             "$DATA_DIR/Inbox/2md" "$DATA_DIR/Inbox/2docx"
    [[ ! -L "$DATA_DIR/Research/Inbox" ]] && ln -sfn "$DATA_DIR/Inbox" "$DATA_DIR/Research/Inbox" 2>/dev/null || true
}

# --- Commands -----------------------------------------------------------------
cmd_start() {
    ensure_dirs
    # Don't double-start: neither a manual container nor the systemd service.
    if $RUNTIME ps --filter name=mark-dawn --format "{{.Names}}" 2>/dev/null | grep -qx "mark-dawn"; then
        log "Watcher already running"
        exit 0
    fi
    if command -v systemctl &>/dev/null && systemctl --user is-active --quiet mark-dawn.service 2>/dev/null; then
        log "Watcher already running as the mark-dawn systemd service"
        exit 0
    fi
    pull_image
    local target="${1:-watcher}"

    log "Starting mark-dawn ($target)..."
    # shellcheck disable=SC2046  # volumes()/container_env() emit multi-arg flags
    $RUNTIME run -d --name mark-dawn --restart unless-stopped \
        $(volumes) \
        $(container_env) \
        -e "MARK_DAWN_LANGS=$LANGS" \
        "$IMAGE" "$target"
    log "✅ Watcher started"
    echo "   Inbox:    $DATA_DIR/Inbox"
    echo "   Research: $DATA_DIR/Research"
    echo "   Logs:     $RUNTIME logs -f mark-dawn"
}

cmd_stop() {
    log "Stopping mark-dawn..."
    if command -v systemctl &>/dev/null && systemctl --user is-active --quiet mark-dawn.service 2>/dev/null; then
        systemctl --user stop mark-dawn.service
    fi
    $RUNTIME stop mark-dawn 2>/dev/null || true
    $RUNTIME rm mark-dawn 2>/dev/null || true
    log "✅ Stopped"
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start "$@"
}

cmd_convert() {
    [[ $# -eq 0 ]] && { echo "Usage: $0 convert FILE [--docx]"; exit 1; }
    local file_path; file_path="$(realpath "$1")"
    [[ ! -f "$file_path" ]] && { err "Error: file not found: $1"; exit 1; }
    shift
    local want_docx=""
    for a in "$@"; do [[ "$a" == "--docx" ]] && want_docx="--docx"; done

    log "Converting: $(basename "$file_path")"
    ensure_dirs 2>/dev/null || true
    pull_image 2>/dev/null || true
    # shellcheck disable=SC2046  # volumes()/container_env() emit multi-arg flags
    $RUNTIME run --rm \
        $(volumes) \
        $(container_env) \
        -v "$(dirname "$file_path"):/input:Z" \
        -e "MARK_DAWN_LANGS=$LANGS" \
        "$IMAGE" convert "/input/$(basename "$file_path")" $want_docx
}

cmd_logs() {
    $RUNTIME logs -f mark-dawn
}

cmd_status() {
    echo "Runtime:  $RUNTIME"
    echo "Image:    $IMAGE"
    echo "Data:     $DATA_DIR"
    echo "Config:   $CONFIG_FILE"
    echo "Log:      $LOG_FILE"
    echo "Languages: $LANGS"
    echo ""
    $RUNTIME ps --filter name=mark-dawn --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    echo ""
    echo "Inbox contents (newest first):"
    list_or_empty "$DATA_DIR/Inbox"
    echo "Research contents (newest first):"
    list_or_empty "$DATA_DIR/Research"
}

list_or_empty() {
    local d="$1"
    if [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
        ls -1t "$d" | head -5
    else
        echo "  (empty)"
    fi
}

cmd_update() {
    log "Updating mark-dawn image..."
    $RUNTIME pull "$IMAGE"
    cmd_restart
    log "✅ Updated to latest image"
}

cmd_install_systemd() {
    ensure_dirs
    local unit="$HOME/.config/systemd/user/mark-dawn.service"
    mkdir -p "$(dirname "$unit")"
    # Foreground `podman run --rm` so systemd tracks the watcher process
    # directly (no -d, which would make systemd think the unit exited).
    # Same container name as `start` — the running checks in cmd_start/
    # cmd_stop prevent a manual container and the service from doubling up.
    cat > "$unit" <<EOF
[Unit]
Description=mark-dawn Document Converter
After=local-fs.target

[Service]
Type=simple
Restart=always
RestartSec=10
Environment=MARK_DAWN_LANGS=$LANGS
Environment=MARK_DAWN_INBOX_DIR=/data/Inbox
Environment=MARK_DAWN_OUT_DIR=/data/Research
Environment=MARK_DAWN_FAILED_DIR=/data/Inbox_Failed
ExecStart=$(command -v $RUNTIME) run --rm --name mark-dawn \
    $(volumes) $IMAGE watcher
ExecStop=$(command -v $RUNTIME) stop -t 10 mark-dawn

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now mark-dawn.service
    log "✅ Service installed and started"
    echo "   Status: systemctl --user status mark-dawn"
}

cmd_uninstall() {
    cmd_stop
    systemctl --user disable --now mark-dawn.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/mark-dawn.service"
    systemctl --user daemon-reload
    log "✅ Uninstalled"
}

cmd_config() {
    case "${1:-show}" in
        show)
            echo "Current config:"
            echo "  image:    $IMAGE"
            echo "  data_dir: $DATA_DIR"
            echo "  langs:    $LANGS"
            echo "  runtime:  $RUNTIME"
            echo "  config:   $CONFIG_FILE"
            ;;
        set)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --image) IMAGE="$2"; shift 2;;
                    --data-dir) DATA_DIR="$2"; shift 2;;
                    --langs) LANGS="$2"; shift 2;;
                    *) err "Unknown config key: $1"; exit 1;;
                esac
            done
            save_config
            log "✅ Config saved"
            cmd_config show
            ;;
        *) err "Usage: $0 config {show|set [--image X] [--data-dir X] [--langs X]}"; exit 1;;
    esac
}

cmd_menu() {
    while true; do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║         mark-dawn — menu             ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  1) Start watcher                    ║"
        echo "║  2) Stop watcher                     ║"
        echo "║  3) Restart watcher                  ║"
        echo "║  4) Convert a file                   ║"
        echo "║  5) View logs                        ║"
        echo "║  6) Status                           ║"
        echo "║  7) Update image                     ║"
        echo "║  8) Install systemd service          ║"
        echo "║  9) Uninstall                        ║"
        echo "║  c) Config                           ║"
        echo "║  q) Quit                             ║"
        echo "╚══════════════════════════════════════╝"
        read -rp "Choose [1-9/c/q]: " ch
        case "$ch" in
            1) cmd_start;;
            2) cmd_stop;;
            3) cmd_restart;;
            4) read -rp "File path: " fp; cmd_convert "$fp";;
            5) cmd_logs;;
            6) cmd_status;;
            7) cmd_update;;
            8) cmd_install_systemd;;
            9) cmd_uninstall;;
            c) cmd_config show;;
            q) echo "Bye."; exit 0;;
            *) echo "Invalid choice";;
        esac
    done
}

# --- Main --------------------------------------------------------------------
load_config

case "${1:-}" in
    start)      shift; cmd_start "$@";;
    stop)       cmd_stop;;
    restart)    shift; cmd_restart "$@";;
    convert)    shift; cmd_convert "$@";;
    logs)       cmd_logs;;
    status)     cmd_status;;
    update)     cmd_update;;
    install-systemd) cmd_install_systemd;;
    uninstall)  cmd_uninstall;;
    config)     shift; cmd_config "$@";;
    menu|--menu|-i) cmd_menu;;
    help|--help|-h|"")
        cat <<EOF
mark-dawn — Universal Document → Markdown/DOCX Pipeline (Linux)

Usage: $0 {command} [options]

Commands:
  start               Start background watcher
  stop                Stop background watcher
  restart             Restart watcher
  convert FILE [--docx]  Convert single file (optionally to docx)
  logs                Follow container logs
  status              Show container and directory status
  update              Pull latest image and restart
  install-systemd     Install as systemd user service
  uninstall           Remove container and systemd service
  config {show|set}   View or change configuration
  menu                Interactive numbered menu
  help                Show this help

Supported formats:
  PDF, DjVu, TIFF, JPEG, PNG, BMP, WebP → markdown (OCR via ocrmypdf)
  DOCX, XLSX, PPTX, HTML, CSV, RTF       → markdown (via markitdown)
  --docx flag converts markdown → DOCX  (needs pandoc in image)
  --docx is also auto-detected for files in Inbox/2docx/

Directories:
  ~/Documents/Inbox        - Drop files for auto-conversion to markdown
  ~/Documents/Inbox/2md    - Alternative inbox (same output: markdown)
  ~/Documents/Inbox/2docx  - Files here auto-convert to DOCX
  ~/Documents/Research     - Converted files appear here
  ~/Documents/Inbox_Failed - Failed conversions

Environment:
  MARK_DAWN_IMAGE       Docker image (default: $IMAGE)
  MARK_DAWN_DATA_DIR    Data directory (default: $DATA_DIR)
  MARK_DAWN_LANGS       OCR languages (default: $LANGS)

Config: $CONFIG_FILE

Examples:
  $0 menu
  $0 start
  $0 convert ~/doc.pdf
  $0 convert ~/scan.djvu --docx
EOF
        ;;
esac
