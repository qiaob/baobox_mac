# Data and privacy

[简体中文](../privacy-and-data.md) · English

In one sentence: **everything stays on this Mac. Baobox uploads nothing and has no accounts.**

## Which permissions are needed

| Permission | Used by | Without it |
|---|---|---|
| **Screen Recording** | Screenshots, recording, OCR, live drawing | Those features can't run |
| **Accessibility** | Clipboard paste-back, window management, keyboard clicking, keyword expansion | Degraded: the clipboard copies instead of pasting; window management and keyboard clicking are unavailable |
| **Microphone** (optional) | Only requested when you enable "record microphone" during a recording | The recording continues without microphone audio |

> ⚠️ One system quirk: after ticking Screen Recording in System Settings you **must restart
> Baobox** for it to take effect. Both the onboarding window and the settings page offer a
> one-click restart.

Not needed: **no network account, no background uploads, no usage analytics.**

## Where data lives

```
~/Library/Application Support/Baobox/
├── <one subdirectory per module>    # keeps modules from interfering
~/Pictures/Baobox/                   # default location for screenshots and recordings
```

Per tool:

| Tool | What it stores | Where |
|---|---|---|
| Screenshot | History (20 by default), recordings | Support directory / `~/Pictures/Baobox` |
| Clipboard | History entries (text, images), favorites, snippets | Support directory, **AES-GCM encrypted by default** |
| Window manager | Layout snapshots | Support directory |
| Keep awake | Settings only | UserDefaults |
| Keyboard clicking | Settings only | UserDefaults |
| Claude Code assistant | **Nothing** — reads `~/.claude` live | — |
| Codex assistant | **Nothing** — reads `~/.codex` live | — |

Settings live in UserDefaults (`com.baobox.app`).

## The clipboard's privacy design

The clipboard is the only tool that retains content long-term, so it gets its own rules:

- **Encrypted at rest (on by default)**: text and images are encrypted with **AES-GCM**
  before hitting disk. The key is a random 256-bit value in the **login keychain** — it
  **never leaves this Mac and never syncs to iCloud**
- **Password manager content is skipped by default**: anything marked
  `org.nspasteboard.ConcealedType` (passwords from 1Password, Bitwarden, Keychain Access) is
  ignored. Enabling it asks for confirmation and spells out the risk; turning it back off
  **deletes every sensitive entry already recorded**
- **Transient content is always ignored**: content marked
  `org.nspasteboard.TransientType` has no switch and is never recorded — the source app
  explicitly asked for that
- **Ignore list**: nothing copied while a listed app is frontmost gets recorded
- **Auto-cleanup**: 1 / 7 / 30 / 90 days; non-favorited entries past that are deleted

Turning encryption off asks for confirmation, because existing history is **rewritten to disk
in plaintext**.

## Keystroke watching for keyword expansion

Snippet keyword expansion has to watch keystrokes to match a prefix. It's the only feature in
the app that does, so the boundary is drawn tightly:

- **Off by default** — you have to enable it
- **At most 32 characters** are held in memory for prefix matching
- **Never written to disk, never added to clipboard history**
- Apps on the ignore list don't expand
- In password fields macOS doesn't hand keystrokes to applications at all

## Does it use the network

Not in normal use. Two places make requests, and both require **an explicit click**:

- Claude Code assistant → Maintenance → Check for the latest version (an npm lookup)
- Codex assistant → Maintenance → Check for the latest version (same)

All session, usage, and cost data in both assistants is **computed from local files**. No AI
API is called and no login is required.

## Does it modify my files

Yes, but only when you ask it to, and always under the same rules:

- **Only our own keys are touched**; unknown fields and comments are preserved
- **A `.baobox.bak` backup is written first**
- JSON goes through `JSONSerialization`; TOML is edited line-by-line and block-by-block
  rather than through a general-purpose parser
- When a value can't be edited safely the **control is disabled** — better to do nothing than
  to corrupt the file

The files involved: `~/.claude/settings.json`, `~/.claude.json` (MCP), and
`~/.codex/config.toml`.
