# Focus & health

[简体中文](../focus-health.md) · English

Menu bar → **Focus & Health**. A focus timer (Pomodoro) and health reminders in one tool: focus covers the stretches of
work, reminders and breaks cover the gaps in between. Reminders come from the [desktop pet](desktop-pet.md); when it's time
for a break, the pet walks to the middle of the screen, grows big and rests with you.

## Focus timer

- **Start**: menu → "Start Focus (25 min)" uses the default length; "Focus for…" ▸ offers 25 / 50 / 90 minutes.
- **While focusing**: the pet sleeps, other notifications wait, and health reminders are held until the focus ends. A
  countdown appears in the menu bar; click it for the same menu.
- **Pause / Resume**: pausing leaves do-not-disturb and reminders work as usual; resuming continues the countdown.
- **End Early** ▸: "Count as Done" counts the round and starts the break; "Discard" counts nothing and skips the break.
- **After a round**:
  - a normal round: a card "Focus round N done!", a 5-minute short break (counting down in the menu bar), buttons
    "One More Round" and "End";
  - a focus of 50 minutes or more, or every 4th round: straight into a long break (break screen, 15 minutes by default).
- **When the break ends**: the pet asks "Break's over! Ready for the next round?" with "Start" and "End". Settings can start
  the next round automatically instead.
- Reminders held during the focus are folded into the break's text ("Also: have some water") and count as given.

The "Start / Pause Focus" shortcut starts a focus with the default length when idle and pauses / resumes one in progress;
it's unbound by default. The desktop pet's ring menu has "Focus" too, and its title follows the state ("Pause Focus",
"Resume Focus"). Pausing makes the pet show a card "Focus paused · 12:34 left" with "Resume" and "End This Round"; ending
counts as done.

## Health reminders

Four presets, all of which you can change, turn off or delete ("Restore Presets" brings them back):

| Reminder | Default | How it reminds you |
|---|---|---|
| Drink Water | Every 60 min (time at the computer) | Pet reminder. Due together with Stand Up it becomes one: "Get up and have some water" |
| Stand Up | Every 60 min | Pet reminder |
| Eye Rest 20-20-20 | Every 20 min | Light nudge: "Look into the distance for 20 seconds" |
| Break | Every 50 min | Break screen, 5 minutes |

All four have "Being away from the computer counts as done" ticked.

Three ways to remind:

- **Light nudge**: the pet does a little move and shows a small bubble that goes away by itself after a few seconds; no buttons.
- **Pet reminder**: a card with "Done" and "In 10 min". Left alone for 8 seconds it goes away and counts as missed; it
  won't chase you. The item restarts its timer as soon as the reminder is shown.
- **Break screen**: a strong reminder with a break length; see "Break screen" below.

For reminders at set times, such as medicine: "Add Reminder", set Repeat to "Daily at a set time", one reminder per time. It
shows as a bubble that stays until you dismiss it, once a day, within 4 hours after the time and while you're at the computer.

### How time is counted

- **Time at the computer**: counts only while you're at the computer (keyboard or mouse used in the last 2 minutes, or a
  video or slideshow playing). Time away doesn't count.
- **Clock time**: follows the clock. If you're away when it's due, it waits until you're back.
- **Being away from the computer counts as done**: after you've been away long enough, the item counts as done and starts
  over (5 minutes for pet reminders, at least 2 minutes for break screens and light nudges). Sleep counts too. Watching a
  video doesn't count as away.
- **Work hours only**: these reminders only appear within your work hours (9:00–18:00 on workdays by default).

### One rhythm

Each item keeps its own timer, but when to interrupt you and how much to say at once is planned together, so reminders
don't come one right after another:

- anything else due soon is folded into the same reminder;
- a small one waits when a bigger break is less than 10 minutes away;
- a break also counts as getting up, drinking water and resting your eyes;
- two reminders are at least 15 minutes apart (adjustable, 10–30). Fixed-time reminders such as medicine are never moved.

With the four presets and three hours at the computer, that's roughly: a short rest at 20 min → a big break at 50 min (water,
standing and eyes folded in) → a short rest at 75 min → a big break at 105 min → …

### Do not disturb

When a reminder is due while you're in a meeting (the microphone is in use, or Baobox is recording a meeting), a full-screen
app is in front, Baobox is recording the screen, or the pet is quiet, it waits and comes once that's over. A break held back
for more than 45 minutes won't suddenly cover the screen; it becomes a card instead,
"You've been busy for a while — take a moment to move", with "Done" and "Rest Now".

## Break screen

When a break is due, the pet walks from where it is to the middle of the screen, growing as it goes; the screen dims, and
below the pet are a title, a countdown and buttons. During the break the pet lies down (or gazes into the distance for eye
rest). When the countdown ends it gets up, stretches, says "Break's over!" and walks back.

With Standard and Strict, a card "Break in 1 minute" comes a minute early, with "Rest Now".

Three strengths (pick one in settings; Standard by default):

