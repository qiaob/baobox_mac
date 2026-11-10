# Meeting

[简体中文](../meeting.md) · English

Menu bar → **Meeting**. Records online meetings (microphone + system audio, labeled "Me / Them") or in-person meetings
(microphone only), then writes minutes and collects action items with AI. With your calendar connected it also reminds
you of the next meeting, joins it in one click and notices meetings that are already under way. The former Live
Translate lives here too, as "Free Listening".

Everything stays on this Mac by default.

## Three kinds of recording

| | Online Meeting | In-Person Meeting | Free Listening |
|---|---|---|---|
| For | Zoom, Tencent Meeting, DingTalk, Teams, Feishu, Google Meet and other calls | Meeting face to face | Videos, podcasts, online courses (the former Live Translate) |
| Records | Microphone + system audio (the other side), mixed into one stream | Microphone only | The audio source chosen under Subtitles & Interpreting |
| Speakers | Labeled "Me / Them" | Not labeled | Not labeled |
| Subtitles and translation | Off by default; click "Subtitles" on the control bar | Same | As set under Subtitles & Interpreting; the subtitle bar shows as usual |

Meeting recording, Free Listening and [Dictation](dictation.md) can't run at the same time (they share the microphone).
Starting one while another is running tells you "… is using the microphone. Stop it first."

## Starting a recording

- Menu: "Start Recording an Online Meeting" or "Start Recording an In-Person Meeting".
- The same two buttons sit at the top of Settings → Meeting.
- "Start Recording" or "Join & Record" on a meeting reminder or detection bubble.
- Shortcuts "Start / End Online Meeting Recording" and "Start In-Person Meeting Recording", unbound by default; set them
  under Settings → Shortcuts or on the Meeting settings page.
- "Meeting" in the desktop pet's ring menu (right-click the pet).

The first time, a "Before you record" dialog appears: let everyone in the meeting know it's being recorded and
transcribed, and get their OK. That's up to you: Baobox only reminds you and never notifies anyone. Click
"I've Told Them" to start; it won't ask again.

When you start an online meeting by hand and a calendar meeting is in progress (or starts within 5 minutes), the recording
is linked to it: the title and attendees come from the calendar. In-person meetings aren't linked automatically.

## While recording: the control bar

A small control bar appears; it never takes focus.

- With the pet on, the bar sits **on top of the pet's head** and moves with it (drag the pet to move it). With the pet off it
  sits at the top center of the screen; drag it anywhere and the position is remembered.
- On the left: "● REC" with the elapsed time, and the type (Online / In person).
- **Microphone and speaker icons**: green while there's sound. Click one to stop recording that side (it turns red with a
  slash); click again to resume. The transcript notes the change. This only stops Baobox from recording; people in the
  meeting still hear you. In-person meetings only have the microphone.
- Buttons:
  - **Pause / Resume**;
  - **Mark Key Point**: what was said in the last ~20 seconds gets priority in the minutes;
  - **Notes**: opens a text box; what you jot down is saved with the transcript and used as context for the minutes.
    Esc collapses it;
  - **Subtitles**: shows the subtitle bar with translations (languages and read-aloud follow Subtitles & Interpreting);
  - **End**.

While recording, a red "● 32:15" appears in the menu bar; click it for the Meeting menu.

During a meeting Baobox goes into do-not-disturb: the pet keeps quiet, ordinary notifications wait, and Focus & Health
reminders are held. When the recording is linked to a calendar meeting, you get one gentle note 5 minutes past the
scheduled end.

## Ending and minutes

Click "End" on the control bar, choose "End and Write Minutes" in the menu, or press the
"Start / End Online Meeting Recording" shortcut again.

The transcript is saved first, then AI writes the minutes. When they're done the pet says "Meeting minutes are ready";
click "Open" to see them in the meeting library.

- Minutes have four parts: Summary, Decisions, Action items (owner, task, due date) and Highlights (the key points you marked).
- "Minutes template": Default / Stand-up / 1:1 / Interview. The four parts stay; the focus changes.
- By default the minutes are written by the local model Qwen3-1.7B, offline (download it under "Correction model" in the
  AI Correction group of the Meeting settings, or under Settings → AI → On This Mac). With no usable model, or too little
  content, only the transcript is kept and the status reads "Transcript only"; later you can click "Regenerate Minutes" in the
  meeting library.
- For better minutes, pick a larger local model on the "Meeting Minutes" row of the Meeting settings. You can also pick a cloud
  model; only then is the meeting's full transcript and notes sent to that provider. See [AI](ai.md).
- A meeting in which nothing at all was recorded isn't saved.
- Free Listening isn't saved by default. Turn on "Save transcripts (Markdown)" under Subtitles & Interpreting and each
  session goes into the meeting library too (type "Free"), with key points / decisions / to-dos written after you stop.

