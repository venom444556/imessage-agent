#!/bin/bash
# iMessage Agent - One-time setup
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$AGENT_DIR/com.imessage-agent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.imessage-agent.plist"

echo "=== iMessage Agent Setup ==="
echo ""

# Step 0: Check config exists
if [ ! -f "$AGENT_DIR/config.env" ]; then
    echo "  ✗ config.env not found."
    echo "    Copy config.env.example to config.env and fill in your values first."
    exit 1
fi
echo "[0/4] Config found."

# Step 1: Compile the message reader
echo "[1/4] Compiling message reader..."
swiftc -o "$AGENT_DIR/message-reader" "$AGENT_DIR/src/MessageReader.swift" -lsqlite3 2>&1
echo "  ✓ Compiled"

# Step 2: Check if message-reader can access the DB
echo "[2/4] Testing database access..."
if "$AGENT_DIR/message-reader" latest 2>/dev/null | grep -qE '^[0-9]+$'; then
    echo "  ✓ Database access OK"
else
    echo "  ✗ Cannot access Messages database."
    echo ""
    echo "  You need to grant Full Disk Access to the message-reader binary."
    echo "  Opening System Settings > Privacy & Security > Full Disk Access..."
    echo ""
    echo "  Add this file to the list:"
    echo "    $AGENT_DIR/message-reader"
    echo ""
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
    echo "  After granting access, run this setup script again."
    exit 1
fi

# Step 3: Generate the LaunchAgent plist with correct paths
echo "[3/4] Installing LaunchAgent..."
cat > "$PLIST_SRC" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.imessage-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$AGENT_DIR/agent.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$AGENT_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$AGENT_DIR/stderr.log</string>
    <key>WorkingDirectory</key>
    <string>$AGENT_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
echo "  ✓ Installed to $PLIST_DST"

# Step 4: Load and start
echo "[4/4] Starting agent..."
launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo "  ✓ Agent started"

echo ""
echo "=== Setup Complete ==="
echo "The iMessage Agent is now running and will start automatically on login."
echo ""
echo "Commands you can send via iMessage to your Mac:"
echo "  !ping   - Check if agent is alive"
echo "  !status - Get agent status"
echo "  !stop   - Shut down the agent"
echo "  Anything else - Executed as a Claude Code instruction on the Mac"
