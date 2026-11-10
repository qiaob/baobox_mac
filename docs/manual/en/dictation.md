# Voice dictation

[简体中文](../dictation.md) · English

Menu bar → **Dictation**. Talk instead of typing: what you say goes straight into the text field you're in, at the cursor.

Default shortcut **⌥Space**: press once to start; each sentence is typed in as soon as you pause, so you can keep talking;
press again to stop.

## Three ways to dictate

| Mode | How to start | Good for |
|---|---|---|
| **Start / Stop Dictation** | ⌥Space (bound by default), or menu → "Start Dictation" | Everyday typing: each sentence goes in as you finish it |
| **Hold to Talk** | The "Hold to Talk" shortcut (unbound by default) | One short sentence: hold, talk, release |
| **Long Dictation** | The "Long Dictation" shortcut (unbound by default), or menu → "Long Dictation…" | A long passage: text collects in a panel you can edit, then goes in at once |

### Start / Stop Dictation

- Press once to start. Pause for about a second after a sentence and it's typed into the current text field; keep going.
- Press again (or menu → "Stop Dictation") to stop; the last sentence goes in too. Thirty seconds of silence also stops it
  (change to 10 or 60 seconds, or off).
- Click into another text field midway and the next sentences go there.
- **Esc** or the ✕ on the recording bar stops dictation: the sentence you were still saying is dropped; what's already typed stays.

### Hold to Talk

Hold the shortcut and talk; release to type it in. Regular shortcuts and F1–F12 work; a single modifier key (like right ⌥)
isn't supported yet.

### Long Dictation

Keeps listening until you stop. What you say shows up a part at a time in the "Long Dictation" panel, where you can edit it.
Buttons: "Insert" (into the field you came from), "Copy", "Clear", "Stop" (then "Keep Dictating").

## The recording bar

A small recording bar appears while you dictate. It never takes focus, so the app you're typing into stays in front. It sits
next to the cursor, or at the bottom of the screen when the cursor position isn't available (you can pin it to the bottom in
settings). It shows the level, a timer, the text being recognized and hints such as "Release to finish", "Press again to
finish" and "Esc to cancel".

Afterwards it shows the result for 2 seconds: "Inserted", or "Copied — press ⌘V to paste" (the text couldn't be typed in
directly and is on the clipboard; the bar also has a "Copy" button).

## How the text gets in

"Insert method" is "Automatic" by default:

1. Native text fields: written straight in at the cursor (replacing any selected text).
2. Where that doesn't work (Electron apps, terminals, web pages): pasted through the clipboard, then your clipboard is put
   back. This never shows up in clipboard history.
3. In a password field, or with nowhere to type: only copied, for you to press ⌘V.

"Always paste" always goes through the clipboard.

With Start / Stop Dictation, sentences that can't be typed in don't overwrite the clipboard one by one: they're collected and
copied once when you stop. With dictation history on, the full text is in the history too.

## Clean-up before the text goes in

In this order:

1. **Voice commands** (on by default): say 「换行 / 新的一行」 or "new line" for a line break, 「新段落」 or
   "new paragraph" for a blank line, 「句号 / 逗号 / 问号 / 感叹号」 for punctuation, and 「删除上一句」 or
   "delete last sentence" to drop the previous sentence of this dictation (if it's already typed in, it's backspaced
   away — only text this dictation typed into the current app).
2. **Filter filler words** (on by default): drops 嗯 / 呃 / 额 / 唔, a stray 「啊」 or 「那个」 at the start of a sentence,
   um / uh / er / hmm, and stutters like 「我我我」 or "the the". When unsure, the words stay.
3. **Punctuation**: full-width punctuation for Chinese, no stray spaces between Chinese and English; a final punctuation mark
   is added when missing.
4. **AI Polish** (off by default): see below.

### AI Polish

Tidies spoken text into written text (drops filler, smooths sentences) without adding or removing information. The
"Polish into written text" setting: Off (default) / All apps / Only these apps (say, documents and mail get polished while
chats stay as spoken).

- Hold to Talk polishes the whole passage before it goes in, waiting up to 8 seconds; on timeout the original goes in.
- Start / Stop Dictation and Long Dictation polish sentence by sentence, adding a second or two to each.
- It uses the local model Qwen3-1.7B by default (the same one subtitles use for AI correction). Download it once under
  "Polishing model" in settings; nothing leaves this Mac. Until it's downloaded, the original goes in and you're told once.
