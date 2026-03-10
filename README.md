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

## Prerequisites

- **macOS 14+** (tested on macOS 26 Tahoe)
- **iMessage signed in** on the Mac (Messages.app with an active iCloud/Apple ID)
- **Claude Code CLI** installed and on PATH (`npm install -g @anthropic-ai/claude-code`)
- **Xcode Command Line Tools** (`xcode-select --install`) for Swift compilation
- **Python 3** (ships with macOS)

## Setup

### 1. Clone and configure

```bash
git clone <your-repo-url>
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
├── agent.sh                           # Main loop — polls, dispatches, replies
├── setup.sh                           # One-time setup — compile, permissions, LaunchAgent
├── config.env.example                 # Configuration template
├── config.env                         # Your configuration (git-ignored)
└── .gitignore

~/home-agent/                          # Claude Code project directory (separate)
├── CLAUDE.md                          # Agent persona and response guidelines
└── .claude/
    └── settings.json                  # Permissions and MCP server access
```

### The home-agent directory

The agent runs Claude Code with `--project-dir ~/home-agent`. This directory contains:

- **`CLAUDE.md`** — Tells Claude it's running as a headless home agent, to keep responses concise and mobile-readable, and to never output secrets (since responses go over iMessage).
- **`.claude/settings.json`** — Pre-approves permissions for all tools and MCP servers so Claude can execute without interactive prompts. This is where you control what Claude has access to: Gmail, Notion, GitHub, Playwright, StoryFlow, Figma, web search, filesystem, and shell.

To add or remove capabilities, edit `~/home-agent/.claude/settings.json`. The global `~/.claude/.mcp.json` and plugin configs are inherited automatically.

### Why Swift for the reader?

macOS protects `~/Library/Messages/chat.db` with TCC (Transparency, Consent, and Control). No process can read it without Full Disk Access — not `sqlite3`, not Python, not even `osascript`. A compiled Swift binary gets its own TCC entry, so granting it FDA doesn't escalate privileges for anything else on the system.

### Why AppleScript for sending?

The Messages.app AppleScript interface still supports `send` commands. This goes through Apple Events (inter-process communication), not the database, so it works without FDA. Reading messages via AppleScript was removed in recent macOS versions, which is why the reader uses the database directly.

### Why not Shortcuts?

macOS Shortcuts can trigger on incoming messages, but Shortcuts cannot be created programmatically via the CLI — only run. This solution is fully automatable with no GUI interaction required after the one-time FDA grant.

## Security considerations

- **iMessage-only.** The database query filters on `m.service = 'iMessage'`, rejecting SMS and RCS messages entirely. This is critical — SMS caller ID is trivially spoofable with off-the-shelf services. iMessage messages are end-to-end encrypted and authenticated through Apple's push notification infrastructure, tied to the sender's Apple ID and device certificates. An attacker cannot spoof an iMessage from your number without compromising your Apple ID.
- **Only your phone number is processed.** The `AUTHORIZED_HANDLE` in `config.env` is the only number the agent will read and respond to. All other messages are ignored at the database query level.
- **Privilege separation.** By default, instructions run in Claude Code's normal mode, which applies its own safety checks and refuses destructive operations. Only messages prefixed with `!sudo` run with `--dangerously-skip-permissions`. This limits the blast radius if an attacker somehow gets an iMessage through — they can read and query, but can't delete, overwrite, or execute destructive commands without the explicit escalation prefix.
- **The message-reader binary has Full Disk Access.** It can read any file on the system. The binary is a simple SQLite reader with no network access and no write operations — it only reads the Messages database.
- **Messages are not stored.** Processed messages are tracked by row ID only. The message text is not persisted anywhere except the macOS Messages database and the agent log.
- **No secrets in responses.** The CLAUDE.md in `~/home-agent` instructs Claude to never output API keys, passwords, or tokens in responses, since they're delivered over iMessage.

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
