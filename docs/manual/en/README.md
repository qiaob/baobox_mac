# Baobox User Manual

[简体中文](../README.md) · English

For version **0.0.6**. This manual covers every tool and every feature currently in the app.

## Contents

| Tool | What it covers |
|---|---|
| [Screenshot & recording](screenshot.md) | Smart capture, annotation, pinning, scrolling capture, on-screen OCR, recording, live drawing, history |
| [Clipboard](clipboard.md) | History, search, paste-back, favorites, text tools, snippets, privacy and encryption |
| [Window manager](window-manager.md) | Halves, quarters, maximize, center, across displays, layout snapshots |
| [Keyboard clicking](keyboard-nav.md) | Letter-label clicking, continuous mode, keyboard scrolling |
| [Keep awake](caffeinate.md) | Timed sleep prevention, optional display-on |
| [Claude Code assistant](claude-code.md) | Session resume, quota and usage, audit, notifications, visual config, statusline, MCP |
| [Codex assistant](codex.md) | Session resume, quota and usage, visual config, turn notifications, maintenance |

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
   General / Shortcuts / one page per tool / About.

### The settings window

| Tab | Contents |
|---|---|
| General | Interface language (English / Chinese / follow system — restart required), launch at login, permission status with jump-to-System-Settings, terminal app |
| Shortcuts | Every bindable action declared by every tool. Click a binding to record it; conflicts with the system or other apps are flagged immediately; defaults can be restored |
| Per tool | One page each, documented in the chapters above |
| About | Version |

The **terminal app** setting decides which terminal the Claude Code and Codex assistants
use when resuming a session. Automatic mode prefers an installed third-party terminal
(iTerm2 → Ghostty → kitty → WezTerm → Alacritty) and falls back to Terminal.app.

### First launch

Onboarding asks for two permissions:

- **Screen Recording** — needed for screenshots, recording, and OCR.
  ⚠️ A system quirk: after ticking it in System Settings you **must restart Baobox**.
  Both the onboarding window and the settings page offer a one-click restart.
- **Accessibility** — needed for clipboard paste-back, window management, keyboard
  clicking, and keyword expansion. Without it those features degrade gracefully (the
  clipboard copies instead of pasting, for instance) — nothing errors out or crashes.

Skipping is fine; grant them later under Settings → General → Permissions.

Microphone access is only requested if you turn on "record microphone" while recording.
It is off by default.

### Where data lives

Everything is local and nothing is uploaded:

```
~/Library/Application Support/Baobox/<module>/
```

One subdirectory per module. Screenshots default to `~/Pictures/Baobox` (configurable).
See [Data and privacy](privacy-and-data.md).
