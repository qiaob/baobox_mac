# Baobox

[![CI](https://github.com/qiaob/baobox_mac/actions/workflows/ci.yml/badge.svg)](https://github.com/qiaob/baobox_mac/actions/workflows/ci.yml)

**A menu-bar toolbox for macOS** — screenshots, clipboard, window management, keyboard
clicking, sleep prevention, plus dashboards for the Claude Code and Codex CLIs. One app
instead of five, with one shortcut system and one settings window.

[简体中文](README.zh-CN.md) · [User manual](docs/manual/en/README.md) · [Shortcuts](docs/manual/en/shortcuts.md)

```
macOS 14+   ·   Swift 5.9   ·   Zero third-party dependencies   ·   Everything stays local
```

## Contents

- [What it is](#what-it-is)
- [The tools](#the-tools)
- [Install](#install)
- [First launch](#first-launch)
- [Shortcuts](#shortcuts)
- [Data and privacy](#data-and-privacy)
- [Build from source](#build-from-source)
- [Project layout](#project-layout)
- [Adding a tool](#adding-a-tool)
- [Documentation](#documentation)

## What it is

The small utilities you use every day normally mean four or five separate apps — one for
screenshots, one for clipboard history, one for window management — each sitting in the
background with its own settings and its own shortcuts. Baobox makes them **modules inside
one native app**:

- **Native, not Electron** — Swift 5.9 with SwiftUI and AppKit, **zero third-party
  dependencies**, resident memory under ~50 MB
- **Modular** — the app shell knows nothing about any specific tool; each module implements
  the `ToolModule` protocol and registers its own menu, shortcuts, and settings page
- **Local only** — nothing is uploaded, nothing is collected, there is no account

No Dock icon (`LSUIElement`); everything lives in the menu bar.

## The tools

| Tool | Default shortcut | In one line |
|---|---|---|
| [Screenshot & recording](docs/manual/en/screenshot.md) | ⌘⇧2 · ⌃⇧R | Smart capture, annotation, pinning, scrolling capture, on-screen OCR, recording, live drawing, history |
| [Clipboard](docs/manual/en/clipboard.md) | ⌘⇧V · ⌘⌥V | History, search, paste-back, favorites, format detection and conversion, text snippets, encrypted at rest |
| [Window manager](docs/manual/en/window-manager.md) | ⌃⌥ family | Halves, quarters, maximize, center, across displays — 13 actions plus layout snapshots |
| [Keyboard clicking](docs/manual/en/keyboard-nav.md) | ⌘⇧Space | Two-letter labels on every clickable element; also keyboard scrolling |
| [Keep awake](docs/manual/en/caffeinate.md) | menu only | Timed sleep prevention, optional display-on |
| [Claude Code assistant](docs/manual/en/claude-code.md) | ⌃⇧Space | Session resume, quota and usage, audit, notifications, visual config, statusline, MCP |
| [Codex assistant](docs/manual/en/codex.md) | unbound | Session resume, quota and usage, visual config, turn notifications, maintenance |

### The framework itself

- Menu-bar resident, no Dock icon; the menu is a plain list of tools, one row each,
  hover to open its submenu
- Global hotkey center (Carbon): registration, **conflict detection**, customization,
  persistence, reset to default
- One settings window: General / Shortcuts / one page per tool / About
- First-launch permission onboarding with live status
- Optional launch at login (`SMAppService`)
- English and Simplified Chinese, or follow the system

### Screenshot & recording

One shortcut figures out what you meant: **hover to highlight a window, click to capture
it**; **press and drag** (past a ~4 pt threshold) to switch to a region; **⏎** for the whole
screen; **Esc** to cancel.

- Eight-way handles, **arrow keys nudge by one pixel** (⇧ for ×10), and a pixel loupe that
  shows live coordinates and the color under the cursor
- Multi-display, with an independent overlay per screen
- **Menus can be captured too**: if a context menu or menu-bar dropdown is open when you
  press the shortcut, the whole screen is frozen before Baobox activates and the menu
  closes — so the menu is still there in the shot
- **Annotation**: rectangle, ellipse, arrow, pen, highlighter, mosaic, text, eraser
  (removes a whole stroke). Undo ⌘Z, redo ⇧⌘Z, copy and finish ⏎, save ⌥⏎
- **Pinning**: keep an image floating above every window — resize it, change its opacity,
  run OCR on it, save it. You can also pin whatever image is on the clipboard
- **Scrolling capture**: frame a scrollable area, scroll the page yourself, and adjacent
  frames are aligned by their overlap into one tall image; the preview offers save, copy,
  pin, and OCR
- **On-screen OCR**: recognized **locally** by the system Vision framework (nothing is
  uploaded), with selectable language sets. **The result is editable before you copy it**,
  and QR codes or barcodes in the frame are decoded alongside the text
- **Recording**: the same selection flow, output as MP4 or GIF; system audio and microphone
  (a separate second track, optionally mixed down to one); pause, resume, or discard mid-recording
- **Live drawing**: draw straight onto the screen. In **pass-through mode** the strokes stay
  put while you keep using the app underneath
- **History**: the last 20 shots by default — copy, pin, save, or delete any of them

### Clipboard

Text, images, files, and links are all recorded. **⌘⇧V** opens the panel with the cursor
already in the search field; **⏎ pastes straight back** into the app you came from.

- Type filters (all / text / link / image / file / favorites), favorites pinned to the top,
  plain-text paste (⌘⌥V)
- **Text tools in the preview pane**: JSON, JWT, XML, timestamps, URLs, Base64, and curl
  commands are detected automatically, with in-place actions — format, decode, extract,
  MD5/SHA, **generate a QR code** — and a one-click revert
- **Large editor**: monospaced, undo, ⌘F find
- **Text snippets**: save text you type often, give it a keyword, and typing
  "prefix + keyword" in any input field expands it in place
- **Privacy**: content marked by password managers is skipped by default; transient content
  is always ignored; you can ignore specific apps; auto-cleanup after 1/7/30/90 days
- **Encryption**: history is written to disk with **AES-GCM** by default. The key is a
  random 256-bit value in the login keychain — it never leaves the Mac and never syncs to iCloud

### Window manager

All 13 actions are bindable and ship bound to the **⌃⌥** family.

> ⚠️ The ⌃⌥ set collides exactly with Rectangle and Magnet. If you run one of those,
> rebind one side in Settings.

- Full multi-display support: the target screen is the one with the **largest intersection**;
  layout is based on each screen's **visible frame** (menu bar and Dock excluded);
  moving across displays maps position and size proportionally and clips to bounds, so
  nothing deforms or overflows between different resolutions
- **Layout snapshots**: save where every window is and restore it later. Matching is by
  title first, order as fallback; apps that aren't running are skipped. Each entry records a
  stable per-display UUID and the window's relative position on that display, so a
  resolution or arrangement change doesn't break it
- Configurable gap between windows (0 = flush)

### Keyboard clicking

Press **⌘⇧Space** and every clickable element gets a two-letter label; type the letters to
click it. Elements come from the accessibility tree, so these are **real controls**, and
clicks prefer `AXPress` — **your actual mouse never moves**.

- **Continuous mode**: labels refresh after each click so you can keep going; Esc or a real
  mouse click exits
- **Label scope**: current display only, or all of them
- **Keyboard scrolling**: j/k to scroll, Space to page — for pages like Chrome that don't
  expose a scrollbar element

### Keep awake

Built on IOKit power assertions. Pick 15 minutes, 1 hour, 2 hours, or indefinite from the
menu; it releases itself when the timer runs out and the menu shows the remaining time.
Optionally keeps the display on too. The assertion is always released on quit.

### Claude Code / Codex assistants

Both bring a local AI coding CLI into the menu bar. **Everything is parsed from local
files — no AI API calls, no login.**

- **Resume sessions**: the most recent ones are one click away in your terminal, plus a
  Spotlight-style search panel (in Claude Code, Tab switches to a "recent files" mode that
  opens the files it last wrote)
- **Usage and quota**: 5-hour and weekly windows, today's spend, reports by day / project /
  model, and call statistics
- **Audit** (Claude Code): files changed per day, revealable in Finder
- **Notifications**: when a task finishes or Claude is waiting for you, with sound or
  **spoken** alerts; warnings at 80% of a token budget and when a quota window resets
- **Dangerous-command guard** (Claude Code): `rm -rf /`, `sudo rm`, `git push --force`,
  `git reset --hard`, `DROP TABLE`, `mkfs`, `chmod -R 777` and friends are blocked before
  they run, with the reason handed back to Claude. Custom regex rules are supported
- **Visual configuration**: permission mode, default model, session retention, permission
  rules and presets, privacy switches, CLAUDE.md management (Claude Code); approval policy,
  sandbox mode, default model (Codex)
- **Statusline builder** (Claude Code): tick the segments, preview live, apply in one click,
  with a confirmation before overwriting an existing one
- **MCP**: add and remove user-level servers for Claude Code; read-only listing for Codex
- **Maintenance**: disk usage, cleanup of old sessions, version check and a copyable
  upgrade command

> All costs are **estimates** based on public pricing, and labeled as such throughout.
>
> **Edits to your files are conservative**: only our own keys are touched, unknown fields
> and comments are preserved, and a `.baobox.bak` backup is written first. When a value
> can't be edited safely the control is disabled rather than risk corrupting the file.

## Install

### Download a release

Grab the latest `.zip` from [Releases](https://github.com/qiaob/baobox_mac/releases),
unzip it, and drag `Baobox.app` into Applications. If Gatekeeper blocks the first launch,
allow it under System Settings → Privacy & Security.

### Requirements

- macOS 14 (Sonoma) or later
- Apple silicon and Intel both supported

## First launch

Onboarding asks for two permissions:

| Permission | Used for | Without it |
|---|---|---|
| **Screen Recording** | Screenshots, recording, OCR, live drawing | Those features don't work |
| **Accessibility** | Clipboard paste-back, window management, keyboard clicking, keyword expansion | Clipboard degrades to copy-only; window management and keyboard clicking are unavailable |

> ⚠️ A system quirk: after you tick Screen Recording in System Settings you **must restart
> Baobox** for it to take effect. Both the onboarding window and the settings page offer a
> one-click restart.

Skipping is fine — you can grant them later under Settings → General → Permissions.
Microphone access is only requested if you enable "record microphone" while recording.

## Shortcuts

Bound out of the box:

| Shortcut | Action |
|---|---|
| ⌘⇧2 | Smart screenshot |
| ⌃⇧R | Start / stop recording |
| ⌘⇧V | Clipboard history panel |
| ⌘⌥V | Paste last item as plain text |
| ⌘⇧Space | Keyboard clicking |
| ⌃⇧Space | Claude Code quick resume |
| ⌃⌥ ← → ↑ ↓ / U I J K / ⏎ / C / ⌫ | The 13 window actions |
| ⌃⌥⌘ ← → | Move window across displays |

OCR, live drawing, QR code, keyboard scrolling, the Claude Code center, recent files, and
both Codex panels ship **unbound** — assign them under Settings → Shortcuts. Full list in
[Shortcuts](docs/manual/en/shortcuts.md).

## Data and privacy

**Everything stays on this Mac. Nothing is uploaded, nothing is collected, there is no account.**

```
~/Library/Application Support/Baobox/<module>/   # one subdirectory per module
~/Pictures/Baobox/                               # default location for screenshots and recordings
```

- Clipboard history is **AES-GCM encrypted by default**; the key lives in the login
  keychain and never syncs to iCloud
- Content marked by password managers is not recorded by default; transient content is
  always ignored
- The Claude Code and Codex assistants **store nothing** — they read `~/.claude` and
  `~/.codex` live
- The only network access is the version check you trigger yourself (an npm lookup)

See [Data and privacy](docs/manual/en/privacy-and-data.md).

## Build from source

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`project.yml` globs all of `Sources`, so new `.swift` files are picked up without touching
the config.

```bash
brew install xcodegen
git clone https://github.com/qiaob/baobox_mac.git
cd baobox_mac
xcodegen generate
open Baobox.xcodeproj          # or: xcodebuild -scheme Baobox build
```

`Baobox.xcodeproj` is not checked in — re-run `xcodegen generate` after pulling.
Non-sandboxed with Hardened Runtime; bundle id `com.baobox.app`.

Validate the localization catalog:

```bash
python3 -c "import json;json.load(open('Sources/Resources/Localizable.xcstrings'));print('valid')"
```

## Project layout

```
Sources/
├── App/                    # BaoboxApp, AppDelegate, StatusItemController
├── Core/                   # shared infrastructure
│   ├── ToolModule.swift        # the tool protocol (the heart of the framework)
│   ├── ToolRegistry.swift      # registration order = menu order
│   ├── HotkeyCenter.swift      # Carbon global hotkeys
│   ├── KeyCombo / Permissions / Geometry / L10n / QRCodeGenerator / TextRecognizer …
├── Modules/                # one directory per tool
│   ├── Screenshot/  Clipboard/  WindowManager/  KeyboardNav/
│   ├── Caffeinate/  ClaudeCode/  AITools/  NetCapture/
├── Settings/               # settings window
├── Onboarding/             # first-launch permission flow
└── Resources/              # Localizable.xcstrings, Assets
```

`NetCapture` (packet capture) is in the repo but **not registered in the current release**.

## Adding a tool

The framework knows nothing about any specific tool. Adding one takes two steps:

1. Implement `ToolModule` under `Sources/Modules/<Name>/`:

```swift
@MainActor
final class MyTool: ToolModule {
    let id = "mytool"
    let name = L("mytool.name")
    let symbolName = "wand.and.stars"           // SF Symbol

    func submenuItems() -> [NSMenuItem] { … }   // submenu
    func hotkeys() -> [HotkeyDefinition] { … }  // bindable shortcuts
    func settingsTab() -> AnyView { … }         // settings page
    func activate() { … }                       // on launch
    func willTerminate() { … }                  // cleanup before quit
}
```

2. Call `registry.register(MyTool())` in `AppDelegate`.

The menu-bar entry, submenu, settings tab, and hotkey registration and persistence are all
wired up automatically.

All user-facing strings go through `L("mytool.key")` (AppKit) or `Text("mytool.key")`
(SwiftUI), with both `en` and `zh-Hans` values added to
`Sources/Resources/Localizable.xcstrings`.

Conventions are documented in [CLAUDE.md](CLAUDE.md).

## Documentation

| Document | Contents |
|---|---|
| [User manual](docs/manual/en/README.md) | Every tool and every feature, in detail ([中文](docs/manual/README.md)) |
| [CLAUDE.md](CLAUDE.md) | Architecture overview and code conventions |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | Product requirements |
| [docs/TECH_DESIGN.md](docs/TECH_DESIGN.md) | Technical design |
| [docs/design/](docs/design/) | UI mockups and design tokens |
| `docs/<feature>/` | Requirements and design per feature |

The workflow for a new feature: write requirements and a technical design under
`docs/<feature>/` first, then implement it — **the document is the source of truth**.
