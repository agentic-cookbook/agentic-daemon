#!/bin/bash
set -euo pipefail

DAEMON_LABEL="com.agentic-cookbook.daemon"
MENUBAR_LABEL="com.agentic-cookbook.menubar"
SUPPORT="$HOME/Library/Application Support/$DAEMON_LABEL"
LOGS="$HOME/Library/Logs/$DAEMON_LABEL"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_PLIST_SRC="$SCRIPT_DIR/${DAEMON_LABEL}.plist"
DAEMON_PLIST_DST="$HOME/Library/LaunchAgents/${DAEMON_LABEL}.plist"
MENUBAR_PLIST_SRC="$SCRIPT_DIR/${MENUBAR_LABEL}.plist"
MENUBAR_PLIST_DST="$HOME/Library/LaunchAgents/${MENUBAR_LABEL}.plist"
PROJECT_DIR="$SCRIPT_DIR/Apple/AgenticDaemon"
XCODEPROJ="$PROJECT_DIR/AgenticDaemon.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"

if [[ ! -d "$XCODEPROJ" ]]; then
    if command -v xcodegen >/dev/null 2>&1; then
        echo "Generating Xcode project from project.yml..."
        (cd "$PROJECT_DIR" && xcodegen generate)
    else
        echo "error: AgenticDaemon.xcodeproj not found and xcodegen is not installed." >&2
        echo "Install XcodeGen (brew install xcodegen) or commit the generated project." >&2
        exit 1
    fi
fi

echo "Building agentic-daemon and AgenticMenuBar (Release)..."
xcodebuild \
    -project "$XCODEPROJ" \
    -scheme AgenticDaemon \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -quiet \
    build

BIN_PATH="$BUILD_DIR/Build/Products/Release"
DAEMON_BINARY="$BIN_PATH/agentic-daemon"
MENUBAR_BINARY="$BIN_PATH/AgenticMenuBar"

echo "Installing..."
mkdir -p "$SUPPORT/jobs"
mkdir -p "$SUPPORT/lib/Modules"
mkdir -p "$LOGS"

# Install daemon binary
cp "$DAEMON_BINARY" "$SUPPORT/agentic-daemon"
chmod 755 "$SUPPORT/agentic-daemon"

# Install menu bar companion binary
cp "$MENUBAR_BINARY" "$SUPPORT/agentic-menubar"
chmod 755 "$SUPPORT/agentic-menubar"

# Install AgenticJobKit shared library + module for job compilation
cp "$BIN_PATH/libAgenticJobKit.dylib" "$SUPPORT/lib/"
for ext in swiftmodule swiftdoc abi.json swiftsourceinfo; do
    src="$BIN_PATH/Modules/AgenticJobKit.$ext"
    [ -f "$src" ] && cp "$src" "$SUPPORT/lib/Modules/"
done

# Install management CLI
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

# Install daemon LaunchAgent plist
sed "s|\${HOME}|$HOME|g" "$DAEMON_PLIST_SRC" > "$DAEMON_PLIST_DST"

# Install menubar LaunchAgent plist
sed "s|\${HOME}|$HOME|g" "$MENUBAR_PLIST_SRC" > "$MENUBAR_PLIST_DST"

# Unload existing agents if running
launchctl bootout "gui/$(id -u)/${DAEMON_LABEL}"  2>/dev/null || true
launchctl bootout "gui/$(id -u)/${MENUBAR_LABEL}" 2>/dev/null || true

# Load and start both agents
launchctl bootstrap "gui/$(id -u)" "$DAEMON_PLIST_DST"
launchctl bootstrap "gui/$(id -u)" "$MENUBAR_PLIST_DST"

echo ""
echo "Installed: $DAEMON_LABEL"
echo "  Binary:  $SUPPORT/agentic-daemon"
echo "  JobKit:  $SUPPORT/lib/libAgenticJobKit.dylib"
echo "  Jobs:    $SUPPORT/jobs/"
echo "  Logs:    $LOGS/"
echo "  Plist:   $DAEMON_PLIST_DST"
echo ""
echo "Installed: $MENUBAR_LABEL"
echo "  Binary:  $SUPPORT/agentic-menubar"
echo "  Plist:   $MENUBAR_PLIST_DST"
echo ""
echo "Verify:"
echo "  launchctl list | grep agentic-cookbook"
echo "  agenticd status"