## Meeting library

Menu → "Meeting Library". The window has two views:

- **Meetings**: filter by type (All / Online / In person / Free) and search titles, attendees and minutes. Each row shows the
  title, type, time, duration, attendees and minutes status (Recording / Writing minutes / Minutes ready / Transcript only /
  Minutes failed).
  Hover a row or right-click it for: Minutes, Transcript, Copy Minutes, Regenerate Minutes, Export…, Show in Finder, Delete.
  The details on the right have three tabs: **Minutes** (with checkable action items below), **Transcript** (transcript and
  notes) and **Series** (the meetings of the same series in time order).
- **Action Items**: action items from every meeting, grouped "Open / Done". Tick one to complete it; click its source to jump
  back to that meeting. "Copy All Open" and "Export…".

"The same series" means the same recurring calendar event, or the same title (ignoring dates and numbers).

Delete moves the meeting's folder to the Trash, where you can put it back. A meeting that is still recording or writing
minutes can't be deleted.

### This week's report

Menu → "Write This Week's Report": collects the decisions and open action items of this week's (Monday to Sunday) online
and in-person meetings, adds a short AI-written overview, saves it to the meeting library and opens it. With no meetings
this week it just says so. Choose the model for the overview on the "Weekly Overview" row of the Meeting settings.

## Connecting your calendar

Settings → Meeting → Calendar → turn on "Read calendars". macOS asks for calendar access the first time. Baobox reads the
calendars on this Mac (including synced Google, Outlook and other accounts), read-only; nothing leaves this Mac. Tick
the calendars to read below.

Once connected:

- **Next meeting**: the first line of the menu shows "Next: Design review · in 25 min". Turn on
  "Show the next meeting in the menu bar" for a countdown in the menu bar; click it for the Meeting menu.
- **Reminder before a meeting**: 1 minute before (or 5, or off) the pet shows a bubble that stays until you answer: title,
  time, attendees, which calendar it's from, and open action items from earlier meetings. Buttons: "Join & Record" (when
  there's a meeting link) or "Start Recording", "Brief" (when there's a brief), "Ignore".
- **One-click join**: Baobox finds the meeting link in the event's URL, location or notes (Zoom, Tencent Meeting, DingTalk,
  Google Meet, Teams, Feishu, Webex); menu → "Join Next Meeting" opens it. The item is dimmed when there's no link. The
  "Join Next Meeting" shortcut is unbound by default.
- **Meeting brief**: the summary of the last meeting in the same series plus every open action item of that series. Open it
  from menu → "Meeting Brief" or from a reminder; the window has "Join", "Start Recording", "Open Last Minutes" and "Close".
  The menu item is dimmed when there's nothing to show.
- **Pause Meeting Reminders** ▸ For 1 Hour / For Today / Until Tomorrow (no reminders today or tomorrow; back the day after).
  Pausing stops reminders, detection prompts and automatic starts; the menu then offers "Resume Meeting Reminders".

All-day events, cancelled events and meetings you declined don't count.

## Noticing meetings in progress

"Detect meetings automatically" is on by default. Baobox asks whether to record (it only asks, never starts on its own,
and asks once per meeting) when:

- a calendar meeting with a meeting link has started and isn't being recorded;
- a meeting app (Zoom, Tencent Meeting, DingTalk, Teams, Feishu, Webex, FaceTime, WeChat, Slack) starts a meeting: its meeting
  window opens (DingTalk; joining muted counts too), or it uses the microphone for a few seconds;
- a browser uses the microphone on a meeting site (the web versions of Google Meet, Teams, Zoom, Tencent Meeting, Feishu
  Meetings, Webex, Jitsi).

Music and videos don't count, and a browser using the microphone isn't blamed on Slack or WeChat.

The bubble offers "Start Recording", "Ignore" and "Don't Detect This App". Apps you choose not to detect go on the
"Apps not to detect" list, where you can remove them again.

**Start recording automatically for calendar meetings** (off by default): instead of asking, Baobox starts recording (linked
to the event) when a calendar meeting with a link begins, or when a meeting app is using the microphone during a calendar
meeting. If you clicked "Ignore" on a meeting's reminder, that meeting won't start automatically.

## Device check

Settings → Meeting → Recording → Device check → "Test 3 Seconds": records the microphone and system audio for 3 seconds,
shows whether each side heard anything, then plays the mix back. That mix is exactly what recognition hears in an online
meeting. Say something while some audio plays (a video, say). If system audio reads "Can't capture", Screen Recording
permission is missing.

## Menu

