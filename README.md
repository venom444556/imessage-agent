# iMessage Agent

Send iMessage instructions from your phone to a Mac running [Claude Code](https://docs.anthropic.com/en/docs/claude-code). The Mac executes them and replies with the result — all through iMessage.

## How it works

```
┌──────────┐   iMessage    ┌──────────────┐   stdin    ┌─────────────┐
│  iPhone   │ ───────────▶ │  Mac Mini     │ ────────▶ │ Claude Code │
│           │ ◀─────────── │  (agent.sh)   │ ◀──────── │ (--print)   │
└──────────┘   iMessage    └──────────────┘   stdout   └─────────────┘
```

1. A compiled Swift binary (`message-reader`) polls the macOS Messages SQLite database every 5 seconds for new **iMessage-only** messages from your authorized phone number. SMS and RCS are rejected.
2. When a new message is found, the agent script passes it to `claude --print` for execution. By default, Claude Code runs in **normal mode** with its built-in safety checks. Prefix a message with `!sudo` to escalate to `--dangerously-skip-permissions` for unrestricted execution.
3. Claude Code's output is sent back to you via iMessage using AppleScript automation.

The agent runs as a macOS LaunchAgent — it starts on login, restarts on crash, and survives reboots.

## Why this over Claude Code's built-in remote features

Claude Code has a terminal interface. It's great when you're at a desk. This is for when you're not.

- **Zero app switching.** You're already in iMessage. No browser, no terminal app, no SSH client. Text a command, get a result. It fits into the same flow as texting a coworker.
- **Works from anywhere with cell signal.** No VPN, no SSH tunnel, no port forwarding. iMessage handles the transport — E2E encrypted, works on cellular, works on airplane Wi-Fi.
- **Full Mac access, not just a shell.** Because Claude Code is the executor (not a raw shell), you get natural language instructions. "Check if CI is passing" works. "Summarize my unread email" works. "Find that file I was working on yesterday" works. You don't have to remember exact commands on a phone keyboard.
- **Persistent and hands-off.** It's a LaunchAgent. You don't start it, you don't manage it, you don't think about it. The Mac is always listening. Send a text at 2am and the response is waiting when you look at your phone.
- **Integrates with everything Claude Code touches.** Gmail, Notion, GitHub, Playwright, Figma — whatever MCP servers you've configured. It's not a limited remote shell. It's your entire Claude Code environment, reachable by text.

The closest comparison is SSH + tmux, but that requires a terminal app, exact commands, and managing connections. This is "text your Mac in English and it does the thing."

## Prerequisites

- **macOS 14+** (tested on macOS 26 Tahoe)
- **iMessage signed in** on the Mac (Messages.app with an active iCloud/Apple ID)
- **Claude Code CLI** installed and on PATH (`npm install -g @anthropic-ai/claude-code`)
- **Xcode Command Line Tools** (`xcode-select --install`) for Swift compilation
- **Python 3** (ships with macOS)

## Setup

### 1. Clone and configure

```bash
git clone git@github.com:venom444556/imessage-agent.git
cd imessage-agent
cp config.env.example config.env
```

Edit `config.env` with your values:

```env
# Your phone number (the one you'll text FROM)
AUTHORIZED_HANDLE="+1XXXXXXXXXX"

# Your Mac's iMessage account ID
IMESSAGE_ACCOUNT="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
```

**Finding your iMessage account ID:**

```bash
osascript -e 'tell application "Messages" to get id of every account'
```

This returns multiple account IDs. To find the right one, check which account your chat uses:

```bash
osascript -e '
tell application "Messages"
    set c to chat id "any;-;+1XXXXXXXXXX"
    set a to account of c
    get id of a
end tell'
```

Replace `+1XXXXXXXXXX` with your phone number.

### 2. Run setup

```bash
chmod +x setup.sh agent.sh
./setup.sh
```

The setup script will:
1. Compile the Swift message reader
2. Test database access (and prompt you to grant Full Disk Access if needed)
3. Install and start the LaunchAgent

### 3. Grant Full Disk Access (first time only)

macOS TCC (Transparency, Consent, and Control) blocks all processes from reading `~/Library/Messages/chat.db` unless explicitly granted Full Disk Access. The setup script will open System Settings for you.

1. Go to **System Settings > Privacy & Security > Full Disk Access**
2. Click **+**
3. Press **Cmd+Shift+G** and paste the path to `message-reader` (shown in the setup output)
4. Toggle it **on**
5. Run `./setup.sh` again

### 4. Verify

Send a text from your phone to your Mac's iMessage account:

```
!ping
```

You should receive `Pong!` back within a few seconds.

## Usage

Send any iMessage to your Mac. The agent interprets it as a Claude Code instruction and replies with the result.

**Examples:**

| You send | What happens |
|---|---|
| `List all running Docker containers` | Runs via Claude Code in **normal mode** (safe), replies with output |
| `What's the disk usage on this machine?` | Claude Code checks and replies |
| `!sudo Delete all .tmp files in /var` | Runs via Claude Code with **elevated privileges** (no safety checks) |
| `!sudo Reset the postgres database` | Elevated — Claude executes without confirmation prompts |
| `!ping` | Agent replies `Pong!` (no Claude involved) |
| `!status` | Agent replies with PID, uptime, and state |
| `!stop` | Agent shuts down gracefully |

### Privilege levels

By default, instructions run in **normal mode** — Claude Code applies its own safety checks and will refuse or warn on destructive operations (deleting files, dropping databases, force-pushing, etc.).

Prefix with `!sudo` to run in **elevated mode** — Claude Code runs with `--dangerously-skip-permissions`, executing any instruction without guardrails. Use this only when you explicitly need destructive or unrestricted operations.

## Architecture

```
imessage-agent/                        # This repo
├── src/
│   └── MessageReader.swift            # Swift binary — reads Messages SQLite DB
├── home-agent/                        # Template — copied to ~/home-agent on setup
│   ├── CLAUDE.md                      # Agent persona and response guidelines
│   └── .claude/
│       └── settings.json              # Permissions and MCP server access
├── agent.sh                           # Main loop — polls, dispatches, replies
├── setup.sh                           # One-time setup — compile, permissions, LaunchAgent
├── config.env.example                 # Configuration template
├── config.env                         # Your configuration (git-ignored)
├── LICENSE                            # MIT
└── .gitignore
```

### The home-agent directory

The setup script copies `home-agent/` to `~/home-agent` (or wherever `HOME_AGENT_DIR` points). The agent runs Claude Code with `--project-dir ~/home-agent`. This directory contains:

- **`CLAUDE.md`** — Tells Claude it's running as a headless home agent, to keep responses concise and mobile-readable, and to never output secrets (since responses go over iMessage).
- **`.claude/settings.json`** — Pre-approves permissions for tools so Claude can execute without interactive prompts. The template includes filesystem, shell, and web access. Add your MCP server permissions here (Gmail, Notion, GitHub, etc.).

To add or remove capabilities, edit `~/home-agent/.claude/settings.json`. The global `~/.claude/.mcp.json` and plugin configs are inherited automatically.

### Why Swift for the reader?

macOS protects `~/Library/Messages/chat.db` with TCC (Transparency, Consent, and Control). No process can read it without Full Disk Access — not `sqlite3`, not Python, not even `osascript`. A compiled Swift binary gets its own TCC entry, so granting it FDA doesn't escalate privileges for anything else on the system.

### Why AppleScript for sending?

The Messages.app AppleScript interface still supports `send` commands. This goes through Apple Events (inter-process communication), not the database, so it works without FDA. Reading messages via AppleScript was removed in recent macOS versions, which is why the reader uses the database directly.

### Why not Shortcuts?

macOS Shortcuts can trigger on incoming messages, but Shortcuts cannot be created programmatically via the CLI — only run. This solution is fully automatable with no GUI interaction required after the one-time FDA grant.

## Security model

### Defense in depth

This system has three security layers. Each one narrows the attack surface independently.

**Layer 1: iMessage-only (transport authentication)**

The database query filters on `m.service = 'iMessage'`, rejecting SMS and RCS messages at the query level. This is the most important layer. SMS caller ID is trivially spoofable — there are commercial services that let anyone send an SMS "from" any number for a few dollars. iMessage is fundamentally different:

- Messages are E2E encrypted using per-device keys
- Sender identity is authenticated through Apple's Identity Service (IDS)
- Each device registers with Apple using device-specific certificates tied to the sender's Apple ID
- The `service` column in `chat.db` is set by the Messages framework at delivery time based on the actual transport used — it cannot be forged by the sender

To send an iMessage "from" your number, an attacker would need to compromise your Apple ID and register a device against it. SMS spoofing is a $5 commodity service. iMessage spoofing is an Apple ID takeover.

**Layer 2: Single authorized handle (identity pinning)**

The `AUTHORIZED_HANDLE` in `config.env` is the only phone number the agent will read from. All other messages — from any other number, from any other Apple ID — are filtered out at the SQL query level before the agent script ever sees them. This is not a regex or application-level check; it's a `WHERE` clause. Messages from unauthorized senders never enter the processing pipeline.

**Layer 3: Privilege separation (blast radius control)**

By default, instructions run in Claude Code's normal mode, which applies its own safety checks and refuses destructive operations (deleting files, dropping databases, force-pushing, etc.). Only messages explicitly prefixed with `!sudo` run with `--dangerously-skip-permissions`.

If an attacker somehow got through layers 1 and 2, they could ask Claude to read files or run queries, but they could not execute destructive commands. Escalation to `!sudo` requires knowing the prefix exists and using it — it's not the default.

### Realistic threat assessment

The only scenario where this system is compromised is an **Apple ID takeover** — an attacker who has your Apple ID credentials, has passed 2FA, and has registered a device to your account. At that point, they can send iMessages as you.

But if someone has your Apple ID, they also have:
- Your iCloud Keychain (every saved password)
- Your iCloud Drive (every synced document)
- Your Photos library
- Your email (if using iCloud Mail)
- Find My (physical location of every device)
- The ability to remotely wipe your devices

A compromised Apple ID is a total-compromise scenario. The iMessage agent is the least of your concerns. Secure your Apple ID (strong password, hardware security key for 2FA, recovery key) and you've secured this agent as a side effect.

### Additional safeguards

- **Execution timeout.** Instructions that run longer than 5 minutes (configurable via `EXEC_TIMEOUT`) are killed. This prevents a malformed or adversarial prompt from hanging the agent indefinitely.
- **No secrets in responses.** The `CLAUDE.md` in `~/home-agent` instructs Claude to never output API keys, passwords, or tokens in responses, since they're delivered over iMessage.
- **The message-reader binary has Full Disk Access.** It can read any file on the system, but the binary is a simple read-only SQLite reader with no network access and no write operations. The source is in `src/MessageReader.swift` — it's 90 lines, fully auditable.
- **Messages are not stored.** Processed messages are tracked by row ID only. The message text is not persisted anywhere except the macOS Messages database and the agent log.

## Troubleshooting

**Agent won't start:**
```bash
# Check logs
cat agent.log
cat stderr.log

# Check if LaunchAgent is loaded
launchctl print gui/$(id -u)/com.imessage-agent
```

**"Cannot open Messages database":**
- The message-reader binary needs Full Disk Access. Re-run `./setup.sh`.

**Messages not being received:**
- Verify iMessage is signed in: open Messages.app and check Settings > iMessage
- Verify the account ID in config.env matches your iMessage account
- Check that you're texting the correct Apple ID / phone number associated with this Mac

**Claude CLI not found:**
- Ensure `claude` is on your PATH. Add the correct path to the `PATH` in `config.env` or in the generated LaunchAgent plist.

## Uninstall

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.imessage-agent.plist
rm ~/Library/LaunchAgents/com.imessage-agent.plist
# Optionally remove Full Disk Access for message-reader in System Settings
```

## License

MIT
