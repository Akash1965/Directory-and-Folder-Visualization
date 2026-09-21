#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LABEL="com.changelink.agent"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"; mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$LABEL</string><key>ProgramArguments</key><array><string>/usr/bin/env</string><string>swift</string><string>run</string><string>ChangeLinkApp</string></array><key>WorkingDirectory</key><string>$ROOT</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
PLIST
launchctl unload "$PLIST" 2>/dev/null || true; launchctl load "$PLIST"; echo "Installed $PLIST"
