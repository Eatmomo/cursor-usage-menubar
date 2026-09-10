#!/bin/bash
set -euo pipefail
LABEL="com.cursor-usage-menubar"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "/Volumes/2TB/娱乐/menubar/cursor-usage-menubar" 2>/dev/null || true
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$ROOT/cursor-usage-menubar" ]]; then
  "$ROOT/cursor-usage-menubar" --unregister-login-item 2>/dev/null || true
fi
echo "uninstalled LaunchAgent + stopped process"