- You can switch the "AI Polish" row to another local model or a cloud model. With a cloud model, the dictated text is sent
  to that provider. See [AI](ai.md).

## Recognition

- **Language**: Automatic (Chinese / English, the default) / Follow Live Translate / 中文 / English. Automatic listens in
  the main language first (English if your system is in English, otherwise Chinese); when a passage looks unsure, it
  re-checks the recording in the other language and keeps the better one. Start / Stop Dictation and Long Dictation decide
  per sentence, so you can switch languages between sentences. Chinese recognition already picks up common English words
  mixed in.
- **Prefer on-device recognition** (on by default): when this Mac has an on-device model for the language, the audio never
  leaves it. The settings page says, per language, whether it's recognized on this Mac or through Apple's servers. To get an
  on-device model, add the language under System Settings → Keyboard → Dictation.
- **Glossary**: names and product terms listed here are recognized more accurately. It's shared with Subtitles &
  Interpreting; click "Edit in Live Translate…" to edit it.

Dictation can't run while a meeting is being recorded or Free Listening is on. It then says
"… is using the microphone. Stop it before dictating."

## Dictation history

Menu → "Copy Last Dictation" and "Dictation History…". The history window can search, copy, insert again, delete and clear.

Only the text, time and target app are kept, never audio. The last 50 are kept by default (10–500); you can also turn history off.

## Menu

| Item | Notes |
|---|---|
| Start Dictation / Stop Dictation | Start / Stop Dictation, shortcut ⌥Space |
| Long Dictation… | "Stop Long Dictation" while listening, "Resume Long Dictation" after it's stopped |
| Copy Last Dictation | Dimmed until you've dictated something |
| Dictation History… | |
| Dictation Settings… | |

## Settings

Settings → Dictation:

| Group | Setting | Notes |
|---|---|---|
| (top) | Three shortcuts | Start / Stop Dictation ships as ⌥Space; Hold to Talk and Long Dictation are unbound |
| Recognition | Language | "Automatic (Chinese / English)" by default |
| | Stop after silence | Start / Stop Dictation only: Off / 10 / 30 (default) / 60 seconds |
| | Prefer on-device recognition | On by default; the lines below say which way each language goes |
| Text | Voice commands, Filter filler words | Both on by default |
| AI Polish | Polish into written text | Off (default) / All apps / Only these apps ("Add App…") |
| | AI Polish, Polishing model | Which model, and downloading the local one (shown unless polish is off) |
| Typing It In | Insert method | Automatic (default) / Always paste |
| Recording Bar | Position | Next to the cursor (default) / Bottom of the screen |
| | Play start and end sounds | Off by default |
| History | Keep dictation history | On, keeping the last 50; "Dictation History…", "Clear History…" |
| Glossary | N terms (shared with Live Translate) | "Edit in Live Translate…" |
| Permissions | Microphone, Speech Recognition, Accessibility | Granted or not, with "Open Settings" |

## Permissions

Asked for the first time you dictate; nothing is requested in advance:

| Permission | Used for | Without it |
|---|---|---|
| Microphone, Speech Recognition | Listening | Dictation can't start; System Settings opens at the right pane |
| Accessibility | Typing into text fields, pasting, catching Esc | Text is only copied for you to press ⌘V; Esc can't cancel, use the ✕ on the bar |

## Data and privacy

- Dictation history lives in `~/Library/Application Support/Baobox/Dictation/history.json`, text only.
- Recognition runs on this Mac by default; languages without an on-device model go through Apple's speech service (the same
  as the system's own Dictation).
- AI Polish runs on this Mac by default. Only if you pick a cloud model for "AI Polish" is the dictated text sent.

## Troubleshooting

- **⌥Space does nothing**: another app (a launcher, say) may own it; pick another shortcut under Settings → Shortcuts.
- **Text didn't go in; "Copied — press ⌘V to paste"**: Accessibility permission is missing, you're in a password field, or
  there's nowhere to type. Press ⌘V yourself.
- **"Speech recognition isn't available right now"**: check your network, or turn on Dictation in System Settings → Keyboard.
- **"… is using the microphone. Stop it before dictating."**: a meeting recording or Free Listening is using the microphone;
  stop it first.

Technical details: [docs/dictation/](../../dictation/TECH_DESIGN.md).
