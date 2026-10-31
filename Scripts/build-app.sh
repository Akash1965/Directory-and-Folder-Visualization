#!/bin/bash
# One-time builder: compiles Change-Link in release mode and assembles a double-clickable
# "Change-Link.app" (with its icon) in the project folder and in ~/Applications.
# Run it again after changing the source code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Change-Link"
APP="$ROOT/$NAME.app"
ICON_SRC="$ROOT/Resources/AppIcon.png"

cd "$ROOT"
echo "Building (release)…"
swift build -c release --product ChangeLinkApp
BIN="$(swift build -c release --product ChangeLinkApp --show-bin-path)/ChangeLinkApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChangeLinkApp"

# Icon: PNG -> .iconset -> .icns
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Change-Link</string>
  <key>CFBundleExecutable</key><string>ChangeLinkApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.changelink.app</string>
  <key>CFBundleName</key><string>Change-Link</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDesktopFolderUsageDescription</key><string>Change-Link monitors the folders you choose for changes.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Change-Link monitors the folders you choose for changes.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Change-Link monitors the folders you choose for changes.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will launch the bundle on Apple Silicon.
codesign --force --deep --sign - "$APP"

# Also install to ~/Applications so it shows up in Launchpad/Spotlight.
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$NAME.app"
cp -R "$APP" "$HOME/Applications/$NAME.app"
touch "$APP" "$HOME/Applications/$NAME.app"

echo ""
echo "Done. Double-click  $APP  (or find Change-Link in ~/Applications / Spotlight)."
echo "Tip: drag the icon to your Dock to keep it there."
open "$APP"
