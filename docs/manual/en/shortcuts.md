# Shortcuts

[简体中文](../shortcuts.md) · English

For 0.0.6. Every binding can be re-recorded, cleared, or reset under Settings → Shortcuts.
Conflicts with the system or another app are flagged **while you record**.

## Bound out of the box

| Shortcut | Action | Tool |
|---|---|---|
| ⌘⇧2 | Smart screenshot (click for a window · drag for a region · ⏎ for fullscreen) | Screenshot |
| ⌃⇧R | Start / stop recording | Screenshot |
| ⌘⇧V | Open the clipboard history panel | Clipboard |
| ⌘⌥V | Paste the last entry as plain text | Clipboard |
| ⌘⇧Space | Keyboard clicking (letter labels on elements) | Keyboard clicking |
| ⌃⇧Space | Claude Code quick resume panel | Claude Code |
| ⌃⌥← / → / ↑ / ↓ | Left / right / top / bottom half | Window manager |
| ⌃⌥U / I / J / K | Top-left / top-right / bottom-left / bottom-right quarter | Window manager |
| ⌃⌥⏎ | Maximize (fills the visible area, not fullscreen) | Window manager |
| ⌃⌥C | Center (without resizing) | Window manager |
| ⌃⌥⌘→ / ← | Move to the next / previous display | Window manager |
| ⌃⌥⌫ | Restore original position | Window manager |

> ⚠️ The window manager's **⌃⌥ set collides exactly with Rectangle and Magnet**. If you run
> one of those, rebind one side.

## Unbound by default

Left empty because these either collide easily or aren't frequent enough to earn a
combination:

| Action | Tool |
|---|---|
| On-screen OCR | Screenshot |
| Live drawing | Screenshot |
| QR code from the most recent entry | Clipboard |
| Keyboard scrolling (j/k to scroll) | Keyboard clicking |
| Open the Claude Code center | Claude Code |
| Recent files panel | Claude Code |
| Codex session center | Codex assistant |
| Codex quick resume panel | Codex assistant |

## Tools with no shortcut

**Keep awake** is menu-only and declares no shortcut — a low-frequency action shouldn't
occupy a key combination.

## In-interface keys (not global)

These only apply while the relevant interface is open and don't reserve global combinations.

### Screenshot / recording selection

| Key | Action |
|---|---|
| Click | Capture / record the highlighted window |
| Drag | Freehand region |
| ⏎ | The whole screen |
| Arrow keys | Nudge the selection one pixel (⇧ for ×10) |
| Esc | Cancel |

### Annotation

| Key | Action |
|---|---|
| ⌘Z | Undo |
| ⇧⌘Z | Redo |
| ⏎ | Copy and finish |
| ⌥⏎ | Save |
| Esc | Cancel |

### Clipboard panel

| Key | Action |
|---|---|
| Type | Search |
| ↑ / ↓ | Select |
| ⏎ | Paste back into the previous app |
| ⌘⌫ | Delete the entry |
| Esc | Close |

### Keyboard clicking / scrolling

| Key | Action |
|---|---|
| Two letters | Click that element |
| j / k or ↑ / ↓ | Scroll (scroll mode) |
| Space / ⇧Space | Page down / up (scroll mode) |
| Esc | Exit |

### Quick resume panels (Claude Code / Codex)

| Key | Action |
|---|---|
| Type | Search sessions |
| ↑ / ↓ | Select |
| ⏎ | Resume |
| ⌘C | Copy the resume command |
| Tab | Switch sessions / files mode (Claude Code only) |
| Esc | Close |

### Live drawing

| Key | Action |
|---|---|
| Esc | Exit drawing |

### Global

| Key | Action |
|---|---|
| ⌘, | Open settings |
| ⌘Q | Quit Baobox |
