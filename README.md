# Logic Click Locate

A tiny menu-bar helper for **Logic Pro on macOS**: a plain **left-click on an empty track lane moves the playhead** there. No Shift needed.

I built it because in Logic Pro 12.4, Shift-clicking an empty track lane no longer moves the playhead (clicking the ruler still works).

## How it works

- It watches left-clicks while Logic is the front app.
- When a click lands on an **empty part of a track lane** (no region under it, no modifier keys, no drag), it clicks the **ruler** at the same horizontal position for you and puts the cursor straight back.
- Clicking regions, marquee/rubber-band drags, and Shift/Cmd/Option/Ctrl clicks are left alone.
- It uses macOS Accessibility to tell an empty lane from a region. It doesn't change or patch Logic in any way.

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
3. Allow it in **System Settings → Privacy & Security → Accessibility → Logic Click Locate**.

To remove it: `zsh uninstall.sh`.

## Known limits

- **English only.** It recognises Logic's lanes and ruler by their English accessibility names, so it won't work if Logic runs in another language.
- **May break with a Logic update** if Apple renames those elements.
- **You may feel a very brief hold of the mouse** right after a locate. It has to click the ruler with the real cursor (Logic ignores clicks sent to it directly), and macOS briefly pauses mouse movement after an app moves the cursor.
- A double-click on an empty lane also moves the playhead on its first click.
- It doesn't check which tool is selected, so a Pencil click on an empty lane also locates.
- After reinstalling, remove the old Accessibility entry and allow it again (each local build has a new signature).

Tested on Logic Pro 12.4, macOS 26, Apple silicon.

## License

MIT. See `LICENSE`. Use at your own risk.
