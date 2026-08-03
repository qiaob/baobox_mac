# Keep awake

[简体中文](../caffeinate.md) · English

Menu bar → **Keep awake**. Temporarily stops the Mac from going to sleep — for builds, test
runs, large downloads, anything you leave running.

Built on IOKit power assertions (`IOPMAssertionCreateWithName`). No external commands, no
resident process.

## Using it

The top of the submenu is a **status line**:

- Off
- On · N minutes left
- On · indefinitely

Below it are four presets — **15 minutes / 1 hour / 2 hours / indefinitely** — with the
active one ticked, then "Turn off".

There's also "Start with the default duration", which uses whatever you set under
Settings → Keep awake.

It releases itself when the timer expires, and the remaining time in the menu updates live.

## Settings

| Setting | Notes |
|---|---|
| Duration for menu clicks and quick start | 15 minutes / 1 hour / 2 hours / indefinitely |
| Also prevent display sleep | **Off** by default. When on, the screen stays lit too; changing it **applies immediately to an assertion already in effect** |

By default only system sleep is blocked and the display still turns off — most unattended
runs don't need the screen on.

## Notes

- This tool has **no shortcut** and is menu-only, so it doesn't occupy a key combination
- The assertion is always released when the app quits — Baobox will never leave your system
  permanently awake
- If the system fails to create the assertion you get an alert with the error code, not a
  silent failure
