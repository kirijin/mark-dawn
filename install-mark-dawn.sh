#!/bin/bash
set -euo pipefail

echo "mark-dawn Installer"
echo "==================="
echo ""

INSTALLER="$HOME/.local/bin/mark-dawn"
URL="https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.sh"

mkdir -p "$(dirname "$INSTALLER")"

echo "Downloading launcher script..."
curl -fsSL "$URL" -o "$INSTALLER"
chmod +x "$INSTALLER"

echo "✅ Installed to: $INSTALLER"
echo ""
echo "Next steps:"
echo "  1. Ensure you have podman or docker installed"
echo "  2. Run: mark-dawn start"
echo "  3. Drop files into ~/Documents/Inbox"
echo ""
echo "For systemd integration (Linux):"
echo "  mark-dawn install-systemd"
