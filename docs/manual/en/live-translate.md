# Live Translate

[简体中文](../live-translate.md) · English

Turns speech from the **microphone** or **system audio** into live captions, translates
**English ⇄ Chinese**, and shows them in a caption bar at the bottom of the screen. Useful for
English videos and courses, online meetings, or talking with colleagues in person.

## Start and stop

- Menu bar → Live Translate → **Start Live Translate**; click again (or the × on the bar) to stop.
- The global shortcut "Toggle Live Translate" is unbound by default; set one under Settings → Shortcuts.

## Audio source

| Source | Good for | Permission |
|---|---|---|
| **System audio** (default) | Whatever your Mac plays: videos, courses, the other side of a call | Screen Recording (macOS delivers system audio through screen capture) |
| **Microphone** | You or people in the room | Microphone |

Switch from the menu; switching while running restarts recognition automatically. The microphone
is the system default input (System Settings › Sound › Input). Baobox's own sounds are never captured.

## Language

Pick the **spoken** language:

- **English → 中文**: recognize English, translate to Chinese;
- **中文 → English**: recognize Chinese, translate to English.

Turn off "Show Translation" to get original-language captions only (live dictation).

## Caption bar

- Shows the last two sentences: the previous one fades, the current one updates live below it;
  long sentences always show their newest part.
- Display: **Original + translation** / **Translation only** / **Original only**.
- Font size and background opacity apply immediately.
- Drag the bar to move it — its position is remembered. It stays on top over full-screen apps and across Spaces.

## Speed and accuracy

- On **macOS 26 and later** the new on-device speech engine is used automatically: text appears faster, context is kept
  across the whole stream, accuracy is higher, and audio never leaves your Mac. The model downloads the first time
  (the bar shows "Downloading the speech model"). Older systems, or a failed download, fall back to the previous engine.
- **Custom vocabulary**: add names, product names and jargon that get misheard (comma- or newline-separated) in settings.

## Privacy

- On macOS 26 recognition is always on-device. On older systems, "Prefer on-device recognition" is on by default: when the on-device model is available, **audio
  never leaves your Mac**; otherwise Apple's speech service is used (same as system Dictation).
- Translation uses the built-in on-device Apple Translation (macOS 15+), no third-party service.
- Captions are never written to disk and are cleared when you stop.

## Requirements and troubleshooting

- **Translation requires macOS 15 or later.** On macOS 14 only original captions are shown.
- macOS may ask to download language files the first time. If it doesn't, or the download fails,
  install English and Chinese under System Settings › General › Language & Region › Translation Languages.
- The first start asks for **Speech Recognition** permission; if denied, enable it in
  System Settings › Privacy & Security › Speech Recognition.
- "Speech Recognition Unavailable": make sure **Dictation** is on in System Settings › Keyboard;
  without the on-device model you also need to be online.
- System audio without Screen Recording permission: after granting it, **restart Baobox** (a macOS limitation).
