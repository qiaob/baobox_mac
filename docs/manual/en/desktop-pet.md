# Desktop pet

[简体中文](../desktop-pet.md) · English

Menu bar → **Desktop Pet**. A little companion on your desktop that is also Baobox's unified notification center: meeting
reminders, focus breaks and Claude Code / Codex task updates are all delivered through the pet. Turn it off and
notifications fall back to Notification Center, so nothing is lost.

## Showing and hiding

- Menu → "Hide Pet" / "Show Pet", or Settings → Desktop Pet → "Enable Pet" (on by default).
- The "Show / Hide Pet" shortcut, unbound by default.
- "Hide" in the outer ring of the ring menu.

Appearing, leaving and switching characters are animated: a black hole opens under the pet's feet and it pops out of it /
dives into it. Turn off "Entrance & Exit Animations" if you'd rather not. With "Reduce motion" on in System Settings, it
simply fades in and out.

## Playing with the pet

| Do this | It does this |
|---|---|
| Click | A little move and a line ("Hey!", "I'm here~") |
| Double-click | High five |
| Rub the mouse back and forth over it | A head pat: "That feels nice~" |
| Click or move the mouse while it sleeps | Wakes up and stretches |
| Drag | Moves somewhere else; its bubbles follow |
| Right-click | Opens the ring menu |

The pet falls asleep during do-not-disturb (see "Do not disturb" below) or after you've been away from the computer for 5 minutes.

While a meeting is being recorded, the meeting control bar sits on top of the pet's head; when it's time for a break, the pet
walks to the middle of the screen and rests with you (see [Focus & health](focus-health.md)).

## The ring menu

Right-click the pet and a ring of buttons appears around it:

- **Inner ring**: Focus, Keep Awake, Next Pet, Phone Transfer, Translate, Quiet (one hour), plus one spot for the first tool of
  the outer ring, and "More" last.
- **Click "More"** for the outer ring: Text, Take a Break, Codex, Draw, Meeting, Capture, Clipboard, Translate Area, Record,
  Keyboard Click, Maximize, plus Test Alerts, Settings and Hide. Tools without a shortcut come first; tools with one come after
  (your keyboard already reaches them). Tools that aren't available don't show.
- Toggle buttons say what they'll do next: "Allow Sleep" while Keep Awake is on, "Pause Focus" while focusing, "Stop
  Recording" while recording, and so on.
- When a click has no visible result (turning Keep Awake on or off, pausing focus), the pet tells you.
- Click an empty spot, click another app, or press Esc to close it.

## Notifications

| Style | Examples | How it goes away |
|---|---|---|
| Toast | The pet's lines, confirmations, "5 minutes past the scheduled end" | One line, gone after 3 seconds |
| Card | "Meeting minutes are ready", a finished Claude Code task, the water reminder | Title, text, sometimes buttons; gone after 8 seconds |
| Sticky | Meeting reminders, Claude Code waiting for you, fixed-time daily reminders | Stays until you click a button or ×; the pet waves at you every 25 seconds |

