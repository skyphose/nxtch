# nxtch

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
- you dont want an app that leans on private api. now playing uses apple's `MediaRemote` framework through `osascript`, and a future macos can break it.

## using it

| | |
| --- | --- |
| open | rest the pointer on the notch, drag something onto it, or press ⌃⌥V |
| close | move away, press esc, or click somewhere else |
| tabs | icons left of the notch: media, shelf, clipboard |
| settings | gear right of the notch: launch at login, activity beside notch, full screen, clipboard recording, quit |

### media

whats playing (title, artist, progress, the app its in) with previous, play/pause and next. below that, one row per app making sound: volume 0 - 150%, mute, and a live level meter.

### shelf

drag anything onto the notch to park it: files, images, links, text. items are temporary. drag one out and drop it somewhere, and it leaves the shelf.

- your files are only referenced, nothing is copied. they copy out by default. hold ⌘ while dropping to move them.
- text, links, images and file promises (mail, photos, screenshots) get saved in `~/Library/Application Support/nxtch/Shelf`. those move out, so no copy is left behind.
- while you drag an item, a delete square shows up. drop it there to take it off the shelf. your original files are never trashed.
- double-click opens an item. right-click for open, show in finder, copy, airdrop or delete.

### clipboard

press ⌃⌥V anywhere and type to search. ↑/↓ moves the selection, return pastes into the app you were in.

- click a row to copy it. right-click to paste, pin or delete.
- anything a password manager marks as concealed or transient is never recroded. nothing is recorded while a password manager is the frontmost app either, since not all of them mark their items.
- text is capped at 50,000 characters. images over 20 MB or 50 megapixels are skipped.
- history lives in `~/Library/Application Support/nxtch/Clipboard`, readable by your user only and kept out of time machine.

## build

```bash
./build.sh            # builds Nxtch.app in this folder
./build.sh --run      # builds and launches it
./build.sh --install  # builds, copies to /Applications and launches from there
```

`build.sh` runs `swift build` and wraps the binary into an app.

it signs with your apple development certificate if you have a valid one, so macos keeps the audio and accessibility grants across rebuilds. without one it signs ad hoc, and macos asks again after every build. set `SIGN_ID` to pick a specific identity.

## permissions

| permission | asked when | why |
| --- | --- | --- |
| system audio recording | the first time an app plays sound | per-app volume and the meters read each app's audio |
| accessibility | the first time you paste from clipboard history | return/paste sends ⌘V to the app you were in |

with an ad hoc signature macos may ask again after every rebuild. signing with your own certificate stops that (see build). return only pastes if the app you were in is frontmost again. otherwise the item just stays on the clipboard.

## how it works

**per-app volume.** core audio process taps. for an app set to anything but 100%, nxtch taps its audio and mutes the original. then it plays it back through the default output at your gain, ramped and run through a soft limiter. at 100% the app's audio isnt touched.

**meters.** the tap callback splits each app's audio into four bands with one-pole filters. meters are drawn with `CALayer`s and only run where you can see them.

**now playing.** since macos 15.4, `MediaRemote` only answers apple-signed programs. so nxtch asks through `osascript` (jxa), which is apple-signed. a long-running helper reports title, artist and position, and quits when nxtch quits. the playback buttons send comamnds the same way, so they need no permission.

**the notch panel.** a borderless, non-activating `NSPanel` above the menu bar. it tries hard to stay out of the way:

- it only opens after you rest on the hardware notch, or when you drag something onto it.
- only the visible black shape takes clicks. everything around it passes through.
- it takes keyboard focus only for clipboard search, and hands it back when it closes.
- its hidden in full-screen apps unless you turn that on.

## security

- signed with hardened runtime, so another process cant inject code into nxtch and borrow its audio or accessibility access.
- names of dropped files are cleaned before saving. a name cant leave the shelf folder, hide itself or fake its extension with right-to-left characters.
- files nxtch saves get the quarantine flag, so gatekeeper still checks them when you open one.
- nxtch only ever deletes files inside its own shelf folder.
- now-playing data comes from any app or web page, so its times are clamped before use.

what it costs to run, and what stays out on purpose, is in [SCOPE.md](SCOPE.md).

## project layout

```
Sources/Nxtch/
  main.swift          app entry, settings, logging, global shortcut, ⌘V
  NotchWindow.swift   panel, tabs model, mouse/drag/keyboard handling
  NotchView.swift     notch shape, open/closed shells, tab bar, CALayer level meter
  MediaTab.swift      now-playing card, mixer rows
  ShelfTab.swift      shelf tiles, delete zone, drag source
  ClipboardTab.swift  search field, history rows
  MixerModel.swift    finds which apps make sound, keeps taps in sync, saves volumes
  Audio.swift         core audio helpers, process tap, real-time render callback
  NowPlaying.swift    now-playing helper and playback commands (osascript)
  Shelf.swift         shelf store: safe file names, drops, thumbnails
  Clipboard.swift     clipboard history store
Resources/Info.plist
build.sh
SCOPE.md
```
