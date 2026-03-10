#!/bin/bash
# iMessage Agent - Monitors incoming iMessages and executes instructions via Claude Code
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
READER="$AGENT_DIR/message-reader"
STATE_FILE="$AGENT_DIR/.last_rowid"
LOG_FILE="$AGENT_DIR/agent.log"
LOCK_FILE="$AGENT_DIR/.agent.lock"
CONFIG_FILE="$AGENT_DIR/config.env"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.env not found. Copy config.env.example to config.env and fill in your values."
    exit 1
fi
source "$CONFIG_FILE"

# Clear nested session detection so claude CLI doesn't refuse to run
unset CLAUDECODE

# Execution timeout (default: 5 minutes)
EXEC_TIMEOUT="${EXEC_TIMEOUT:-300}"

# iMessage max chunk size (leave room for overhead)
MAX_CHUNK=15000

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

send_imessage() {
    local message="$1"
    osascript -e "
        tell application \"Messages\"
            set targetBuddy to buddy \"$AUTHORIZED_HANDLE\" of account id \"$IMESSAGE_ACCOUNT\"
            send $(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))') to targetBuddy
        end tell
    " 2>>"$LOG_FILE"
}

send_long_imessage() {
    local message="$1"
    local total=${#message}

    if [ "$total" -le "$MAX_CHUNK" ]; then
        send_imessage "$message"
        return
    fi

    # Split into chunks on line boundaries where possible
    local offset=0
    local part=1
    local total_parts=$(( (total + MAX_CHUNK - 1) / MAX_CHUNK ))

    while [ "$offset" -lt "$total" ]; do
        local chunk="${message:$offset:$MAX_CHUNK}"

        # Try to break at the last newline within the chunk
        if [ "$((offset + MAX_CHUNK))" -lt "$total" ]; then
            local last_newline="${chunk%$'\n'*}"
            if [ ${#last_newline} -gt $((MAX_CHUNK / 2)) ]; then
                chunk="$last_newline"
            fi
        fi

        send_imessage "[$part/$total_parts] $chunk"
        offset=$((offset + ${#chunk}))
        part=$((part + 1))
        sleep 1  # Brief pause between chunks to maintain order
    done
}

execute_instruction() {
    local instruction="$1"
    local rowid="$2"
    local privileged="$3"  # "yes" or "no"

    log "EXECUTING [privileged=$privileged]: $instruction"

    # Send acknowledgment
    if [ "$privileged" = "yes" ]; then
        send_imessage "Got it (elevated). Working on it..."
    else
        send_imessage "Got it. Working on it..."
    fi

    # Execute via Claude CLI with timeout
    # Default: normal mode (Claude will refuse destructive operations)
    # !sudo prefix: skip permissions (full access, no guardrails)
    local result
    local exit_code=0
    local project_dir="${HOME_AGENT_DIR:-$HOME/home-agent}"
    if [ "$privileged" = "yes" ]; then
        result=$(cd "$project_dir" && perl -e "alarm $EXEC_TIMEOUT; exec @ARGV" -- claude --print --dangerously-skip-permissions "$instruction" 2>&1) || exit_code=$?
    else
        result=$(cd "$project_dir" && perl -e "alarm $EXEC_TIMEOUT; exec @ARGV" -- claude --print "$instruction" 2>&1) || exit_code=$?
    fi

    if [ "$exit_code" -eq 142 ] || [ "$exit_code" -eq 124 ]; then
        result="Timed out after ${EXEC_TIMEOUT}s. Try breaking it into smaller steps."
        log "TIMEOUT: $instruction"
    elif [ -z "$result" ]; then
        result="Command executed but produced no output."
    fi

    log "RESULT: ${result:0:200}..."

    # Send result back via iMessage (split if needed)
    send_long_imessage "$result"
}

# Ensure only one instance runs
if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(cat "$LOCK_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Agent already running (PID $existing_pid). Exiting."
        exit 1
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Initialize state - get current latest rowid so we only process NEW messages
if [ ! -f "$STATE_FILE" ]; then
    "$READER" latest > "$STATE_FILE" 2>/dev/null || echo "0" > "$STATE_FILE"
    log "Initialized. Starting from rowid $(cat "$STATE_FILE")"
fi

log "iMessage Agent started. Monitoring messages from $AUTHORIZED_HANDLE..."
send_imessage "iMessage Agent is online and monitoring. Send me instructions to execute on the Mac Mini."

# Main polling loop
while true; do
    last_rowid=$(cat "$STATE_FILE")

    # Read new messages
    new_messages=$("$READER" "$last_rowid" 2>>"$LOG_FILE") || true

    if [ -n "$new_messages" ]; then
        while IFS='|' read -r rowid text; do
            if [ -n "$text" ] && [ -n "$rowid" ]; then
                # Skip empty or system messages
                if [[ "$text" == *"￼"* ]] || [ -z "${text// /}" ]; then
                    log "Skipping non-text message (rowid: $rowid)"
                    echo "$rowid" > "$STATE_FILE"
                    continue
                fi

                # Check for control commands
                case "$text" in
                    "!stop"|"!quit"|"!exit")
                        log "Stop command received. Shutting down."
                        send_imessage "Agent shutting down."
                        echo "$rowid" > "$STATE_FILE"
                        exit 0
                        ;;
                    "!status")
                        send_imessage "Agent is running. PID: $$. Uptime: $(ps -o etime= -p $$). Last processed rowid: $last_rowid"
                        echo "$rowid" > "$STATE_FILE"
                        ;;
                    "!ping")
                        send_imessage "Pong!"
                        echo "$rowid" > "$STATE_FILE"
                        ;;
                    "!sudo "*)
                        # Elevated: strip prefix, run with --dangerously-skip-permissions
                        execute_instruction "${text#!sudo }" "$rowid" "yes"
                        echo "$rowid" > "$STATE_FILE"
                        ;;
                    *)
                        # Default: run in normal mode (Claude applies its own safety checks)
                        execute_instruction "$text" "$rowid" "no"
                        echo "$rowid" > "$STATE_FILE"
                        ;;
                esac
            fi
        done <<< "$new_messages"
    fi

    sleep "${POLL_INTERVAL:-5}"
done
