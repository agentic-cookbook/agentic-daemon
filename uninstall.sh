#!/bin/bash
set -euo pipefail

LABEL="com.agentic-cookbook.daemon"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SUPPORT="$HOME/Library/Application Support/$LABEL"
LOGS="$HOME/Library/Logs/$LABEL"

echo "Stopping $LABEL..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

echo "Removing plist..."
rm -f "$PLIST"

echo "Removing application support..."
rm -rf "$SUPPORT"

echo "Removing symlink..."
rm -f /usr/local/bin/agd 2>/dev/null || true

echo "Remove logs? ($LOGS)"
read -r -p "[y/N] " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    rm -rf "$LOGS"
    echo "Logs removed."
else
    echo "Logs preserved."
fi

echo ""
echo "Uninstalled: $LABEL"
