#!/bin/bash
# Install LaunchAgent so Cursor usage menubar starts at login.
# 二进制和图标复制到内置盘再运行：仓库在可移动磁盘上，从那里运行每次重新编译都会弹「访问可移动宗卷」授权
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_BIN="$ROOT/cursor-usage-menubar"
INSTALL_DIR="$HOME/Library/Application Support/cursor-usage-menubar"
BIN="$INSTALL_DIR/cursor-usage-menubar"
LABEL="com.cursor-usage-menubar"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ ! -x "$SRC_BIN" || "$ROOT/main.swift" -nt "$SRC_BIN" ]]; then
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
pkill -f "$SRC_BIN" 2>/dev/null || true
# also kill any .app leftover
pkill -f "Cursor Usage.app/Contents/MacOS/cursor-usage-menubar" 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
# 先复制成新文件再 mv，不覆盖可能仍在映射中的旧二进制
cp "$SRC_BIN" "$BIN.new"
mv -f "$BIN.new" "$BIN"
cp "$ROOT/Cursor_icns.icns" "$INSTALL_DIR/Cursor_icns.icns"
"$BIN" --unregister-login-item >/dev/null 2>&1 || true

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
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $BIN"
echo "agent: $PLIST"
