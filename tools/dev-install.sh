#!/bin/bash
# Copy this checkout into the Omarchy plugin dir and (re)load it. Dev use only.
set -euo pipefail
ID="io.github.ai-dico.auto-update"
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEST="$HOME/.config/omarchy/plugins/$ID"
[[ $(omarchy-shell lock isLocked 2>/dev/null || echo false) != true ]] || { echo "screen is locked" >&2; exit 1; }
mkdir -p "$DEST"
tar -C "$SRC" --exclude=./.git --exclude=./tools --exclude=./tests --exclude=./docs -cf - . | tar -C "$DEST" -xf -
chmod +x "$DEST/bin/"*
omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
echo "installed to $DEST"
