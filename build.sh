#!/bin/zsh
# Собирает BattBar.app в ~/Applications и запускает его.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/BattBar.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BattBar</string>
  <key>CFBundleIdentifier</key><string>local.battbar</string>
  <key>CFBundleExecutable</key><string>BattBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
swiftc -O main.swift -o "$APP/Contents/MacOS/BattBar" -framework AppKit -framework IOKit
codesign --force -s - "$APP"
pkill -x BattBar 2>/dev/null || true
sleep 1; open "$APP"
echo "OK: $APP"
