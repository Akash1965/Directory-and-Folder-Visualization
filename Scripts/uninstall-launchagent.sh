#!/bin/bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.changelink.agent.plist"; launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; echo "Uninstalled ChangeLink"
