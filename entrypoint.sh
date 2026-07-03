#!/bin/bash
set -e

# Создаём рабочие директории (на случай если не смонтированы)
mkdir -p /data/Inbox /data/Research /data/Inbox_Failed

case "${1:-}" in
    watcher)
        exec python /usr/local/bin/watcher.py
        ;;
    convert)
        shift
        [ -z "$1" ] && { echo "Usage: entrypoint.sh convert FILE"; exit 1; }
        exec python /usr/local/bin/convert_pdf.py "$1"
        ;;
    *)
        exec "$@"
        ;;
esac
