# Screenshot & recording

[简体中文](../screenshot.md) · English

Menu bar → **Screenshot**. The largest tool in Baobox, covering seven things: smart capture,
annotation, pinning, scrolling capture, on-screen OCR, recording, and live drawing — plus a
screenshot history.

Requires **Screen Recording** permission. System quirk: after ticking it in System Settings
you must restart Baobox.

## Smart capture

Default shortcut **⌘⇧2**, or menu → Screenshot → Start capture.

The whole screen enters selection mode, where you have three ways to go:

| Action | Result |
|---|---|
| Move the mouse | The **window** under the cursor is highlighted with its bounds outlined |
| Click | Capture that highlighted window |
| Press and drag | Switches to **region capture**; drag out any rectangle |
| ⏎ | Capture the entire screen |
| Esc | Cancel |

Once a region exists you can keep adjusting it:

- Eight handles resize it
- Arrow keys nudge it **one pixel at a time** (⇧ for ×10) for precise alignment
- The live size is shown next to the selection (e.g. `820 × 460`)
- A loupe follows the cursor, magnifying pixels and showing the coordinates and the color
  under the pointer

**Menus can be captured too.** If a context menu or menu-bar dropdown is open when you press
the shortcut, Baobox freezes the whole screen *before* it activates and the menu closes — so
the menu is still in the shot.

When the capture completes, what happens next depends on your settings: copy to the
clipboard, also save to disk by template, or save only.

### Save settings

Settings → Screenshot → Saving:

- **Save to a folder automatically after capture** — turn it off to only use the clipboard
- **Location** — `~/Pictures/Baobox` by default
- **Filename template** — DateFormatter syntax; `.png` is appended automatically. The
  Chinese default is `截图 yyyy-MM-dd HH.mm.ss`; the English default deliberately has no
  word prefix, because letters in something like `Screenshot` are format specifiers to
  DateFormatter and would come out as garbage
- Two captures in the same second don't overwrite each other — the second gets a suffix

If saving fails (unwritable folder, a TCC-protected directory, a full disk) **you get an
alert**. It never fails silently.

## Annotation

Finishing a capture drops you straight into annotation, with the toolbar next to the selection:

| Tool | Notes |
|---|---|
| Rectangle | Outline |
| Ellipse | Outline |
| Arrow | For pointing things out |
| Pen | Freehand |
| Highlighter | Semi-transparent, thick |
| Mosaic | Paint over sensitive areas |
| Text | Click and type |
| Eraser | Removes a **whole stroke** with one click (it isn't a partial rubber) |

- Color and **thickness / font size** are adjustable
- **Undo ⌘Z** / **Redo ⇧⌘Z**
- **Copy and finish ⏎** / **Save ⌥⏎** / **Cancel Esc**

The toolbar also hosts three cross-feature entry points: **Pin**, **OCR**, and
**Scrolling capture**.

## Pinning

Keep a captured image floating **above every window** — handy for referencing a design while
you write code.

- Annotation toolbar → Pin, or screenshot history → Pin to screen
- Menu → Screenshot → Pins → **Pin from clipboard** (copy an image first)
- Menu → Screenshot → Pins → **Close all pins**

Right-click a pinned image:

| Item | Notes |
|---|---|
| Copy image | Back to the clipboard |
| Save as… | Write it to a file |
| Recognize text | Run OCR on this pin |
| Opacity | Adjust transparency |
| Reset size | Undo scaling |
| Close pin | Close this one |

Pins can be dragged and resized; anything larger than the screen is scaled to 80% of the
visible area.

## Scrolling capture

For capturing a page taller than the screen.

1. Frame a **scrollable area** during capture (a browser's content area, say)
2. Click "Scrolling capture" in the annotation toolbar
3. Once the control bar appears, **scroll the page yourself** — Baobox aligns adjacent
   frames by their overlap and stitches them
4. The control bar shows the stitched height live
5. Click Finish, or menu → Screenshot → Finish scrolling capture

A **preview window** opens with four actions: save, copy, pin, and OCR.

If nothing was stitched you get a clear message — usually it means the framed area wasn't
actually scrollable, or the page wasn't scrolled while the control bar was up.

## On-screen OCR

Pull text off the screen. Recognition runs **locally through the system Vision framework —
nothing is uploaded**.

Entry points:

- A shortcut (unbound by default; assign your own)
- Menu → Screenshot → Recognize text
- Annotation toolbar → OCR
- Right-click a pin → Recognize text
- Scrolling capture preview → OCR

Selection works exactly like capture: **click a window** for the whole window, **drag** to
frame a region.

The result window is **editable before you copy** — a couple of misread characters don't
mean starting over. QR codes and barcodes in the frame are decoded alongside the text.

Settings → Screenshot → OCR:

- **Recognition languages** — English only / Chinese + English / Chinese + English + Japanese.
  **Fewer languages usually means better accuracy**
- **Copy directly without showing the result window** — for when speed matters more

## Recording

Default shortcut **⌃⇧R**, or menu → Screenshot → Start recording. Press the shortcut again
to stop.

Selection is identical to capture: click for a window, drag for a region, ⏎ for the whole
screen.

A **confirmation bar** then appears where you can toggle system audio and microphone for
this recording before clicking Start.

The floating HUD while recording offers **pause / resume**, **stop**, and
**cancel (discard)**. Pause and stop are in the menu too.

Settings → Screenshot → Recording:

- **Output format** — MP4 or GIF. GIF has no audio, caps at 10 fps, and is scaled to 720px
  wide; it suits short clips
- **Record system audio** — no extra permission needed
- **Record microphone** — asks for permission the first time; the audio goes into a
  **separate second track**. If permission is denied you're told once and the recording
  continues without microphone audio
- **Mix down to a single track** — when recording both sources, mixing them means every
  player produces sound (some only play the first track)

## Live drawing

Draw straight onto the **live screen** without capturing anything — for demos and
explanations. The shortcut is unbound by default; menu → Screenshot → Screen drawing.

Toolbar:

| Button | Notes |
|---|---|
| Pass-through mode | **Strokes stay on screen while you use the app underneath** — the key to drawing and working at once |
| Resume drawing | Switch back from pass-through |
| Clear | Erase everything |
| Save frame (with strokes) | Save the current screen including your drawing |
| Exit (Esc) | End the session |

Settings → Screenshot → Screen drawing:

- **Canvas scope** — all displays or current display only. With "current display only" the
  canvas only swallows clicks on the screen the mouse is on; other screens stay usable.
  Takes effect the **next** time you start drawing
- **Show a preview window after saving** — on: saving ends the session and opens a preview
  (save / OCR / pin / copy). Off: it silently copies to the clipboard and saves per your
  settings, and **drawing continues uninterrupted**

## History

Menu → Screenshot → History lists recent captures (20 by default, configurable).

Each has a submenu: **Copy**, **Pin to screen**, **Save as…**, **Delete**. There's a
"Clear history" at the bottom.

History and "files saved to disk" are **independent**: even with auto-save off, every
capture (copy / save / pin) goes into history so you can get it back. "Save as…" uses the
entry's **own timestamp**, not the moment you saved it.

The retention count is under Settings → Screenshot → History.
