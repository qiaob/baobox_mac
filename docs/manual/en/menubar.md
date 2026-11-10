# Menu bar

[简体中文](../menubar.md) · English

Menu bar → **Menu Bar**. When the icons at the top right are too many, hidden behind the notch, or squeezed out
by the front app's menus, tidy them up here: in Baobox Settings, set each icon to Show or Hide. Hidden icons don't
take up menu bar space, and they're one click away in the first row of the Baobox menu.

## Turning it on

Settings → Menu Bar → turn on "Manage the menu bar". It's off by default: once on, Baobox adds an **invisible**
placeholder to the menu bar (you never see or touch it) and uses it to push hidden icons off screen.

It needs two permissions. Baobox's screenshot and window tools already ask for both, so you probably have them:

| Permission | Used for |
|---|---|
| Screen Recording | Remembering what each icon looks like, so the Baobox menu can show it as is |
| Accessibility | Telling which app each icon belongs to; moving icons when you hide or show them; opening hidden icons for you |

## Show / Hide

The settings page lists every icon currently in the menu bar: the icon, its name, and Show / Hide.

- Hide: the icon leaves the menu bar right away and appears in the first row of the Baobox menu.
- Show: it goes back to the menu bar.
- When you change one, Baobox moves just that icon for you; the pointer disappears for an instant and the other icons
  stay put.
- Your choices stick: after an app restarts or the Mac reboots, they're the same (macOS keeps the positions in each app).
- The clock, Control Center and the microphone / camera recording indicator can't be moved and aren't listed; Baobox's
  own icon isn't listed either.
- **An icon that appears for the first time** (a newly installed app's first launch) is placed at the far left by
  macOS and starts out hidden. Set it to Show in Settings to keep it in the menu bar.

## The first row of the Baobox menu

Click the Baobox icon. The first row of the menu (above Screenshot) holds:

- **hidden icons**;
- after a thin divider, **icons squeezed out or behind the notch right now** (turn this off with "Also put
  squeezed-out icons in the Baobox menu row").

They look the same as in the menu bar and show their name on hover. A click works like clicking the icon itself
and opens its menu. For a hidden icon, Baobox moves just that one next to the Baobox icon for a moment, opens its menu,
and moves it back to where it was once the menu closes; the other hidden icons don't move and keep their order. If it
can't be moved, or there's no room even next to the Baobox icon (the front app's menus reach all the way to it), the pet
tells you; no other hidden icons are brought out. With several displays, the icon's menu opens on the display whose menu
bar you clicked the Baobox icon in.

The row doesn't appear when nothing is hidden or squeezed out.

## The Baobox icon's position

By default the Baobox icon sits at the far left, so it's the first to get squeezed out. **When you turn on menu bar
management, Baobox moves itself next to the battery and clock and keeps itself visible at all times**: if it ever ends
up in the hidden area (say you ⌘-dragged it there) or gets squeezed out, it moves back to the right end within a few
seconds — if Baobox were hidden, nothing could bring the other icons back. With management off, you can still move it by
hand with Menu Bar → "Move the Baobox Icon to the Right". Baobox's own temporary icons (the focus countdown, the meeting recording indicator)
appear to its right.

There's also a shortcut, "Open the Baobox Menu" (unbound by default; set it in Settings → Shortcuts). It pops the
Baobox menu up at the pointer when the icon is hidden, or when a full-screen app has the menu bar tucked away. With
several displays, it opens under the Baobox icon on the display the pointer is on.

## Notes

- Turning off "Manage the menu bar" brings every hidden icon back.
- Some apps don't remember their icon's position between launches; their icon lands at the far left (hidden) each
  time, and you can still click it from the Baobox menu.
- In a full-screen app the menu bar is tucked away, so Baobox can't tell what's squeezed out. Icon pictures can only be
  captured while the menu bar is showing; an icon that has never been visible uses its app icon until then.
