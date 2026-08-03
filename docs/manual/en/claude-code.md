# Claude Code assistant

[简体中文](../claude-code.md) · English

Menu bar → **Claude Code**. A menu-bar dashboard for the local Claude Code CLI.

**Everything comes from local files under `~/.claude` — no AI API calls, no login, no
network** (the one exception is "check for the latest version", which queries npm and only
runs when you click it).

If Claude Code isn't installed (`~/.claude` doesn't exist) the menu shows a single grayed-out
line and no background services start.

## The menu

| Section | Contents |
|---|---|
| Live status | Whether a session is running or waiting for you |
| Quota | `5 hours: X used ≈ $Y · resets in Z`, and the same for the week |
| Today | Today's estimated spend |
| Recent sessions | The last 5; click one to resume it in your terminal |
| Quick resume… | Opens the Spotlight-style search panel |
| Recent files… | Opens the recent files panel |
| Browse session history… | Opens the center window |
| Usage report… | The center window's usage tab |
| Today's changes… | The center window's audit tab |
| Completion / waiting notifications | Notification toggle |

> Every cost is an **estimate** based on public pricing, and labeled as such in the UI.

## Quick resume panel

Default shortcut **⌃⇧Space**. A Spotlight-style overlay: type to search session titles,
project names, or paths.

| Key | Action |
|---|---|
| Type | Search |
| ↑ / ↓ | Select |
| ⏎ | Resume in the terminal |
| ⌘C | Copy the resume command |
| Tab | **Switch between "sessions" and "files" modes** |
| Esc | Close |

### Recent files mode

The same panel in "files" mode (it also has its own shortcut, unbound by default) searches
the files Claude Code **wrote most recently**; ⏎ opens one.

Settings → Claude Code → Recent files lets you **pick which app opens each category**
(categories without a choice use the system default), and whether to include internal files
under `~/.claude`.

### Session row format

Settings → Claude Code → Session rows (quick resume panel) offers **Compact / Standard /
Detailed**, or **a custom scheme** where you tick the fields to show: project, directory
path, last active, model, context size, file size. Built-in schemes aren't editable — create
a custom one to change things.

## The center window

Shortcut unbound by default; menu → Browse session history…. Three tabs:

### Sessions

Searchable full session history (by title or project). For each row:

- **Double-click** to resume
- Right-click: resume, copy the resume command, **export to Markdown**, delete

Deleting asks for confirmation — it permanently removes that session's JSONL file.

### Usage

- **5-hour** and **weekly** window cards: tokens used, estimated cost, time to reset, plus a
  progress bar if you've set a budget
- Reports by **day**, **project**, and **model**
- **Call statistics**: skills and slash commands, MCP servers › tools, built-in tools

### Audit

Files Claude Code changed, by date: `N projects · M changes`, expandable to the individual
files, with **Reveal in Finder** on right-click.

## Notifications and hooks

Settings → Claude Code → Notifications.

Notifications need **hooks installed** first (one button on the settings page): Baobox writes
an event-reporting hook into your Claude Code configuration. "Remove hooks" takes it back out
with no leftovers.

| Setting | Notes |
|---|---|
| Completion / waiting notifications | Fires when a task finishes or Claude is waiting for you |
| Alert style | Notification only / sound / spoken |
| Sound | Pick a system sound |
| Spoken alerts | Read aloud with the system voice; the text is yours to write, `{project}` is replaced with the project name, and leaving it empty reads the notification title |
| Preview | Hear it before committing |

### Budget alerts

- **Per-window budget** (thousands of tokens) and **weekly budget**
- Alerts once at **80%**
- Optionally alerts when a quota window resets ("a new 5-hour window has started")

The weekly window supports two interpretations: leave it empty for a **rolling 7-day**
estimate, or **align it to a fixed reset time** by entering the weekday and hour (match what
Claude's `/usage` reports).

## Dangerous-command guard

Settings → Claude Code → Configuration → Dangerous-command guard.

Enabling it installs a `PreToolUse(Bash)` hook: commands matching a rule are **blocked**, and
the reason is handed back to Claude so it can try another way.

Built-in rules:

- Recursive delete of `/` (`rm -rf /`) and of the home directory (`rm -rf ~`)
- Deleting as admin (`sudo rm`)
- Force push (`git push --force`), hard reset (`git reset --hard`), force clean (`git clean -fd`)
- Dropping tables (`DROP TABLE`)
- Formatting a filesystem (`mkfs`)
- Opening all permissions recursively (`chmod -R 777`)

You can add **custom rules** (ERE regex matched against the whole command JSON line) and
restore the defaults in one click.

> The settings page says it plainly: **a blocklist stops slips, not determined evasion.**

## Visual configuration

Settings → Claude Code → Configuration turns common `settings.json` entries into controls:

| Group | Contents |
|---|---|
| Behavior | Default permission mode (default / accept edits / plan / bypass all), default model, session retention days |
| Permission rules | allow and deny lists you can edit, plus **presets** to tick: file reads, Git read-only, Git writes, package managers, build and test |
| Privacy | Disable telemetry, disable error reporting, disable non-essential network traffic |
| Commit attribution | Whether to sign commits with `Co-Authored-By: Claude` (future commits only) |
| CLAUDE.md | Lists the global file and each known project's; missing ones can be created from a built-in template |

"Bypass all confirmations" carries a red warning — Claude can then do anything without asking.

**Every write is conservative**: only our own keys are touched, unknown fields in the file
are preserved, and a `.baobox.bak` backup is written first. Choosing "follow default"
*removes* the key rather than writing a default value into your file.

## Statusline builder

Settings → Claude Code → Statusline: tick the segments you want, preview live, then
"Apply to Claude Code".

Available segments include directory, Git branch, model, context usage %, context tokens,
session cost (estimated), session duration, effort, and time. The separator is configurable.

If a non-Baobox `statusLine` is already configured you get an **explicit warning and a
confirmation** before it's replaced. It can be removed again at any time.

## MCP panel

Settings → Claude Code → MCP manages the **user-level** `mcpServers` at the top level of
`~/.claude.json`:

- Lists existing servers
- Add: name, type (stdio local command / http remote URL), command, arguments, environment
  variables
- Delete (with confirmation)

## Maintenance

Settings → Claude Code → Maintenance:

- **Disk usage**: sessions / shell snapshots / todos / other / total, plus the session file
  count
- **Clean up old sessions**: removes session files older than N days, with confirmation, then
  reports how many were deleted and how much was freed
- **Version**: local `claude --version`, with a **check for the latest npm release** and a
  **copyable upgrade command** (a failed check says so — you may be offline)
