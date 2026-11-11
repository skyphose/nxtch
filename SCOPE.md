# nxtch scope

nxtch does three jobs from the notch and nothing else: media, a shelf and clipboard history. anything not listed under "in" needs a good reason, and has to fit the budget, before it goes in.

## budget

hard limits. a change that breaks one doesnt ship.

| | limit |
| --- | --- |
| idle cpu, notch closed | about 0% with nothing playing. 2% max while an app is playing (closed-notch meter on) |
| memory | under 80 MB resident with a full clipboard history. a watchdog logs past 150 MB and restarts nxtch past 400 MB |
| dependencies | none. apple frameworks only, one binary, built with `swiftc` from the command line tools |
| helpers | one (`osascript` for now playing), and it quits when nxtch quits |
| network | none. no accounts, sync, analytics, crash reporting or auto-update |
| permissions | only when a feature is used. audio capture, and accessibility only for paste from history |

## in

### media

- now playing: title, artist, progress, the source app's icon, previous / play-pause / next. no permission needed.
- per-app volume 0 - 150%, mute, live level meters. follows the default output device.
- sliders stick to 100%, ⇧ turns that off. one button resets every app to 100%.
- closed: an icon for every playing app on the left (up to four), one meter on the right.

### shelf

- drop anything on the notch. files are referenced. text, links, images and file promises are saved.
- items are temporary. a successful drag out takes them off the shelf, and moves the original file to where you dropped it (⌥ copies instead). a delete zone shows up while you drag.
- tick one or several (a circle on each tile, or the check mark for all) and drag them out together.
- grows down a row at a time, four tiles a row, up to three rows, then scrolls.
- open, show in finder, copy, airdrop, delete, clear. they act on the selection, or on everything without one.
- survives a relaunch. files that disappear drop off the shelf.

### clipboard

- text, images and file references. newest first, pinning, search.
- 100 unpinned items max, each kept 7 days. text up to 50,000 characters, one image up to 20 MB and 50 megapixels.
- skips anything a password manager marks as concealed or transient, anything copied while one is frontmost, and anything arriving from another device.
- history is readable by your user only and kept out of time machine. so is the shelf's own storage.
- one global shortcut (⌃⌥V). click to copy, return to paste.

### the panel itself

- hover or drag to open. it never steals clicks or keyboard focus by accident.
- launch at login, ears on or off, full screen on or off.

## out, on purpose

- widgets: calendar, weather, battery, reminders, timers, system stats.
- a camera mirror, hud rpelacements (volume and brightness overlays), lock-screen stuff.
- album art. it needs either unsigned code loaded into a system program or downloads from each service.
- play/pause per app. i tried it: macos sends media commands to whichever app is now playing, even when the command names a different one.
- lyrics, visualizer skins, themes, custom layouts.
- cloud or sync of any kind. sharing beyond airdrop.
- clipboard: rich text or html beyond plain text, snippets, templates, ocr, editing items.
- shelf: file conversion, compression, renaming.
- mixer: eq, effects, per-app output routing, recording audio.
- plugins or extension points.
- more than one display at a time. nxtch lives on the notch screen.

## maybe later, if it fits the budget

- per-app output device.
- pick your own clipboard shortcut.

## how the budget is kept

measured on one m-series macbook pro running macos 27, notch closed, one app playing audio: nxtch went from about 11% to about 1% cpu, at 71 MB resident.

after the 0.3 cleanup, with zoom holding a silent audio stream open: 0.8% cpu, 15 MB footprint (`footprint`, not resident). thats not the same setup as the line above, so treat it as direction, not a before/after.

- meters are plain `CALayer`s on one shared timer: 30 fps with sound, 4 fps in silence, stopped when none is on screen. five meters cost 30 wakeups a second, not 150. swiftui animation re-laid out the whole panel every frame. that alone was about 10%.
- metering taps only run where a meter is visible. every playing app while the media tab is open, one app (the one in the ears) while closed, none otherwise. each tap also costs cpu in `coreaudiod`. volume taps only exist for apps not at 100%.
- audio state is event-driven: core audio notifications for the process list and each process's output state, with a 5 s safety check.
- no system-wide mouse-move monitor. a 10x/s cursor check does hover and drag detection. system-wide, nxtch only watches clicks.
- cross-process calls are rationned. the drag pasteboard is read only while a mouse button is down. the clipboard change count is read twice a second.
- window state is only touched when it changes (`ignoresMouseEvents`).
- caches are bounded. clipboard rows draw 96 px thumbnails from an `NSCache`, never the full image. history is capped at 100 unpinned items.
- app icons are cached per app. asking for one reads from disk every time.
- the mixer only publishes values that changed, so a refresh with nothing new doesnt redraw the panel.

### what it still costs

- the closed-notch meter keeps one listen-only tap running while any app outputs audio, even silence from an idle browser tab or a call app. about 2% in `coreaudiod`. turning off "activity beside notch" removes it.
- the now-playing helper (`osascript`) uses about 28 MB and about 0.1% cpu. each playback button press starts a short-lived `osascript`.
