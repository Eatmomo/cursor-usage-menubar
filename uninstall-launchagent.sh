#!/bin/bash
set -euo pipefail
LABEL="com.cursor-usage-menubar"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
INSTALL_DIR="$HOME/Library/Application Support/cursor-usage-menubar"
BIN="$INSTALL_DIR/cursor-usage-menubar"
ROOT="$(cd "$(dirname "$0")" && pwd)"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "$BIN" 2>/dev/null || true
pkill -f "$ROOT/cursor-usage-menubar" 2>/dev/null || true
if [[ -x "$BIN" ]]; then
  "$BIN" --unregister-login-item 2>/dev/null || true
fi
rm -rf "$INSTALL_DIR"
echo "uninstalled LaunchAgent + stopped process"
