# Selection assistant

[简体中文](../selection-assistant.md) · English

Menu bar → **Selection Assistant**. Select text in any app — browsers, Google Docs, PDFs, even a single word — and a small row
of buttons appears above it: **Translate, Learn, Polish, Rewrite, Natural English, Explain, Summarize**, plus your own
actions. Rewrites can replace the original text. Text that can't be selected at all (images, scanned PDFs, video) can be
captured with "Region Text".

Needs **Accessibility** permission (to read the selected text). Region Text also needs Screen Recording.

## The action bar

The action bar appears about 0.4 seconds after you select text and release the mouse. It's just buttons: **nothing runs
until you click one**.

- If you press ⌘C (or any key) or the clipboard changes in those 0.4 seconds, it doesn't appear — selecting just to copy
  isn't interrupted.
- It goes away when you click elsewhere, start typing, scroll, or leave it alone for 4 seconds (with the mouse off the bar).
- "Rewrite ▾" lets you pick the tone right away: More Formal / More Casual / More Concise.
- "⋯" on the right opens settings, where you can add actions and change their order.

| Action | What it does | Result |
|---|---|---|
| Translate | Translates the selection | Translation; read aloud or copy |
| Learn | Phonetics, pronunciation and meaning — learn the word or sentence | See "Learn" below |
| Polish | Fixes typos, grammar and punctuation without changing the meaning | Can replace the original |
| Rewrite | Rewrites more formal, more casual or more concise | Can replace the original |
| Natural English | Turns it into natural English you can send (Slack, email, PRs) | Can replace the original |
| Explain | What a term, code or error message means | Shown only |
| Summarize | 3–5 key points | Shown only |

## The result panel

Click an action and the bar expands into a result panel:

- The same row of actions stays on top, the current one highlighted. Click another to switch results in place; results are
  remembered, so switching back doesn't run it again.
- Rewrite-type actions (Polish, Rewrite, Natural English, and custom actions whose result type is "Rewrite"): the main button
  is "Replace ⏎", with "Copy" beside it.
- Other actions: the main button is "Copy".
- There are also "Regenerate" and read-aloud buttons. The footer shows which model ran and how many seconds it took; when a
  cloud model failed and the local one stepped in, it says "Cloud service unavailable, using the local model instead."

### Replacing the original

"Replace ⏎" only appears for rewrite-type actions, and only when the selected text is in an **editable text field**. Text
borrowed through the clipboard (terminals), captured with Region Text, or read-only text such as a web page can only be
copied — pasting several lines into a terminal could run them.

Before replacing, Baobox checks the selection again. If it no longer matches (you edited it or moved elsewhere), nothing is
replaced; the result is copied instead with "The selection changed, so nothing was replaced. Copied instead." To undo a
replacement, press ⌘Z in that app.

## Translate

- The source language is detected automatically. "Translate into" sets the target, "If already in that language, translate
  into" sets the fallback: with Chinese as the target and English as the fallback, foreign text goes to Chinese and Chinese
  goes to English. You can switch the target right in the popup.
- Read the original or the translation aloud, or copy the translation. Turn on "Speak the translation automatically" to have
  it read every time.
- The engine is chosen in the "Translation Engine" group, "Automatic" by default: System Translation from macOS 15, switching
  to the offline translation model (Tencent Hunyuan Hy-MT2, 33 languages, download once, works offline) for languages the
  system can't translate or when it fails. On macOS 14 only the offline model works; the popup offers the download.

## Learn

It follows "My native language" and "Language I'm learning" in settings (Chinese and English only for now; native Chinese,
learning English by default):

| You selected | You get |
|---|---|
| 1–3 words in the language you're learning (English) | A **dictionary card**: the word, phonetics, US / UK pronunciation buttons, Slow, meanings, word forms ("became" is the past of "become"), and the sentence it came from |
| A sentence or paragraph in that language | **Sentence study**: click any word for its phonetics and meaning ("Details" opens the dictionary card); read aloud at 0.5× / 0.75× / 1× in a US or UK voice with the current word highlighted; a translation into your native language; **Repeat** |
| Your native language (Chinese) | First how to say it in English, then that English sentence as in the row above (clickable words, read aloud, Repeat) |
| Chinese selected while you're learning Chinese | Pinyin, read aloud, and a translation |

- **Repeat**: click "Repeat" and read the sentence aloud. On-device speech recognition compares it: words you got right turn
  green, the rest red, and you see "N of M words right". It needs Microphone and Speech Recognition access, and can't run while
  a meeting recording or Dictation is using the microphone.
- **Offline English–Chinese Dictionary**: phonetics, meanings and word forms come from the open-source ECDICT. Download it
  once in the "Learn" group of the settings (about 66 MB, turned into a local index afterwards). Without it, Learn shows a
  translation and pronunciation only.

## Region Text

Menu → "Region Text…" or the "Region Text" shortcut: the screen freezes, you drag out an area, the text in it is recognized
on this Mac, and the action bar appears for that text. Works for images, scanned PDFs, video frames and games. Needs Screen
Recording permission; restart Baobox after granting it.

## Keyboard

- **Hold ⌥ to pick actions by number**: while the action bar or result panel is up, hold ⌥ to see numbers on the buttons;
  ⌥1–⌥9 pick one.
