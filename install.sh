#!/bin/bash
set -euo pipefail

LABEL="com.agentic-cookbook.daemon"
SUPPORT="$HOME/Library/Application Support/$LABEL"
LOGS="$HOME/Library/Logs/$LABEL"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PKG_DIR="$(cd "$(dirname "$0")" && pwd)/AgenticDaemon"

echo "Building agentic-daemon (release)..."
swift build -c release --package-path "$PKG_DIR"

BIN_PATH=$(swift build -c release --show-bin-path --package-path "$PKG_DIR")
BINARY="$BIN_PATH/agentic-daemon"

echo "Installing..."
mkdir -p "$SUPPORT/jobs"
mkdir -p "$SUPPORT/lib/Modules"
mkdir -p "$LOGS"

# Install daemon binary
cp "$BINARY" "$SUPPORT/agentic-daemon"
chmod 755 "$SUPPORT/agentic-daemon"

# Install AgenticJobKit shared library + module for job compilation
cp "$BIN_PATH/libAgenticJobKit.dylib" "$SUPPORT/lib/"
for ext in swiftmodule swiftdoc abi.json swiftsourceinfo; do
    src="$BIN_PATH/Modules/AgenticJobKit.$ext"
    [ -f "$src" ] && cp "$src" "$SUPPORT/lib/Modules/"
done

# Install management CLI
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/agenticd" "$SUPPORT/agenticd"
chmod 755 "$SUPPORT/agenticd"

# Symlink management CLI to /usr/local/bin for convenient access
if ! ln -sf "$SUPPORT/agenticd" /usr/local/bin/agenticd 2>/dev/null; then
    echo ""
    read -r -p "Need sudo to symlink agenticd to /usr/local/bin. Create symlink? [Y/n] " yn
    if [[ ! "$yn" =~ ^[Nn]$ ]]; then
        sudo ln -sf "$SUPPORT/agenticd" /usr/local/bin/agenticd
    else
        echo "Note: add $SUPPORT to PATH to use agenticd"
    fi
fi

# Expand $HOME in plist and install
sed "s|\${HOME}|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

# Unload any existing registration first
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
sleep 1

# Load and start the daemon
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"; then
    echo "Bootstrap failed, retrying after extended wait..."
    sleep 2
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
fi

echo ""
echo "Installed: $LABEL"
echo "  Daemon:  $SUPPORT/agentic-daemon"
echo "  JobKit:  $SUPPORT/lib/libAgenticJobKit.dylib"
echo "  Jobs:    $SUPPORT/jobs/"
echo "  Logs:    $LOGS/"
echo "  Plist:   $PLIST_DST"
echo ""
echo "Verify:"
echo "  launchctl list | grep agentic-cookbook.daemon"
echo "  agenticd status"
