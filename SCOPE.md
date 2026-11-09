# nxtch scope

nxtch does three jobs from the notch and nothing else: **media**, a **shelf** and **clipboard history**.
Anything not listed under "In" needs a good reason, and has to fit the budget, before it goes in.

## Budget

These are hard limits. A change that breaks one doesn't ship.

| | Limit |
| --- | --- |
| Idle CPU, notch closed | ≈ 0% when nothing is playing; ≤ 2% while an app is playing (closed-notch meter on) |
| Memory | < 80 MB resident with a full clipboard history |
| Dependencies | none: Apple frameworks only, one binary, built with `swiftc` |
| Helpers | one (`osascript` for now-playing), which quits when nxtch quits |
| Network | none: no accounts, sync, analytics, crash reporting or auto-update |
| Permissions | only when a feature is used (audio capture; Accessibility only for paste from history) |

## In

**Media**
- Now playing: title, artist, progress, source app icon, previous / play-pause / next (no permission needed)
- Per-app volume 0–150%, mute, live level meters, follows the default output device

**Shelf**
- Drop anything on the notch: files are referenced, while text, links, images and file promises are saved
- Items are temporary: a successful drag out takes them off the shelf; a Delete zone appears while dragging
- Open, Show in Finder, copy all, AirDrop all, delete, clear
- Survives relaunch; files that disappear drop off the shelf

**Clipboard**
- Text, images and file references; newest first; pinning; search
- 100 unpinned items max; one image up to 20 MB
- Skips anything password managers mark as concealed or transient
- One global shortcut (⌃⌥V); click to copy, Return to paste

**Shell**
- Hover or drag to open; never steals clicks or keyboard focus by accident
- Launch at login, ears on or off, full-screen on or off

## Out (on purpose)

- Widgets: calendar, weather, battery, reminders, timers, system stats
- Camera mirror, HUD replacements (volume and brightness overlays), lock-screen features
- Album art (it needs either unsigned code loaded into a system program or downloads from each service), lyrics, music visualizer skins, themes, custom layouts
- Cloud or sync of any kind; sharing beyond AirDrop
- Clipboard: rich-text or HTML fidelity beyond plain text, snippets or templates, OCR, editing items
- Shelf: file conversion, compression, renaming, multi-select or batch rename
- Mixer: EQ, effects, per-app output routing, audio recording
- Plugins or extension points
- Multiple displays at once (nxtch lives on the notch screen)

## Maybe later (if it fits the budget)

- Per-app output device
- A setting to remove shelf items after they're dragged out
- Choose the clipboard shortcut

## How the budget is kept

Measured on an M-series MacBook Pro running macOS 27, notch closed, one app outputting audio:
nxtch went from about 11% to about 1% CPU, at 71 MB resident.

- **Meters** are drawn with plain CALayers on their own timer (30 fps with sound, 4 fps in silence),
  not SwiftUI animations. Those re-lay-out the whole panel every frame.
- **Metering taps run only where a meter is visible**: every playing app while the Media tab is open,
  one app (the one in the ears) while closed, and none otherwise. Each tap also costs CPU in `coreaudiod`.
  Volume taps exist only for apps not at 100%.
- **Event-driven audio state**: Core Audio notifications for the process list and each process's
  output state, with a 5 s safety check.
- **No system-wide mouse-move monitor.** A 10×/s cursor check does hover and drag detection. System-wide,
  nxtch only watches clicks.
- **Cross-process calls are rationed**: the drag pasteboard is read only while a mouse button is down;
  the clipboard change count is read twice a second.
- **Window state is touched only on change** (`ignoresMouseEvents`).
- **Caches are bounded**: clipboard images go in an `NSCache` with a count limit, and history is capped
  at 100 unpinned items.

### Known costs

- The closed-notch meter keeps one listen-only tap running while any app outputs audio, even silence
  (an idle browser tab or call app): about 2% in `coreaudiod`. Turning off "Show Activity Beside Notch"
  removes it.
- The now-playing helper (`osascript`) uses about 28 MB and about 0.1% CPU. Playback buttons start a short-lived `osascript` per click.
