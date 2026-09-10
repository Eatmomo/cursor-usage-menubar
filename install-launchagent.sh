#!/bin/bash
# Install LaunchAgent so Cursor usage menubar starts at login.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/cursor-usage-menubar"
LABEL="com.cursor-usage-menubar"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ ! -x "$BIN" ]]; then
  "$ROOT/build.sh"
fi

# Stop OpenCode agent if somehow still present
OLD="$HOME/Library/LaunchAgents/com.opencode-go-usage-menubar.plist"
if [[ -f "$OLD" ]]; then
  launchctl bootout "gui/$(id -u)/com.opencode-go-usage-menubar" 2>/dev/null || true
  rm -f "$OLD"
fi

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
# also kill any .app leftover
pkill -f "Cursor Usage.app/Contents/MacOS/cursor-usage-menubar" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST"
echo "running: $(pgrep -lf cursor-usage-menubar || echo '(starting…)')"