- **Show Action Bar** (a shortcut, unbound by default): shows the action bar for the selection in keyboard mode. Letters jump
  to an action (T Translate, L Learn, P Polish, R Rewrite, E Natural English, X Explain, S Summarize; numbers for custom
  actions), ← → move, Return runs, Esc closes. Those keys are only taken while the bar is up.
- **One key, straight to the result**: "Translate Selection" and each built-in action have their own shortcut ("Selection:
  Learn" and so on). Select text, press it, and the result appears without the action bar. All unbound by default.

## Custom actions

Settings → Actions → "New Action", then fill in:

- **Name**;
- **Prompt**: `{text}` stands for the selected text; without it, the text is added at the end;
- **Result**: Rewrite (can replace the selection) / Answer (show only).

Built-in actions can be turned off and reordered too (except Translate). The list's order, top to bottom, is the bar's order,
left to right; the first nine on the bar match ⌥1–⌥9.

## Which model the AI actions use

Polish, Rewrite, Natural English, Explain, Summarize and custom actions use the model chosen on the "Selection AI Actions" row.
The default is the local Qwen3-1.7B (the same one used for caption correction and dictation polish). Download it once on the
"Local AI model" row; the first start takes a few seconds.

- If the selection is too long for the local model, you're told so; nothing is cut off silently. With a cloud model set up,
  "Use the Cloud This Time" sends just this one.
- You can also pick a larger local model or a cloud model. With a cloud model, text is sent **only when you click an action**;
  just selecting text sends nothing.
- Translation has its own model setting (the "Selection Translation" row), separate from the AI actions. See [AI](ai.md).

## Menu

| Item | Notes |
|---|---|
| Show Action Bar | Shows the action bar for the current selection (keyboard mode) |
| Translate Selection | Translates right away, without the bar |
| Learn Selection | Opens Learn right away, without the bar |
| Region Text… | |
| Pop Up on Selection | Ticked = appears when you select text; unticked = menu and shortcuts only |
| Selection Assistant Settings… | |

## Settings

Settings → Selection Assistant:

| Group | Setting | Notes |
|---|---|---|
| Trigger | Pop up automatically when text is selected | On by default |
| | After selecting text | Show the action bar (default) / Translate right away / Learn right away |
| | Borrow the clipboard when Accessibility can't read the selection | On by default; see below |
| Actions | The action list | Switch, Move Up / Move Down, Edit, Delete; "New Action" |
| Shortcuts | Hold ⌥ to pick actions by number | On by default |
| | The shortcuts | Show Action Bar, Translate Selection, one per action, Region Text; all unbound by default |
| AI Actions | Selection AI Actions | Which model; the same row as in Settings → AI |
| | Local AI model | Downloading Qwen3-1.7B |
| Languages | Translate into, If already in that language, translate into | |
| | Speak the translation automatically | Off by default |
| Translation Engine | Selection Translation | Automatic (default) / System Translation / a local or cloud model; downloading the offline translation model |
| Learn | My native language, Language I'm learning | 简体中文 / English; they must differ |
| | English pronunciation | US (default) / UK |
| | Read the word aloud when the card appears | Off by default |
| | Offline English–Chinese Dictionary | Download / Delete |
| Permissions | Accessibility, Screen Recording | Granted or not |
| Try It | Show Action Bar, Translate Selection, Region Text… | |

### Borrowing the clipboard

Some apps (many terminals, for instance) don't tell Accessibility what's selected. Baobox then has the app put the selection
on the clipboard with its own Copy command, reads it and restores your clipboard right away; Baobox's clipboard history
doesn't record it. Automatic pop-up only does this after a drag or double-click, and skips it while the clipboard holds a
password.

## Permissions

| Permission | Used for | Without it |
|---|---|---|
| Accessibility | Reading and watching selections, replacing text | The selection can't be read and nothing pops up; Region Text still works |
| Screen Recording | Region Text | Region Text doesn't work; restart Baobox after granting it |
| Microphone, Speech Recognition | Repeat | Repeat doesn't work |

## Data and privacy

- The selected text is read once when the bar appears; it isn't logged or saved.
- AI actions and translation run on this Mac (or System Translation) by default. Text leaves the Mac only when the matching row
  is set to a cloud model: AI actions send only the text you ran an action on, Selection Translation sends the text being
  translated.
- The offline dictionary lives in `~/Library/Application Support/Baobox/SelectionTranslate/` and downloads from GitHub; the
  translation model and other local models live in `~/Library/Application Support/Baobox/Translation/models/`.

## Troubleshooting

- **Nothing pops up**: check Accessibility permission, then whether "Pop Up on Selection" is ticked in the menu. A selection you
  copied with ⌘C right away doesn't pop up, by design.
- **Nothing pops up in a terminal**: make sure "Borrow the clipboard when Accessibility can't read the selection" is on, and
  select by dragging or double-clicking; a plain click doesn't count.
- **No "Replace" button**: replacing needs a rewrite-type action and text in an editable field; otherwise use "Copy".
- **"You selected about … characters"**: the local model handles a limited length at a time. Select a shorter part, or click
  "Use the Cloud This Time".
- **Can't translate on macOS 14**: System Translation needs macOS 15; download the offline translation model under
  "Translation Engine" in the settings.

Technical details: [docs/selection-translate/ASSISTANT.md](../../selection-translate/ASSISTANT.md).
