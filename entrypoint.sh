#!/bin/bash
set -e

# Guarantee a writable temp directory for Ghostscript/Tesseract
mkdir -p /workspace/tmp
export TMPDIR=/workspace/tmp
export TEMP=/workspace/tmp
export TMP=/workspace/tmp

mkdir -p /data/Inbox /data/Research /data/Inbox_Failed

case "${1:-}" in
  watcher) exec python /usr/local/bin/watcher.py ;;
  convert) shift; exec python /usr/local/bin/convert_pdf.py "$@" ;;
  *) exec "$@" ;;
esac
