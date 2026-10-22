# Logic Click Locate

A tiny menu-bar helper for **Logic Pro on macOS**: a quick plain **left-click on an empty track lane moves the playhead** there. No Shift needed.

I built it because in Logic Pro 12.4, Shift-clicking an empty track lane no longer moves the playhead (clicking the ruler still works).

## How it works

- It checks the mouse button about 100 times a second while Logic is the front app. It doesn't hook into Logic or into the mouse events.
- After a **quick, still tap** (no Shift/Cmd/Option/Ctrl) on an empty part of a track lane, it waits a quarter of a second for a possible second click, then clicks the **ruler** at the same horizontal position and puts your cursor back.
- **Holds, drags, drag-selecting regions, double-clicks and modifier-clicks are ignored**, so editing works as normal.
- **Clicks on regions, track headers, the Library/Inspector, an editor or mixer docked at the bottom, plugin windows and open menus are ignored too.** It works this out by looking at a few small strips of the screen (that's what the Screen Recording permission is for): the ruler row shows where the lanes start, Logic draws a black divider line above a docked editor, and empty lanes are a darker grey than regions.
- It finds the ruler and Tracks area from where Logic's window sits on screen, plus a few offsets you can adjust (see below). It doesn't change or patch Logic in any way.

**Why it never reads Logic's interface:** in Logic 12.4, any app that asks Logic about its interface through macOS Accessibility breaks drag-select and region dragging until Logic is restarted. So this helper deliberately never does that; it reads screen pixels instead.

A menu-bar icon lets you switch it on/off or quit.

## Install

1. Install Apple's Command Line Tools if you don't have them (Xcode itself isn't needed):
   ```
   xcode-select --install
   ```
2. In Terminal, from this folder:
   ```
   zsh install.sh
   ```
   This builds the app from source, puts it in `~/Applications`, and starts it at every login (it also restarts itself if it ever crashes).
3. Allow it in **System Settings → Privacy & Security → Accessibility → Logic Click Locate**. macOS needs this for any app that sends a click; the helper uses it only to click the ruler.
4. Allow it in **System Settings → Privacy & Security → Screen & System Audio Recording → Logic Click Locate**. It only reads a few thin strips of the screen when you click, to see whether you clicked on an empty lane. Without it everything else works, but clicks on regions, track headers or in a docked editor also move the playhead. macOS may ask you to re-confirm this now and then.

To remove it: `zsh uninstall.sh`.

## Adjusting it to your layout

The first run creates `~/Library/Application Support/LogicClickLocate/layout.json`:

| Setting | Meaning |
|---|---|
| `rulerYFromWindowTop` | Height of the ruler's lower half, from the top of Logic's main window |
| `tracksLeftFromWindowLeft` | Taps further left than this are always ignored (the actual lane edge is found on screen) |
| `tracksTopFromWindowTop` | Where the track lanes start vertically |
| `tracksRightMargin`, `tracksBottomMargin` | Edges kept clear (scroll bars) |
| `locateDelay` | Seconds to wait for a possible double-click before locating (default 0.25) |

The defaults were measured on one 3440-wide display with the inspector open. If the playhead doesn't move, or the click lands in the wrong place, adjust these and quit/reopen the helper from its menu-bar icon.

## Known limits

- **Showing/hiding the toolbar or panels above the tracks moves the ruler.** Adjust `layout.json` if that happens.
- A double-click slower than `locateDelay` won't reach Logic as a double-click.
- If you run other tools that read Logic's interface through Accessibility (window managers, automation tools), Logic's drag-select can break until you restart Logic. That's Logic, not this helper.
- After reinstalling, remove the old Accessibility and Screen Recording entries and allow them again (each local build has a new signature).

Tested on Logic Pro 12.4, macOS 26, Apple silicon.

## License

MIT. See `LICENSE`. Use at your own risk.
