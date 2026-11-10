# nxtch

<img src="Resources/icon.png" width="128" alt="nxtch icon">

the macbook notch is a black bar that does nothing. nxtch makes it do three things: per-app volume and whats playing, a shelf for files, and clipboard history.

the name is "no notch" with the o knocked out.

## before you install

- macos 14.2 or later. process taps arrived in 14.2. ive only run it on macos 27.2, on one m-series macbook pro. 14.2 is the floor on paper, not something i tested.
- a mac with a notch. on other displays it falls back to a small pill at the top center. untested, i dont have one.
- full xcode. the command line tools alone cant build it anymore: swiftpm and swiftui's `@State` macro dont work there on recent sdks.

## who its not for

- you want album art. theres none, on purpose. getting it means loading unsigned code into a system program or downloading it from each service. you get the app icon instead.
- you live on an external display. nxtch sits on the notch screen only.
- you need rich text out of your clipboard history. it keeps plain text, images and file references.
- you copy passwords out of a browser extension or a terminal. those look like any other text, so they sit in the clipboard history for up to 7 days unless you delete them.
- you dont want an app that leans on private api. now playing uses apple's `MediaRemote` framework through `osascript`, and a future macos can break it.

## install

needs full xcode installed and opened once (it asks you to accept its license). nxtch is built from source on your mac either way. theres no download to trust.

with homebrew:

```bash
brew tap skyphose/nxtch https://github.com/skyphose/nxtch && brew install nxtch && nxtch
```

or by hand:

```bash
git clone https://github.com/skyphose/nxtch.git ~/nxtch && ~/nxtch/build.sh --install
```

by hand copies it to /Applications and starts it. homebrew keeps it in its own folder, and `nxtch` starts it. since you built it yourself, gatekeeper has nothing to quarantine, so theres no "unidentified developer" warning.

ive only run either install on my own mac. the homebrew one i tested from a local copy of this repo, not from github.

| | by hand | homebrew |
| --- | --- | --- |
| update | `cd ~/nxtch && git pull && ./build.sh --install` | `brew upgrade nxtch` |
| uninstall | `~/nxtch/build.sh --uninstall`, then delete `~/nxtch` | `nxtch --uninstall && brew uninstall nxtch` |
| run without installing | `./build.sh --run` | |
| an older version | `git checkout v0.3.0 && ./build.sh --install` | |

uninstall quits nxtch, turns off launch at login, and removes the app, its settings and caches, the shelf and the clipboard history in `~/Library/Application Support/nxtch`, and its audio and accessibility permissions. nothing is kept back, so theres no undo. files you dropped on the shelf from elsewhere are only referenced, so those stay where they were.

ive run the uninstall on my own mac only. it prints whether the permissions were reset. launch at login i couldnt check from outside: look under system settings > general > login items if you had it on.

### signing

`build.sh` signs with your apple development certificate if you have a valid one. a free apple id is enough: sign in under xcode > settings > accounts. check it took with `security find-identity -v -p codesigning`. if that says 0 valid identities, install apple's "worldwide developer relations - g3" intermediate from apple.com/certificateauthority - xcode didnt add it on my mac. with that, macos keeps the audio and accessibility grants across rebuilds. without one it signs ad hoc, and macos asks again after every update. set `SIGN_ID` to pick a specific identity.

ad hoc has a cost beyond the nagging: you get used to re-approving audio and accessibility. only approve those prompts right after an update you ran yourself. if one shows up out of nowhere, something replaced the app, so deny it.

## using it

| | |
| --- | --- |
| open | rest the pointer on the notch, drag something onto it, or press ⌃⌥V |
| close | move away, press esc, or click somewhere else |
| tabs | icons left of the notch: media, shelf, clipboard |
| settings | gear right of the notch: launch at login, activity beside notch, full screen, clipboard recording, quit |

### media

whats playing (title, artist, progress, the app its in) with previous, play/pause and next. below that, one row per app making sound: volume 0 - 150%, mute, and a live level meter.

- a slider sticks to 100% as it passes, within 2%. hold ⇧ while dragging to turn that off.
- the reset button puts every app back to 100%. its at the top right of the media tab, and only shows when an app is muted or off 100%.
- closed, the notch shows an icon for every app making sound on its left. up to four. one level meter sits on the right, and its bars follow the first app only.
- the meter takes its color from the icons: green for spotify, orange for firefox. two apps fade from one color to the other. three or more make a wheel.
- an icon with several colors gets one blended color, so chrome comes out orange too. chrome and firefox together is a flat orange. an icon with no real color gives white.

### shelf

drag anything onto the notch to park it: files, images, links, text. items are tmeporary. drag one out and drop it somewhere, and it leaves the shelf.

the shelf MOVES files. it doesnt copy them. dropping a file on the notch only notes where the file is. drag it out into a finder folder and the original goes there, from wherever it was. nothing is duplicated, on the shelf or after. this is new. your own files used to copy out by default.

