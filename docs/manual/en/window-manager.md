# Window manager

[简体中文](../window-manager.md) · English

Menu bar → **Window manager**. Moves and resizes the **frontmost window**: halves, quarters,
maximize, center, across displays, restore — 13 actions, all bindable.

Requires **Accessibility** permission, since it manipulates other apps' windows. Without it
the menu shows "Accessibility permission required (click to enable)", which jumps straight
to System Settings.

## The 13 actions and their default bindings

| Action | Default | Notes |
|---|---|---|
| Left half | ⌃⌥← | |
| Right half | ⌃⌥→ | |
| Top half | ⌃⌥↑ | |
| Bottom half | ⌃⌥↓ | |
| Top-left quarter | ⌃⌥U | |
| Top-right quarter | ⌃⌥I | |
| Bottom-left quarter | ⌃⌥J | |
| Bottom-right quarter | ⌃⌥K | |
| Maximize | ⌃⌥⏎ | Fills the visible area — **not** fullscreen (no new Space) |
| Center | ⌃⌥C | Without resizing |
| Move to next display | ⌃⌥⌘→ | |
| Move to previous display | ⌃⌥⌘← | |
| Restore original position | ⌃⌥⌫ | Back to where it was before Baobox moved it |

> ⚠️ **The ⌃⌥ set collides exactly with Rectangle and Magnet.** If you run one of those,
> rebind one side under Settings → Shortcuts, or both apps will respond.

Every binding can be re-recorded or cleared under Settings → Shortcuts.

## Multiple displays

The rules here are explicit:

- The **target screen** is the one with the **largest intersection** with the current window
  — not the one the mouse is on
- Layout is based on each screen's **visible frame**, so the menu bar and Dock are avoided
  and windows never end up underneath them
- Moving across displays maps **position and size proportionally** and clips to bounds.
  Different resolutions and arrangements won't deform or overflow anything

## Window gap

Settings → Window manager → Layout → Gap: the space left around windows and along the
dividing line for halves, quarters, and maximize, in points. Set it to 0 for flush windows.

## Layout snapshots

Save where every window is and restore it later — for the recurring "plug in the external
display / back at my desk" moment.

- **Save**: menu → Window manager → Save current layout…, then name it. It records every
  **regular, non-minimized** window's position and size
- **Restore**: click the layout's name in the menu
- **Manage**: Settings → Window manager → Layout snapshots lists and deletes them, each
  showing "N windows · saved at …"

Matching on restore is **by title first, by order as a fallback**; apps that were running
then but aren't now are skipped without error.

Each window in a snapshot records the **stable UUID of its display and its relative position
on that display**, so a changed resolution or a rearranged setup still lines up.
