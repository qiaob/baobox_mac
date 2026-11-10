# Baobox User Manual

[简体中文](../README.md) · English

For version **0.0.8**. This manual covers every tool and every feature currently in the app.

## Contents

| Tool | What it covers |
|---|---|
| [Screenshot & recording](screenshot.md) | Smart capture, annotation, pinning, scrolling capture, on-screen OCR, recording, history |
| [Draw on Screen](screenshot.md#live-drawing) | Draw straight onto the screen; in pass-through mode the strokes stay while you keep working underneath |
| [Clipboard](clipboard.md) | History, search, paste-back, favorites, format detection and conversion, snippets, privacy and encryption |
| [Window manager](window-manager.md) | Halves, quarters, maximize, center, across displays, layout snapshots |
| [Menu bar](menubar.md) | Show or hide each menu bar icon; hidden and squeezed-out icons one click away at the top of the Baobox menu; move the Baobox icon to the right |
| [Keyboard clicking](keyboard-nav.md) | Letter-label clicking, continuous mode, keyboard scrolling |
| [Meeting](meeting.md) | Next-meeting countdown, one-click join, auto-detects meetings, local transcript, minutes and action items |
| [Subtitles & Interpreting](live-translate.md) | Live captions and translation from the mic or system audio (21 languages), AI correction, spoken translation into a call; now part of Meeting |
| [Selection assistant](selection-assistant.md) | Select text in any app → action bar: Translate, Learn, Polish, Rewrite, Natural English, Explain, Summarize |
| [Voice dictation](dictation.md) | Hold-to-talk, continuous or long dictation; the text lands at your cursor, optional AI polish, with history |
| [Focus & health](focus-health.md) | Focus timer, water / stand / 20-20-20 reminders, break screen delivered by the desktop pet |
| [Desktop pet](desktop-pet.md) | A pet on your desktop that is also Baobox's unified notification center |
| [Keep awake](caffeinate.md) | Timed sleep prevention, optional display-on |
| [Phone Transfer](phone-transfer.md) | Scan to connect; send files and text between Mac and phone over LAN or the internet (direct P2P) |
| [Claude Code assistant](claude-code.md) | Session resume, quota and usage, audit, notifications, visual config, statusline, MCP |
| [Codex assistant](codex.md) | Session resume, quota and usage, visual config, turn notifications, maintenance |

Settings also has an **[AI](ai.md)** page: pick a local or cloud model for each feature that
uses one, manage local models, add cloud providers, and see today's usage and limits.

Two general chapters:

- [Shortcuts](shortcuts.md) — every default binding and every bindable action
- [Data and privacy](privacy-and-data.md) — what is stored where, which permissions are
  needed, and why

## Read this page first

### Where it lives

Baobox is **menu-bar resident** with no Dock icon (`LSUIElement`). Everything is reached
through the Baobox icon in the menu bar: click it for the tool list, hover a tool to open
its submenu.

The order of tools in the menu is the order they are registered in code; it isn't draggable.

### Three ways to drive it

1. **The menu** — every feature is reachable by clicking, no shortcuts required.
2. **Global shortcuts** — bind common actions under Settings → Shortcuts; they work from
   any app. Only a few low-collision combinations ship bound; see [Shortcuts](shortcuts.md).
3. **The settings window** — `⌘,` or "Settings…" in the menu. The sidebar lists
   General / Shortcuts / AI / one page per tool / About.

### The settings window

| Tab | Contents |
|---|---|
| General | Interface language (English / Chinese / follow system — restart required), launch at login, permission status with jump-to-System-Settings, terminal app |
| Shortcuts | Every bindable action declared by every tool. Click a binding to record it; conflicts with the system or other apps are flagged immediately; defaults can be restored |
| AI | Three panes: **Features** (a local or cloud model per feature that uses one, with a suggestion next to it) / **Local models** (download, start, delete) / **Cloud models** (providers, API keys, models); Usage Limits and Privacy at the bottom |
| Per tool | One page each, documented in the chapters above |
| About | Version |

The **terminal app** setting decides which terminal the Claude Code and Codex assistants
use when resuming a session. Automatic mode prefers an installed third-party terminal
(iTerm2 → Ghostty → kitty → WezTerm → Alacritty) and falls back to Terminal.app.

### First launch

Onboarding asks for two permissions:

- **Screen Recording** — needed for screenshots, recording, OCR, and drawing on screen.
  ⚠️ A system quirk: after ticking it in System Settings you **must restart Baobox**.
  Both the onboarding window and the settings page offer a one-click restart.
- **Accessibility** — needed for clipboard paste-back, window management, keyboard
  clicking, and keyword expansion. Without it those features degrade gracefully (the
  clipboard copies instead of pasting, for instance) — nothing errors out or crashes.

Skipping is fine; grant them later under Settings → General → Permissions.

Microphone and speech recognition are only requested when you use them: "record microphone"
while recording, subtitles and interpreting, meeting notes, or dictation. Calendar access is only
requested when you turn on the calendar in Meeting's settings.

### Where data lives

Everything stays on this Mac by default: nothing is collected and there is no account. Cloud AI
models are off by default; text goes to a provider only when you pick a cloud model for a feature
in Settings → AI and use that feature.

```
~/Library/Application Support/Baobox/<module>/
```

One subdirectory per module. Screenshots default to `~/Pictures/Baobox` (configurable).
See [Data and privacy](privacy-and-data.md).