- Up to 3 bubbles stack at once, the newest next to the pet; the rest wait, with "N more" on top.
- Hovering a bubble pauses its countdown.
- Clicking a card without buttons means "open" (for example, jumping to the session it's about); × just closes it.
- To try it: menu → "Send Test Notification" ▸ sends one of each style.

### Do not disturb

At these times ordinary notifications wait and the pet sleeps; afterwards they arrive as one bubble, "N muted notifications":

- menu → "Quiet" ▸ "Quiet for 1 Hour" / "Quiet for Today" ("Turn Off Quiet" ends it); "Quiet" in the ring menu = one hour;
- a full-screen app is in front;
- Baobox is recording the screen, recording a meeting, focusing, or showing a break screen.

Important alerts (meeting reminders, Claude Code waiting for you and the like) still show. So do confirmations of what you
just clicked.

### With the pet off

Notifications go to Notification Center instead, buttons included. The first time you turn the pet off (or start Baobox with
it off), Baobox asks for notification permission.

## Movement and where it stays

- **Movement**:
  - Stay Put: stays where it is;
  - Calm: Find a Quiet Spot and Stay (default): walks to a spot that's out of your way and mostly plays in place, taking a
    step or two every minute or so and moving somewhere new every 10–20 minutes;
  - Normal: strolls more and moves every few minutes;
  - Lively: Wander Around.
- **Keep Out of My Way (Avoid the Window I'm Using)** (on by default): when it covers the window you're using (after you
  switch apps or desktops, or when you click right next to it), it walks away — or dives into a black hole and pops out
  somewhere free. Where you drop it, it stays for 10 minutes.
- **Look at the Screen to Find Blank Areas** (on by default; only with Keep Out of My Way on): when no empty desktop is left,
  it takes a small low-resolution look at the screen to find a blank spot. It uses the Screen Recording permission Baobox
  already has for screenshots and never asks for it; the image is analyzed on this Mac and discarded right away, never saved
  or uploaded.
- **Where it hangs out**:
  - Bottom of the screen (default): walks along the top of the Dock;
  - On app windows too: also stands on top of other apps' windows and lies down there, riding along when you drag the window
    (in Lively it jumps up by itself every few minutes; otherwise only when the window top is a good spot);
  - A custom area: click "Select Area…" and drag out the area; it stays along that area's bottom edge;
  - Stay where I drop it: no gravity; it stays at the height you leave it.
- **Size**: drag the slider.

"On app windows too" only looks at where windows are, never at their titles or contents.

## Characters

- Three built in: Kitty, Puppy, Bunny. Switch under "Current Character", or click "Next Pet" in the ring menu to cycle.
- "More Characters" offers 18 more to download: Shiba Inu, Husky, Fox, Pug, Panda, Rabbit, Frog, Raccoon, Chick, Blob Cat,
  Cube Cat, Cube Dog, Cube Bunny, Cube Pig, Cube Lion, Robot, and two anime-style characters, Toka and Alchemist Girl. Click
  "Download"; it switches over when done. "Delete" removes it again.
- **Your own character**: click "Open Pets Folder", make a subfolder there with a `pet.json` and sprite images, or a single
  `.glb` / `.vrm` model (format: [docs/desktop-pet/PACKS.md](../../desktop-pet/PACKS.md)). Sprite characters only hop and
  say a line when you play with them.

## Menu

| Item | Notes |
|---|---|
| Status line | Pet is on your desktop / Pet hidden |
| Hide Pet / Show Pet | |
| Quiet ▸ | Quiet for 1 Hour / Quiet for Today / Turn Off Quiet (while quiet) |
| Send Test Notification ▸ | Toast (3 s) / Card (8 s) / Sticky with Buttons |
| Desktop Pet Settings… | |

## Settings

Settings → Desktop Pet:

| Group | Setting | Notes |
|---|---|---|
| Pet | Enable Pet | On by default; off sends notifications to Notification Center |
| | Movement | Stay Put / Calm: Find a Quiet Spot and Stay (default) / Normal / Lively: Wander Around |
| | Keep Out of My Way (Avoid the Window I'm Using) | On by default |
| | Look at the Screen to Find Blank Areas | On by default |
| | Entrance & Exit Animations | On by default |
| | Where it hangs out | Bottom of the screen (default) / On app windows too / A custom area ("Select Area…") / Stay where I drop it |
| | Size | Slider |
| Character | Current Character | The art credit is shown below |
| | Open Pets Folder | For your own characters |
| More Characters | One row per character | Download / Delete / Retry |
| Notifications | Sound for Important Alerts | Off by default |
| | Claude Code, Codex, Live Translation Minutes, Focus & Health | Switches for those kinds of notifications; all on by default |

## Data and privacy

- Settings live in UserDefaults; downloaded and custom characters in `~/Library/Application Support/Baobox/Pets/`.
- Notifications aren't written to disk.
- Downloading a character connects to GitHub (falling back to jsDelivr), and the files are checked against their checksums.
  Apart from that, the pet doesn't use the network.

## Troubleshooting

- **The pet is in the way**: Keep Out of My Way is on by default, so switching apps makes it move. You can also drag it
  elsewhere, or set Movement to "Stay Put" and park it in a corner.
- **The pet keeps sleeping**: do-not-disturb is on (Quiet, full screen, screen recording, meeting recording, focus), or you've
  been away for 5 minutes or more.
- **Some notifications don't arrive**: check whether that kind is switched off under Settings → Desktop Pet → Notifications,
  or whether the pet is in Quiet (held notifications arrive together afterwards).
- **A character won't download**: check your network and click "Retry".
- **Can other programs send notifications through the pet?** Not yet. The external interface in the design document
  (socket / command line / URL) hasn't been built.

Technical details: [docs/desktop-pet/](../../desktop-pet/DESIGN.md).
