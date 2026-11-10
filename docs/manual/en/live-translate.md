# Live Translate

[简体中文](../live-translate.md) · English

Turns speech from the **microphone** or **system audio** into live captions, translates
**English ⇄ Chinese**, and shows them in a caption bar at the bottom of the screen. Useful for
English videos and courses, online meetings, or talking with colleagues in person.

## Start and stop

- Menu bar → Meeting → **Start Free Listening**; click again (or the × on the bar) to stop. While a meeting is
  being recorded the item reads Show / Hide Subtitles. (The standalone Subtitles & Interpreting entry is now part
  of Meeting, #106.)
- The global shortcut "Toggle Live Translate" is unbound by default; set one under Settings → Shortcuts or
  Settings → Meeting.

## Audio source

| Source | Good for | Permission |
|---|---|---|
| **System Audio** (default) | Whatever your Mac plays: videos, courses, the other side of a call | Screen Recording (macOS delivers system audio through screen capture) |
| **Microphone** | You or people in the room | Microphone |

Switch under Settings → Meeting → Subtitles & Interpreting; switching while running restarts recognition automatically.
The microphone is the system default input (System Settings › Sound › Input). Baobox's own sounds are never captured.

## Language

- **Spoken language**: with "Auto (A / B)" each sentence is checked against the two languages; or pick one.
- **Translate into**: the language captions are translated into. A sentence already in that language is **not
  translated**; its original text is shown as the caption (with "Translate into English", English speech shows only
  the English original, no Chinese).

Turn off "Translate captions" to get original-language captions only (live dictation).

## Caption bar

- The newest sentence updates live at the bottom; earlier ones are dimmer. **Drag an edge or corner to resize the bar**
  (there's a grip in the bottom-right corner); make it taller to see more sentences. Scroll up with the trackpad or
  mouse wheel to read earlier ones (up to 200). While you're scrolled up, new captions don't pull you back; click
  "Jump to latest" in the bottom-right corner, or scroll back down, to follow again. Changing the source, language or
  other settings from the bar keeps the history; closing the bar clears it.
- Show: **Original + translation** / **Translation only** / **Original only**.
- Font size and background opacity apply immediately.
- Drag the bar to move it. Its position and size are remembered, and it stays on top over full-screen apps and across
  Spaces.
- The first live translation after Baobox opens loads the local translation model into memory (about 6–9 seconds). A
  spinner at the bottom of the caption area reads "Loading the translation model" until it's ready; starting again
  within 10 minutes needs no reload.
- The top-right corner is a **latency monitor**. "Speech" is the time from starting to talk after a pause to the first
  words on screen; "Translation" is the time from a finished chunk to its translation (including AI correction when
  it's on). Both are the median of the last 5. Yellow or orange means slow; "…" after the translation time means a
  chunk is still waiting, and the number is how long it has waited so far.

## Transcript and minutes

- "Save transcripts" is off by default. Click **Record** on the caption bar (or turn it on under Transcript & minutes in
  settings) to start right away (the sentences already on the bar are included). From then on every live translation
  saves one; turning it off finishes the current one.
- Transcripts are Markdown, saved to the meeting library (menu bar → Meeting → Meeting Library): each sentence's time,
  original and translation, written as soon as the sentence ends, so quitting midway loses nothing. Old transcripts
  from "Documents › Baobox Live Translate" were imported into the library by reference; the files stay where
  they are.
- After you stop, AI writes **minutes**: key points, decisions and action items at the top of the transcript, with a
  notification when they're ready. The model is the one chosen for "Meeting Minutes" under Settings → AI; by default
  the local Qwen3-1.7B, offline. If that model isn't ready (a local model not downloaded, a cloud model not set up),
  only the transcript is saved.
- The **Record** button on the bar turns saving on or off; the small button next to it opens the current transcript
  (or the transcript folder when there isn't one yet). After you stop, find the session under menu bar → Meeting →
  Meeting Library.
- Under Transcript & minutes in settings you can turn transcripts or minutes off.

## Speed and accuracy

- On **macOS 26 and later** the new on-device speech engine is used automatically: text appears faster, context is kept
  across the whole stream, accuracy is higher, and audio never leaves your Mac. The model downloads the first time
  (the bar shows "Downloading the speech model"). Older systems, or a failed download, fall back to the previous engine.
- **Custom vocabulary**: add names, product names and jargon that get misheard (comma- or newline-separated) in
  settings, and recognition favors them.

## Privacy

- On macOS 26 recognition is always on-device. On older systems, "Prefer on-device recognition" is on by default:
  when the on-device model is available, **audio never leaves your Mac**; otherwise Apple's speech service is used
  (same as system Dictation).
- Translation uses the built-in on-device Apple Translation (macOS 15+) or the offline model, with no third-party
  service. Only if you pick a cloud model for "Caption Translation" (or "AI Correction"), in the feature list under
  Settings → AI or the same row on this page, is each recognized sentence sent to that provider. When the cloud is
  unavailable it falls back to the local model (if downloaded).
- Transcripts aren't saved by default. With "Save transcripts" on, they stay on this Mac, in the meeting library
  (`~/Library/Application Support/Baobox/Meetings/`).

## Requirements and troubleshooting

- **Translation requires macOS 15 or later.** On macOS 14 only original captions are shown.
- macOS may ask to download language files the first time. If it doesn't, or the download fails,
  install English and Chinese under System Settings › General › Language & Region › Translation Languages.
- The first start asks for **Speech Recognition** permission; if denied, enable it in
  System Settings › Privacy & Security › Speech Recognition.
- "Speech Recognition Unavailable": make sure **Dictation** is on in System Settings › Keyboard;
  without the on-device model you also need to be online.
- System audio without Screen Recording permission: after granting it, **restart Baobox** (a macOS limitation).