| Strength | What it looks like | Postpone | Skip |
|---|---|---|---|
| Relaxed | The pet shows a bubble where it is; no break screen, nothing interrupted | Yes: "In 5 min", up to 2 times per break (0–5) | Just ignore it |
| Standard | The pet walks to the middle and grows big; all screens dim; keyboard and mouse are paused | No | Hold for 3 seconds |
| Strict | Like Standard, plus the background is blurred so nothing on screen is readable | No | Hold for 3 seconds |

- Click the dimmed area to get back to work and the pet shakes its head: "Not done resting yet~".
- Several displays: the pet goes to the display with the mouse; the others just dim and show a small countdown.
- If you're typing or holding the mouse button, the screen waits for you to finish (up to 15 seconds).
- While the full-screen cover is up, ⌘Tab, three-finger swipes between desktops and Mission Control are blocked. Force Quit
  (⌘⌥Esc) isn't blocked; it stays as an escape hatch.
- With the pet off: Standard fills the screen with a background instead (Teal / Dusk / Forest gradients, or your own image);
  Strict still blurs. Pet reminders become system notifications with the same buttons.

### Confirming it's you before the cover goes away

With Standard and Strict, "Confirm It's Me Before a Full-Screen Break Goes Away" is on by default: however the break screen
ends (time's up, hold to skip, or ending it from the menu), the cover stays until you confirm with Touch ID right on the card.
If no one confirms within 30 seconds (you're away), or this Mac has no Touch ID, the Mac locks itself and you come back with
your password. That way a break ending while you're away doesn't leave the screen open to passers-by.

Baobox locks the screen by pressing ⌃⌘Q for you, which needs Accessibility permission.

### Take a break now

Menu → "Take a Break Now", the "Take a Break Now" shortcut (unbound by default), or "Take a Break" in the ring menu: one break
right away, as long as the "Break" reminder. On Relaxed it's a break screen that doesn't dim or block anything; one click skips
it. Not available during a focus or a break.

## Menu

| Item | Notes |
|---|---|
| Status line | "Next: Drink Water · in 12 min"; while focusing, "Focusing · 18:20 left" |
| Start Focus (25 min) | Default length; becomes "Pause Focus" while focusing and "Resume Focus" while paused |
| Focus for… ▸ | 25 / 50 / 90 Minutes (when idle) |
| End Early ▸ | Count as Done / Discard (while focusing) |
| Start Next Round, End Break | During a break |
| Take a Break Now | When idle |
| Pause Reminders ▸ | For 1 Hour / For Today; becomes "Resume Reminders" while paused |
| Focus & Health Settings… | |

## Settings

Settings → Focus & Health:

| Group | Setting | Notes |
|---|---|---|
| Focus | Default length | 15 / 25 (default) / 30 / 45 / 50 / 60 / 90 min |
| | Short break, Long break | 5 min (1–30) and 15 min (5–60) by default |
| | Long break every N rounds | 4 by default (2–8) |
| | Start the next round automatically after a break | Off by default |
| Reminders | Health reminders | Master switch, on by default; doesn't affect the focus timer |
| | Each reminder | A switch on the left; expand it to edit Name, Repeat (Every few minutes / Daily at a set time), the interval or Time, Count (Time at the computer / Clock time), Show as (Light nudge / Pet reminder / Break screen), Break length, Work hours only, Being away from the computer counts as done, or Delete it |
| | Add Reminder, Restore Presets | |
| | At least N minutes between reminders | 15 by default (10–30) |
| Break Screen | Strength | Relaxed / Standard (default) / Strict |
| | Postpone up to N times per break | Relaxed only; 2 by default |
| | Confirm It's Me Before a Full-Screen Break Goes Away | Standard and Strict only; on by default |
| | Background when the pet is off (Standard) | Teal / Dusk / Forest / Image… |
| | Preview | Demonstrates the current strength: a sample bubble on Relaxed, a 10-second break screen on Standard and Strict |
| Work Hours | Starts, Ends, Workdays only | 9:00–18:00, workdays only, by default |
| Do Not Disturb | | An explanation only; no switches |

## Where data lives

`~/Library/Application Support/Baobox/FocusHealth/`: `items.json` (your reminders) and `state.json` (a focus in progress,
today's rounds, each reminder's progress). Timers carry on after Baobox restarts; if a focus ran out more than 10 minutes ago
while the app was closed, it counts as one round and no break is added. Everything stays on this Mac.

## Troubleshooting

- **A reminder didn't come**: it may be waiting (meeting, full screen, screen recording, pet quiet), or the rhythm moved it a
  little later. The first line of the menu shows when the next one is due.
- **Does it work with the pet off?** Yes. The break screen fills the screen with a background, and reminders come as system
  notifications (Baobox asks for notification permission the first time) whose buttons still work.
- **The Mac locked after a break**: with "Confirm It's Me" on, the Mac locks when no one presses Touch ID within 30 seconds.
  Turn it off in settings if you don't want that.
- **"Couldn't lock the screen after the break"**: locking needs Accessibility permission; grant it under Settings → General →
  Permissions.

Technical details: [docs/focus-health/](../../focus-health/TECH_DESIGN.md).