- click a tile to select it. ⌘-click adds or removes one, ⇧-click selects a range. drag any selected tile and they all go together. the check mark button selects everything. the buttons and the right-click menu act on the selection.
- hold ⌥ while dropping to copy and leave the original in place. hold ⌘ to insist on a move.
- the destination does the move, not nxtch. an app that only reads the file (a browser upload, a mail attachment) leaves the original alone. finder should copy instead when the folder is on another disk. untested, i only tried one disk.
- text, links, images and file promises (mail, photos, screenshots) get saved in `~/Library/Application Support/nxtch/Shelf`. those move out, so no copy is left behind. anything over 1 GB is skipped. files nxtch only references have no limit. if the place you drop one only takes its path instead of moving or copying it, it stays on the shelf.
- while you drag an item, a delete square shows up. drop it there to take it off the shelf. your original files are never trashed.
- double-click opens an item. right-click for open, show in finder, copy, airdrop or delete.

### clipboard

press ⌃⌥V anywhere and type to search. ↑/↓ moves the selection, return pastes into the app you were in.

- click a row to copy it. right-click to paste, pin or delete.
- to delete some entries and keep the rest, click the check mark button, pick the rows, then the trash. ⌘-click a row does the same without the button. the trash deletes what you picked, pinned or not. outside select mode it clears everything unpinned.
- anything a password manager marks as concealed or transient is never recroded. nothing is recorded while a password manager is the frontmost app either, since not all of them mark their items. the list is in `Clipboard.swift`. four of the ids on it (macpass, strongbox, keeper, nordpass) i wrote down without an install to check against.
- a password copied from a browser extension or a terminal looks like any other text, so that still gets recorded. delete it, or pause recording first.
- unpinned items are dropped after 7 days.
- things copied on your iphone (universal clipboard) arent recorded. untested.
- text is capped at 50,000 characters. images over 20 MB or 50 megapixels are skipped.
- history lives in `~/Library/Application Support/nxtch/Clipboard`, readable by your user only and kept out of time machine.

## permissions

| permission | asked when | why |
| --- | --- | --- |
| system audio recording | the first time an app plays sound | per-app volume and the meters read each app's audio |
| accessibility | the first time you paste from clipboard history | return/paste sends ⌘V to the app you were in |

with an ad hoc signature macos may ask again after every update. signing with your own certificate stops that (see signing). return only pastes if the app you were in is frontmost again. ohterwise the item just stays on the clipboard.

## how it works

**per-app volume.** core audio process taps. for an app set to anything but 100%, nxtch taps its audio and mutes the original. then it plays it back through the default output at your gain, ramped and run through a soft limiter. at 100% the app's audio isnt touched.

**meters.** the tap callback splits each app's audio into four bands with one-pole filters. meters are drawn with `CALayer`s and only run where you can see them.

**now playing.** since macos 15.4, `MediaRemote` only answers apple-signed programs. so nxtch asks through `osascript` (jxa), which is apple-signed. a long-running helper reports title, artist and position, and quits when nxtch quits. the playback buttons send comamnds the same way, so they need no permission.

**the notch panel.** a borderless, non-activating `NSPanel` above the menu bar. it tries hard to stay out of the way:

- it only opens after you rest on the hardware notch, or when you drag something onto it.
- only the visible black shape takes clicks. evreything around it passes through.
- it takes keyboard focus only for clipboard search, and hands it back when it closes.
- its hidden in full-screen apps unless you turn that on.

## security

- signed with hardened runtime, so another process cant inject code into nxtch and borrow its audio or accessibility access.
- names of dropped files are cleaned before saving. a name cant leave the shelf folder, hide itself or fake its extension with right-to-left characters.
- files nxtch saves get the quarantine flag, so gatekeeper still checks them when you open one.
- nxtch only ever deletes files inside its own shelf and clipboard folders, even if its saved lists were edited. when a shelf file moves, the destination moved it. nxtch never moves or deletes your originals itself.
- now-playing data comes from any app or web page, so its times are clamped before use.

what it costs to run, and what stays out on purpose, is in [SCOPE.md](SCOPE.md). what changed in each version is in [CHANGELOG.md](CHANGELOG.md).

## project layout

```
Sources/Nxtch/
  main.swift          app entry, settings
  Support.swift       timing, animation curves, logging, global shortcut, ⌘V, folders on disk
  NotchWindow.swift   panel, tabs model, mouse/drag/keyboard handling
  NotchView.swift     notch shape, open/closed shells, tab bar
  LevelMeter.swift    the meters, their shared timer, and the color taken from an app icon
  MediaTab.swift      now-playing card, mixer rows
  ShelfTab.swift      shelf tiles, delete zone, drag source
  ClipboardTab.swift  search field, history rows
  MixerModel.swift    finds which apps make sound, keeps taps in sync, saves volumes
  Audio.swift         core audio helpers, process tap, real-time render callback
  NowPlaying.swift    now-playing helper and playback commands (osascript)
  Shelf.swift         shelf store: drops, selection, thumbnails
  Clipboard.swift     clipboard history store
Tests/NxtchTests/     the rules that need no notch: file names, expiry, parsing, levels, colors
Formula/nxtch.rb      the homebrew formula
Resources/Info.plist
Resources/AppIcon.icns       the app icon
Resources/icon.png           the same icon, for this readme
Resources/make-icon.swift    draws it
build.sh
CHANGELOG.md
SCOPE.md
```

`swift test` runs the tests. 19 of them, none touch audio, the pasteboard or the screen. those parts i test by hand.


## license

mit. see [LICENSE](LICENSE).
