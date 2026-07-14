#!/bin/bash
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

pull_image() {
    $RUNTIME pull "$IMAGE" 2>/dev/null || log "Using cached image"
}

ensure_dirs() {
    mkdir -p "$DATA_DIR/Inbox" "$DATA_DIR/Research" "$DATA_DIR/Inbox_Failed" \
             "$DATA_DIR/Inbox/2md" "$DATA_DIR/Inbox/2docx"
    [[ ! -L "$DATA_DIR/Research/Inbox" ]] && ln -sfn "$DATA_DIR/Inbox" "$DATA_DIR/Research/Inbox" 2>/dev/null || true
}

# --- Commands -----------------------------------------------------------------
cmd_start() {
    ensure_dirs
    pull_image
    local target="${1:-watcher}"

    log "Starting mark-dawn ($target)..."
    $RUNTIME run -d --name mark-dawn --restart unless-stopped \
        $(volumes) \
        -e "MARK_DAWN_LANGS=$LANGS" \
        "$IMAGE" "$target"
    log "✅ Watcher started"
    echo "   Inbox:    $DATA_DIR/Inbox"
    echo "   Research: $DATA_DIR/Research"
    echo "   Logs:     $RUNTIME logs -f mark-dawn"
}

cmd_stop() {
    log "Stopping mark-dawn..."
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
    $RUNTIME run --rm \
        $(volumes) \
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
    echo "Inbox contents:"
    ls -1 "$DATA_DIR/Inbox" 2>/dev/null | head -10 || echo "  (empty)"
    echo "Research contents:"
    ls -1 "$DATA_DIR/Research" 2>/dev/null | head -10 || echo "  (empty)"
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
    cat > "$unit" <<EOF
[Unit]
Description=mark-dawn Document Converter
After=local-fs.target

[Service]
Type=simple
Restart=always
RestartSec=10
Environment=MARK_DAWN_LANGS=$LANGS
ExecStart=$(which $RUNTIME) run --rm --name mark-dawn-systemd \
    $(volumes) $IMAGE watcher
ExecStop=$(which $RUNTIME) stop mark-dawn-systemd

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
  start [2md|2docx]   Start background watcher
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
