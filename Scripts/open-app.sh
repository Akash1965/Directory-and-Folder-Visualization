#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ChangeLink.app"
BIN="$ROOT/.build/arm64-apple-macosx/debug/ChangeLinkApp"

cd "$ROOT"
swift build --product ChangeLinkApp
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChangeLinkApp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Change-Link</string>
  <key>CFBundleExecutable</key><string>ChangeLinkApp</string>
  <key>CFBundleIdentifier</key><string>com.changelink.app</string>
  <key>CFBundleName</key><string>Change-Link</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
open "$APP"
echo "Opened $APP"
