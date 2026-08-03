# Codex assistant

[简体中文](../codex.md) · English

Menu bar → **Codex assistant**. An assistant for the local Codex CLI, structured to match the
[Claude Code assistant](claude-code.md) but **implemented separately and independently**.

**Everything comes from local files under `~/.codex` — no AI API calls, no login** (the same
exception applies: "check for the latest version" queries npm when you click it).

If Codex isn't installed (`~/.codex` doesn't exist) the menu shows a single grayed-out line.

## The menu

| Section | Contents |
|---|---|
| Status line | `N sessions · $X today (estimated)` |
| Quota | `5 hours: X used ≈ $Y · resets in Z`, and the same for the week |
| Recent sessions | Click one to resume it with `codex resume <id>` in your terminal |
| Quick resume… | Spotlight-style search panel |
| Browse sessions / usage… | Opens the center window |
| Usage report… | The center window's usage tab |
| Turn completion notifications | Notification toggle |

## Quick resume panel

Unbound by default (to avoid colliding with Claude Code's ⌃⇧Space); assign your own.

| Key | Action |
|---|---|
| Type | Search by title, project, or path |
| ↑ / ↓ | Select |
| ⏎ | Resume in the terminal |
| ⌘C | Copy the resume command |
| Esc | Close |

## The center window

Two tabs:

### Sessions

Search, resume, copy the command, delete.

### Usage

- **5-hour** and **weekly** window cards, with progress bars when a budget is set
- Reports by **day**, **project**, and **model**
- Built-in tool and MCP call statistics

Costs come from a built-in pricing table and are labeled as estimates.

### How usage is calculated

Codex `token_count` events in the rollout JSONL are aggregated into a rolling 5-hour window
and a weekly window.

Both accounting styles are handled correctly, with **no double counting**:

- Incremental (`last_token_usage`)
- Cumulative (`total_token_usage`)

The weekly window defaults to a **rolling 168 hours**, and can be switched to
**align with a fixed weekday and hour**.

## Turn completion notifications

Settings → Codex assistant → Turn completion notifications.

When enabled, Baobox writes a `notify` hook into `config.toml`. Codex calls it at the end of
every turn, and Baobox posts a system notification (**including a summary of the last
reply**). An optional sound can be played.

Turning it off leaves nothing behind in `config.toml`.

If the `notify` key is in a form this app can't edit safely, you're told to manage it by hand
rather than having it rewritten.

### Budget alerts

- **5-hour budget** and **weekly budget** (in thousands of tokens)
- Alerts once at **80%**

## Visual configuration

Settings → Codex assistant turns the three most-adjusted `config.toml` keys into controls:

| Setting | Options |
|---|---|
| Approval policy | Never ask / on request (the model decides) / trusted only (ask outside trusted commands) |
| Sandbox mode | Read-only / workspace-write / **full access (dangerous)** |
| Default model | A dropdown of common models, or type any model name Codex supports |

"Full access" carries a red warning — Codex can then read and write anything and reach the
network.

**Writes are conservative**: `config.toml` is edited line-by-line and block-by-block so
comments and unknown keys survive, and `config.toml.baobox.bak` is written before every
change. Values that can't be edited safely are detected and the corresponding control is
**disabled** rather than risking your configuration.

## Maintenance

- **Disk usage**: how much `~/.codex/sessions` occupies and how many sessions there are
- **Clean up old sessions**: removes rollout JSONL files older than N days, with
  confirmation, then reports the count and space freed
- **Version**: local `codex --version`, with a check for the latest `@openai/codex` on npm
  and a copyable upgrade command

## MCP (read-only)

Lists the `[mcp_servers.*]` entries in `config.toml` and can open the file for you to edit.
This panel **reads but never writes**.