| Item | Notes |
|---|---|
| Status line | The next meeting when idle; "● Recording 32:15 · Online Meeting" while recording |
| Join Next Meeting | Opens the next meeting's link; dimmed without a link |
| Start Recording an Online Meeting / End and Write Minutes | Same spot, same shortcut |
| Start Recording an In-Person Meeting | |
| Start Free Listening | While recording a meeting this becomes "Show Subtitles / Hide Subtitles" |
| Meeting Brief | Dimmed when the next meeting has no brief |
| Meeting Library | |
| Action Items | Shows the number still open |
| Write This Week's Report | |
| Pause Meeting Reminders ▸ | For 1 Hour / For Today / Until Tomorrow |
| Meeting Settings… | |

The old "Subtitles & Interpreting" menu and settings page are still there in this version (their first line reads
"Now part of Meeting"); from the next version they live only under Meeting.

## Settings

Settings → Meeting:

| Group | Setting | Notes |
|---|---|---|
| Calendar | Read calendars | Off by default; macOS asks for calendar access when you turn it on |
| | Calendars to read | Tick the ones to read; new calendars are read too |
| | Remind me before a meeting | Off / 1 min before (default) / 5 min before |
| | Show the next meeting in the menu bar | Off by default |
| Detection | Detect meetings automatically | On by default; asks, never starts on its own |
| | Apps not to detect | Apps you stopped detecting; removable |
| Recording | Default type when starting manually | Online Meeting (default) / In-Person Meeting. A reminder's "Start Recording" uses it when the meeting has no link |
| | Start recording automatically for calendar meetings | Off by default |
| | Minutes template | Default / Stand-up / 1:1 / Interview |
| | Meeting Minutes, Weekly Overview | Which model each uses; the same rows as in Settings → AI |
| | Keep meetings | Keep forever (default) / 30 / 90 / 180 / 365 days; older meetings go to the Trash the next time Baobox starts |
| | Meeting library | Where it is; "Open Meeting Library in Finder" |
| | Device check | Test 3 Seconds |
| Shortcuts | Join Next Meeting, Start / End Online Meeting Recording, Start In-Person Meeting Recording, Toggle Live Translate, Mark Key Point, Open Notes | All unbound by default. "Toggle Live Translate" appears as "Start Free Listening" in the Meeting menu |
| Subtitles & Interpreting | All the former Live Translate settings | Free Listening follows all of them; meetings use the speech language and AI correction, plus translation, read-aloud and the subtitle bar once you turn on Subtitles. See [Subtitles & Interpreting](live-translate.md) |

## Permissions

| Permission | When |
|---|---|
| Microphone, Speech Recognition | The first time you record (including Free Listening) |
| Screen Recording | Recording system audio (the other side) in online meetings. macOS delivers system audio through screen capture; after granting it, **restart Baobox** |
| Calendars (full access) | When you turn on "Read calendars" |

## Data and privacy

```
~/Library/Application Support/Baobox/Meetings/
├── <year>/<date time title>/   # one folder per meeting
│   ├── meeting.md              # minutes, notes, transcript
│   └── meta.json               # attendees, action items and more
└── weekly/                     # weekly reports
```

- Only text is kept, never audio.
- Transcripts from the old Live Translate folder were imported into the library by reference and left where they are.
- Transcription uses Apple's speech recognition; how it stays on this Mac is covered under
  [Subtitles & Interpreting](live-translate.md#privacy).
- Minutes and weekly overviews use a local model by default. Only if you pick a cloud model for "Meeting Minutes" or "Weekly
  Overview" is the transcript sent to that provider. Translation, once you turn on Subtitles, uses the model chosen for
  "Caption Translation"; with a cloud model there, every recognized sentence is sent too. See [AI](ai.md).
- The calendar is read-only and never leaves this Mac.

## Troubleshooting

- **"Me / Them" is wrong**: it's judged from the volume of the microphone and the system audio. Speakers let the microphone
  pick up the other side; headphones work better. Sentences it can't tell aren't labeled.
- **The other side isn't recorded**: system audio in online meetings needs Screen Recording permission; restart Baobox after
  granting it. The device check shows it.
- **"… is using the microphone. Stop it first."**: Dictation or Free Listening is using the microphone; stop it first.
- **A transcript but no minutes**: usually no model is downloaded yet, or there was too little content. Download it, then click
  "Regenerate Minutes" in the meeting library.
- **In a meeting but it didn't ask**: for meetings in a browser, the meeting tab has to be the front tab to be recognized. If a
  meeting app joined muted and has no separate meeting window, Baobox asks once you unmute and use the microphone. Screen
  sharing and recording by other apps aren't detected.
- **No reminder before a meeting**: check that "Read calendars" is on, the reminder isn't set to "Off", and meeting reminders
  aren't paused.

Technical details: [docs/meeting/](../../meeting/TECH_DESIGN.md).
