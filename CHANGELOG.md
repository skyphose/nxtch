# changelog

newest first. every version is a git tag, so `git checkout v0.3.0` gets you that build.

## 0.5.1 - 2026-11-10

shelf ticks instead of modifier clicks, two media fixes, a lighter internal wiring, and screenshots.

- shelf: a circle on each tile ticks it for a multi-drag, replacing ⌘-click and ⇧-click. clicking a tile in the new grid was clearing the selection on mouse up.
- media: the play button goes back to the real state if the app ignored the press. the meter beside the closed notch follows a new now-playing app right away, not up to 5 s later.
- cleanup: plain callbacks instead of combine pipelines, one save when several shelf items go at once, shelf thumbnails freed with their items, a copied image read off the pasteboard once.
- readme: screenshots of the closed notch and all three tabs.

## 0.5.0 - 2026-11-10

no more full xcode, a shelf that grows instead of scrolling, and swiping between tabs.

- builds with the command line tools alone. full xcode isnt needed anymore, for homebrew or by hand. `build.sh` calls `swiftc` directly, since swiftpm in the command line tools fails on recent macos.
- `build.sh` refuses to run with sudo, and wont replace /Applications/Nxtch.app if its a symlink.
- clipboard: the image size check cant overflow, and history writes land in order.
- shelf: a dragged link is only kept if its http, https or mailto.
- shelf: grows down a row at a time, four tiles a row, up to three rows, then scrolls. it used to scroll sideways.
- swipe sideways with two fingers on the open notch to switch tabs.

## 0.4.0 - 2026-11-10

the shelf became a file mover, and the app got a security pass before going public.

- shelf: dragging a file out moves the original. it used to copy. ⌥ copies, ⌘ insists on a move.
- shelf: a file dropped from finder is only referenced, never copied in. select several tiles (⌘-click, ⇧-click, or the check mark) and drag them out together.
- shelf: fixed finder error -8058. nxtch deleted its own copy before finder had moved it.
- clipboard: unpinned items expire after 7 days. pick specific rows to delete. things copied on another device are skipped.
- media: meters take their color from the playing apps' icons. the closed notch shows every app making sound, up to four. a reset button puts every app back to 100%. hold ⇧ to stop a slider sticking at 100%.
- uninstall: `build.sh --uninstall` exists now and leaves nothing behind. the first version of it reset permissions too late and failed silently.
- an app icon, a homebrew formula, and tests for the rules that dont need a notch (`swift test`).
- faster open and close, one shared timer for all meters, clipboard rows built only when visible.

## 0.3.0 - 2026-11-09

- cleanup and security pass: 15 files down to 11, hardened runtime, cleaned file names on the shelf, clipboard history readable by your user only.
- builds with `swift build`. signs with your own certificate when theres one.

## 0.2.0 - 2026-11-09

- notchmixer became nxtch: the shelf and clipboard history joined the mixer.
- fixed the playback buttons doing nothing.

## 0.1.0 - 2026-11-09

- notchmixer: per-app volume, mute and level meters in the notch, with whats playing on top.
