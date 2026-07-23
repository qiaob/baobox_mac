# Baobox

[![CI](https://github.com/qiaob/baobox_mac/actions/workflows/ci.yml/badge.svg)](https://github.com/qiaob/baobox_mac/actions/workflows/ci.yml)

A lightweight, menu-bar-resident macOS toolbox that bundles everyday productivity utilities — screenshot, clipboard manager, color picker, and more — into a single native app with one shortcut system and one settings window.

[English](README.md) · [简体中文](README.zh-CN.md)

## Overview

Most macOS productivity tools ship as separate apps: one for screenshots, one for clipboard history, one for color picking — each with its own download, its own background process, its own settings. Baobox takes the opposite approach: a single menu-bar app, built natively in Swift, that houses multiple independent tool modules behind one consistent interface.

- **Native, not Electron** — Swift 5.9, SwiftUI + AppKit, zero third-party dependencies. Resident memory stays under ~50 MB.
- **Modular by design** — the app shell has no knowledge of individual tools; each one implements a common `ToolModule` protocol and self-registers its menu entry, shortcuts, and settings tab.
- **Local-first** — all data (clipboard history, screenshots, color history, window layouts) stays on disk, on your Mac. Nothing is uploaded.
- **macOS 14 (Sonoma) or later**, built against ScreenCaptureKit and other modern system frameworks.

## Features

### Core
- Menu-bar resident, no Dock icon (`LSUIElement`); the menu is a flat list of tools — one row per tool (icon, name, primary shortcut), with a submenu on hover for actions, history, and per-tool settings.
- Centralized global hotkey manager (Carbon) with conflict detection, per-tool customization, and persistence.
- One settings window: General / Shortcuts / one tab per tool / About.
- Guided permission onboarding with live status.
- Optional launch at login (`SMAppService`).

### Screenshot (default ⌘⇧2)
- Single shortcut, intent detected automatically: hover to highlight and capture a window with one click; click-drag (past a ~4pt threshold) for a region capture with eight-way resize handles, arrow-key nudging (⇧ for ×10), and a pixel loupe; ⏎ for a full-screen capture; Esc to cancel.
- Multi-display support, one overlay per screen.
- Built on ScreenCaptureKit. Results copy to the clipboard and, optionally, save to a configurable folder with a customizable filename template.
- In-place annotation editor: rectangle, ellipse, arrow, pen, highlighter, mosaic/blur, text, eraser, undo/redo (⌘Z / ⇧⌘Z), three stroke widths, a seven-color palette.
- Pin: keep a capture floating on top of every window, draggable, scroll-to-zoom (0.2×–5×), ⌥+scroll for opacity; pin directly from the clipboard.
- Pixel loupe for precise selection: an 8×-magnified 17×17 grid follows the cursor while hovering, dragging, or resizing a handle, with live coordinates and a hex color readout.
- Screenshot history: every capture is archived automatically (configurable retention, default 20), with a thumbnail menu for copy / re-pin / save-as / delete.
- Screen recording: reuses the same selection UI (drag a region, click a window, or capture full screen) and exports to MP4 or GIF. Optionally records system audio and/or microphone (mixed down to a single track by default); a red border marks the recording area and a floating control bar supports pause/resume, stop, and cancel.

### Clipboard (default ⌘⇧V)
- Background monitoring with history for text, rich text, images, file paths, and links; content marked `org.nspasteboard.ConcealedType` / `TransientType` is never stored.
- Floating history panel: type-to-search, filter by type, arrow-key navigation, ⏎ to paste, ⌥⏎ for a plain-text paste, ⌘P to pin.
- Selecting an entry auto-pastes into the frontmost app via a simulated ⌘V (requires Accessibility); without that permission, it falls back to copy-only.
- Configurable history limit with automatic eviction; persists across restarts.
- Per-app ignore list, automatic expiry (never / 1 / 7 / 30 / 90 days), and per-item delete (⌘⌫ or an inline button); a global ⌘⌥V shortcut pastes the most recent item as plain text.

### Color Picker (unbound by default)
- System-native magnifier sampling via `NSColorSampler` — no permissions required.
- Copies the sampled color in your preferred format (Hex / RGB / SwiftUI `Color`) and keeps a history (up to 50 entries).
- The submenu shows the five most recent colors as swatches for one-click re-copy.
- Settings let you choose the output format, hex letter case, and whether to auto-copy after sampling.

### Caffeinate — Sleep Prevention (menu-only)
- Blocks idle sleep via an IOKit power assertion (`IOPMAssertionCreateWithName`).
- Enable for 15 minutes / 1 hour / 2 hours / indefinitely from the submenu; the assertion clears automatically on expiry, with a live countdown shown in the menu.
- Optional "also prevent display sleep"; the assertion is released automatically on quit.

### Window Manager (unbound by default)
- Move and resize the frontmost window via Accessibility: halves, quarters, maximize (non-fullscreen), center, move between displays, and restore to its original position — 13 fully customizable shortcuts (unbound out of the box, since the conventional ⌃⌥ bindings collide with Rectangle; set your own under Settings → Shortcuts).
- **Layout snapshots**: "Save current layout…" records the position and size of every regular, non-minimized window; restoring re-applies them with title-first matching and an ordering fallback, skipping apps that aren't running.
- **Multi-display aware** throughout: the target display is whichever one has the largest intersection with the window; layouts are computed against each display's visible frame (avoiding the menu bar and Dock); moving a window between displays scales its relative position and size to fit, clamped to stay on-screen; snapshots store a stable per-display UUID plus a relative position, so restoring works correctly even if resolution or display arrangement changed since the snapshot was taken.

### QR Code Generator (default ⌃⇧Q)
- Opens a floating panel pre-filled with the current clipboard text; edits regenerate the code live (error-correction level M, quiet zone included).
- Copy as an image, save as PNG, or pin it on screen.
- Fully local (`CIQRCodeGenerator`), no permissions required.

### Claude Code Assistant (unbound by default)
- A menu-bar dashboard for the local Claude Code CLI, built entirely from `~/.claude` files — no AI API, no login: live session status (running / awaiting confirmation), the five most recent sessions for one-click terminal resume, the current 5-hour usage window (tokens, estimated cost, reset countdown) and today's estimated spend.
- **Center window** (Sessions / Usage / Audit): searchable session history with resume, copy-command, Markdown export and delete; a usage report by day / project / model plus an invocation breakdown (skills & slash commands, MCP servers › tools, built-in tools); and a per-day file-change audit that reveals edited files in Finder.
- **Background helpers** (opt-in): Baobox hooks post a system notification when a task finishes or Claude awaits confirmation, warn at 80% of a token budget, and a dangerous-command guard blocks `rm -rf`, `git push --force`, `git reset --hard`, `DROP TABLE` and friends before they run — feeding the reason back to Claude.
- **Visualized configuration**: pickers for permission mode / default model / session retention, permission-preset checkboxes, privacy env toggles, Co-Authored-By, CLAUDE.md management, a statusline generator with live preview, an MCP server panel, and disk cleanup / version check — every edit writes the user's JSON safely (unknown keys preserved, `.baobox.bak` backup).
- Costs are estimates from public pricing and are labelled as such throughout.

### Cursor / Codex Assistant (menu-only)
- A local-only companion for the Codex CLI and the Cursor editor, built entirely from files under `~/.codex` and `~/.cursor` — no AI API, no login. The menu lists your most recent Codex sessions (project + first prompt) for one-click terminal resume (`codex resume <id>`), with a lightweight window to search, resume, copy the command, or delete.
- **Codex configuration**: visualized pickers for `approval_policy`, `sandbox_mode` (danger tier shown in red) and default `model`, edited line-by-line in `config.toml` so comments and unknown keys survive; values it can't safely edit are detected and the controls disable themselves. Backs up `config.toml.baobox.bak` before every write.
- **Turn-complete notifications** (opt-in): installs a `notify` hook into `config.toml`; when a Codex turn finishes Baobox posts a system notification with the last-assistant-message summary, and removing it leaves no residue.
- **Cursor Rules**: track project folders, list their `.cursor/rules/*.mdc` files (with legacy `.cursorrules` detection), open any file, and write built-in General / Frontend / Python rule templates (existing files are never overwritten).
- **Cursor MCP panel**: view, add and remove servers in `~/.cursor/mcp.json` (unknown keys preserved, `.baobox.bak` backup).

> Sparkle-based auto-update is not yet wired up (pending a hosting decision); the "Check for Updates" menu item is currently a disabled placeholder.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

### Download a release

Grab the latest `.zip` from [Releases](https://github.com/qiaob/baobox_mac/releases), unzip, and drag `Baobox.app` into `/Applications`.

Pre-notarization builds are blocked by Gatekeeper on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -cr /Applications/Baobox.app
```

### Build from source

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not checked into git.

```bash
brew install xcodegen
xcodegen generate
open Baobox.xcodeproj
```

Select the `Baobox` scheme and run, or use the bundled Makefile:

```bash
make dev      # Debug build, run without touching /Applications
make install  # Release build, installed to /Applications and relaunched
```

## Permissions

Baobox requests permissions on first launch (System Settings → Privacy & Security):

| Permission | Used for | If denied |
|---|---|---|
| Screen Recording | Capturing screen content | The screenshot tool is unavailable |
| Accessibility | Simulating ⌘V to auto-paste clipboard history; moving/resizing windows | Clipboard falls back to copy-only; Window Manager is unavailable |
| Microphone | Recording your voice during screen recording (optional, requested only when enabled) | Recording continues without a mic track |

All permissions are tied to the bundle identifier `com.baobox.app`; changing it requires re-granting access. Granted permissions take effect immediately — no restart required.

## License

Baobox is provided for personal, non-commercial use only. Commercial use in any form — including resale, bundling into a commercial product or service, or commercial redistribution — is prohibited without prior written permission from the author. Contact the author to discuss commercial licensing.
