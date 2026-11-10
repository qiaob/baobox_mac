# Data and privacy

[简体中文](../privacy-and-data.md) · English

In one sentence: **your data stays on this Mac, there are no accounts, and no usage data is collected.** The network is
used only where you ask for it (downloading models and assets, cloud AI, Phone Transfer over the internet); see
"[Does it use the network](#does-it-use-the-network)".

## Which permissions are needed

| Permission | Used by | Without it |
|---|---|---|
| **Screen Recording** | Screenshots, recording, OCR, live drawing; "System Audio" in meetings and Live Translate | Those features can't run; meetings and Live Translate can't hear system audio |
| **Accessibility** | Clipboard paste-back, window management, keyboard clicking, keyword expansion, the selection assistant (reading and replacing selected text), inserting dictated text, the menu bar manager | Degraded: the clipboard copies instead of pasting; dictation copies instead of inserting; window management, keyboard clicking, reading selections and the menu bar manager are unavailable |
| **Microphone** | Meetings, Live Translate (microphone source), dictation; "record microphone" during a screen recording | Those features can't run; screen recordings continue without microphone audio |
| **Speech Recognition** | Meetings, Live Translate, dictation (on this Mac when possible) | Speech can't be turned into text |
| **Calendars** (optional) | Meeting: requested only when you turn on calendars in Meeting settings; read-only | No next-meeting display, reminders or one-click join |
| **Local Network** | Phone Transfer's local network mode | Local network mode can't connect (internet mode still works) |
| **Automation** | Clicking a Claude Code notification jumps to the terminal window running that session | Clicking the notification doesn't switch to the terminal |

> ⚠️ One system quirk: after ticking Screen Recording in System Settings you **must restart
> Baobox** for it to take effect. Both the onboarding window and the settings page offer a
> one-click restart.

Not needed: **no network account, no background uploads, no usage analytics.** Each permission is requested only when
you first use a feature that needs it.

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
| Focus & Health | Reminders, the current round, focus records (last 400 days) | Support directory |
| Dictation | Dictation history (text only, no audio) | Support directory |
| Meeting / Live Translate | Transcripts (each sentence's original and translation), minutes, notes, action items; Live Translate transcripts (with "Save transcripts" on) go here too. No audio is stored | Support directory `Meetings/` (the meeting library) |
| Selection assistant | Custom actions; the English dictionary for Learn (only after you download it) | UserDefaults / support directory |
| Offline translation and local AI | Model files (around 1 GB each, only after you download them) | Support directory `Translation/` |
| AI | Providers, models and each feature's choice, today's cloud usage; **API keys are in the Keychain** | UserDefaults / Keychain |
| Desktop pet | Downloaded characters | Support directory `Pets/` |
| Phone Transfer | Received files | `~/Downloads/Baobox` (configurable) |
| Menu bar manager | Which icons to show or hide, an icon cache | UserDefaults / support directory |
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

## Export and import (moving to a new Mac)

**Settings → General → Data**: "Export Personal Data…" saves your snippets, dictation history, and focus & health
reminders, settings and focus records to one JSON file. On the new Mac, "Import…" first shows a summary (how many of
each, how many are new, which keywords clash), then **merges** after you confirm — nothing already there is overwritten.

- The exported file is **not encrypted** and contains your snippets and dictation text. Keep it somewhere safe
- Not included: clipboard history (other than snippets), sensitive entries copied from password managers, screenshots,
  meeting notes, API keys (nothing from the keychain ever leaves), local models
- A setting takes the imported value only if it's still at its default on the new Mac; anything you've changed there stays

## Keystroke watching for keyword expansion

Snippet keyword expansion has to watch keystrokes to match a prefix. It's the only feature in
the app that does, so the boundary is drawn tightly:

- **Off by default** — you have to enable it
- **At most 32 characters** are held in memory for prefix matching
- **Never written to disk, never added to clipboard history**
- Apps on the ignore list don't expand
- In password fields macOS doesn't hand keystrokes to applications at all

## Does it use the network

Nothing connects in the background, and nothing is reported back. These use the network, and only when you use them:

| When | Where to | What is sent |
|---|---|---|
| Downloading an offline translation or local AI model | Hugging Face, falling back to ModelScope | Download only |
| Downloading the dictionary in the selection assistant's Learn | GitHub (the ECDICT English dictionary, a pinned version) | Download only |
| Switching to a downloadable pet character | GitHub, falling back to jsDelivr (a pinned version, checked after download) | Download only |
| Choosing a cloud AI model for a feature | The provider you chose | The text that feature uses (see below) |
| Phone Transfer's **internet mode** | The phone's page is on GitHub Pages; connection details are **encrypted** and relayed by public ntfy.sh / MQTT servers; STUN servers (Cloudflare, Google and others) only discover public addresses | Files and text go **peer to peer**, through no server. Local network mode stays on your network |
| Claude Code / Codex assistant → Maintenance → Check for the latest version | npm | A version lookup only |

At the system level: on macOS 26 speech recognition is entirely on-device; on older systems without an on-device speech
model, Apple's speech service is used (same as system Dictation). Translation language packs and the macOS 26 speech
model are downloaded by macOS itself.

All session, usage, and cost data in both assistants is **computed from local files**. No AI
API is called and no login is required.

**Cloud AI models** (Settings → AI) are off by default. You can add providers and models there and pick a model
for each feature (selection translation, caption translation, AI correction, meeting minutes, weekly overview,
dictation polish). **Only a feature set to a cloud model** sends its text; Settings → AI → Usage Limits and Privacy
lists what is sent to which provider. Everything else stays on this Mac. API keys are stored in your Keychain.

- Base URLs must use `https://`; only services on this Mac (like Ollama) may use `http://`, since anything else would
  send your key and text unencrypted.
- The same section shows today's requests and tokens. There is a daily cap of 500 requests (adjustable): past it,
  requests use the local model and the pet asks whether to allow 500 more.

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
