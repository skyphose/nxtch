# changelog

newest first. every version is a git tag, so `git checkout v0.3.0` gets you that build.

## 0.6.3 - 2026-11-11

a mixer that keeps up again, hover on the icons, an about window, and an intel build.

- fixed: the mixer could be 30 s late when an app started or stopped playing. my miss in 0.6.2. nxtch listened for a notice macos never sends, and a 5 s re-check had been hiding that until i slowed it to 30. it listens for the one macos does send now.
- resting on the icons or the meter beside the notch opens it, not just the notch itself. a click there no longer reaches the menu bar item underneath.
- about nxtch in the gear menu: icon, version, a link to the latest release. still no network code. the link opens your browser.
- clipboard rows lift under the pointer, dip on press and pop when copied.
- the audio question comes when nxtch opens, not when something first plays, and the notch no longer freezes until you answer it.
- the notch is on screen 0.3 s after launch. it used to wait 1 - 2 s for the audio taps when music was playing.

- lighter at rest: an invisible window the size of the notch tells nxtch the pointer arrived, so the routine pointer check runs once a second. 1 wakeup a second at rest, down from 3. with music playing nothing changed. the cost: hovering while another app's menu is open can take up to a second.
- one app for apple silicon and intel, 1.4 MB. the intel half has never been run, i dont have one.
- macs without a notch: the pill sits on the menu bar's screen, as tall as the menu bar. the icons beside the notch and the open width follow the notch size. checked at four pretend sizes, not on a second mac.
- a guess: on one macbook air on macos 26.6 the notch drew a step behind, shut while open and open after closing. i couldnt reproduce it. nxtch now redraws right after it opens or closes. unproven.
- if macos refuses the tap-only audio device from 0.6.2, the meter goes back to the 0.6.1 way. that fallback has never fired on my mac.

## 0.6.2 - 2026-11-11

lighter at rest and while music plays, a meters switch, a shortcut picker, and fixes from a second audit.

- clipboard: pick the shortcut in the gear menu - ⌃⌥V, ⌃⌘V, ⌃⇧V or off. shown in the search field.
- shelf: a mail attachment could still move out in 0.6.1. my miss - the drag left the choice to finder, and finder moves on the same disk. copy only now. links and a lowercase `library` cant hide it either.
- releases: the job that runs the build has no write access. a separate job, running none of the repo's code, publishes and attests. the readme's verify command checks the exact tag now, not any build.

- fixed: with two apps playing, the meter beside the closed notch could sit flat after the now-playing app changed. the view wasnt told its tap had moved.
- meters read the levels 10 times a second and glide between readings, down from 30 redraws a second. fewer wakeups. cpu about the same in my runs, so no claim there.
- smaller: clipboard rows only rebuild when their own state changes, app icons are only loaded for apps that are shown, the progress line stops ticking while paused.
- a meter's audio tap no longer opens a silent stream to your speakers. macos's audio service does about 1 point less cpu while music plays (7.3% -> 6.4% across two runs each).
- level meters can be turned off in the gear menu. off also stops the audio taps that feed them.
- lighter: the now-playing helper waits for macos to say something changed instead of checking every second. measured at rest: 0.05% cpu and 1.7 wakeups a second, down from about 0.5% and 29. it shows changes sooner too.
- lighter: the cursor check slows to 3 a second when the pointer is far from the notch. the clipboard check runs once a second, the audio safety refresh every 30 s. the app binary is 0.67 MB, half what it was.

## 0.6.1 - 2026-11-11

mail attachments stay in mail, a memory watchdog, and the first signed tag.

- memory watchdog: once a minute nxtch reads its own memory. past 150 MB it logs a warning, past 400 MB it logs a fault and restarts itself. never in the first 10 minutes after launch, so a fast leak cant loop it.
- leak check: none. `leaks` found 0 at idle and after 4 minutes of use. memory went 21 -> 34 MB the first time the notch opened, then stayed flat. that first open is swiftui and the system fonts and icons setting up, not nxtch's own data.
- clipboard: the empty tab says "No history".
- shelf: files another app keeps (in `~/Library`, inside a package, or in a folder you cant write to) only copy out now. dragging them out used to move them, taking a mail attachment out of mail.

## 0.6.0 - 2026-11-10

a download instead of homebrew, and the repo goes public.

- install: download the zip from the releases page. github builds it from the version tag, not my laptop, and each zip carries an attestation you can check with `gh attestation verify`.
- macos asks you to allow the zip once under privacy & security. building it yourself still skips that.
- homebrew is gone. its formula couldnt pin the exact commit it built, and `build.sh` loses the two settings only homebrew used.

## 0.5.2 - 2026-11-10

fixes from a last security audit before going public. none are critical, all need another program already running as you, or a bad setting.

- shelf: a delete can no longer follow a symlink. if the shelf folder was swapped for a link to, say, Documents, clear would have deleted a file there.
- shelf: a saved list that wont load no longer makes nxtch delete every file it saved. a copied-out file now waits 10 minutes before its delete, not 60 s, so a slow copy can finish.
- clipboard: something copied while a password manager was briefly in front is skipped, as is anything that changed while it was being read. images history lost track of are deleted at launch.
- clipboard: every kind of line break shows in a row's preview, so text after a hidden \r cant sit out of sight.
- saved volumes are range-checked on load. `build.sh` only removes or runs a real Nxtch.app with nxtch's bundle id.
- the shelf's storage is kept out of time machine, like the clipboard's.

## 0.5.1 - 2026-11-10

shelf ticks instead of modifier clicks, two media fixes, a lighter internal wiring, and screenshots.

- shelf: each tile has a circle to tick it for a multi-drag. ⌘-click and ⇧-click are gone. 0.5.0 shipped them broken: in the new grid, a click on a tile also cleared the selection on mouse up.
- media: the play button goes back to the real state if the app ignored the press. the meter beside the closed notch follows a new now-playing app right away, not up to 5 s later.
- cleanup: plain callbacks instead of combine pipelines. several shelf items leaving at once cost one save, and their thumbnails are freed. a copied image is read off the pasteboard once.
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
