# nxtch

*Like "no notch."* nxtch turns the MacBook notch into a small, fast home for three things:

- **Media.** See what's playing (title, artist, progress, and the app it's in) with previous / play-pause / next, plus per-app volume (0–150%), mute and live level meters.
- **Shelf.** Drag anything onto the notch to park it: files, images, links, text. Drag it back out wherever it needs to go, copy it all, or AirDrop it.
- **Clipboard.** Searchable history of text, images and files with pinning. Press **⌃⌥V** anywhere, type to search, and press Return to paste.

It's meant to stay lightweight. See [SCOPE.md](SCOPE.md) for what's in, what's deliberately out, and the resource budget.

## Using it

| | |
| --- | --- |
| Open | Rest the pointer on the notch, drag something onto it, or press ⌃⌥V |
| Close | Move away, press Esc, or click elsewhere |
| Tabs | Icons to the left of the notch: Media · Shelf · Clipboard |
| Settings | Gear to the right of the notch: launch at login, activity beside notch, full screen, clipboard recording, quit |

**Shelf:** Items are temporary. Once you drag one out and drop it somewhere, it leaves the shelf. Dropped files are only referenced, so nothing is copied. Text, links, images and file promises (from Mail, Photos, screenshots and so on) are saved in `~/Library/Application Support/nxtch/Shelf`. Your files copy out by default; hold ⌘ while dropping to move them. Text, links and images that nxtch saved move out, so no copy is left behind. While you drag an item, a **Delete** square appears; drop it there to take it off the shelf (your original files are never trashed). Double-click an item to open it; right-click for Open, Show in Finder, Copy, AirDrop or Delete.

**Clipboard:** Click a row to copy it. Return pastes the selected row into the app you were using (↑/↓ to move the selection). Right-click to paste, pin or delete. Anything that password managers mark as concealed or transient is never recorded. History lives in `~/Library/Application Support/nxtch/Clipboard`.

## Requirements

- macOS 14.2 or later (process taps arrived in 14.2)
- A Mac with a notch (on other displays it falls back to a small pill at the top center)
- Swift toolchain: the Xcode Command Line Tools are enough

## Build

```bash
./build.sh            # builds Nxtch.app in this folder
./build.sh --run      # builds and launches it
./build.sh --install  # builds, copies to /Applications and launches from there
```

`build.sh` calls `swiftc` directly rather than `swift build`, because SwiftPM is broken in some Command Line Tools installs. `Package.swift` is there for editors. The code avoids SwiftUI's `@State` (on recent SDKs it's a macro that needs a compiler plugin the Command Line Tools don't include).

## Permissions

| Permission | Asked when | Why |
| --- | --- | --- |
| System Audio Recording | The first time an app plays sound | Per-app volume and level meters read each app's audio |
| Accessibility | The first time you paste from clipboard history | Return/Paste sends ⌘V to the app you were in |

The app is signed ad hoc, so macOS may ask again after each rebuild.

## How it works

- **Per-app volume:** Core Audio process taps. For an app set to anything other than 100%, nxtch taps its audio, mutes the original and plays it back through the default output with the chosen gain, ramped smoothly and run through a soft limiter. At 100%, the app's audio isn't touched at all.
- **Meters:** the tap callback splits each app's audio into four bands with one-pole filters. Meters are drawn with CALayers and only run where visible.
- **Now playing:** since macOS 15.4, the private MediaRemote framework only answers Apple-signed programs, so nxtch asks through `osascript` (JXA), which is Apple-signed. A long-running helper reports title, artist and position (it quits when nxtch quits), and playback buttons send commands the same way, so they need no permission. There's deliberately no album art: getting it would mean loading unsigned code into a system program or downloading from each service. This relies on private API and may break in a future macOS.
- **Notch panel:** a borderless, non-activating `NSPanel` above the menu bar. To stay out of the way:
  - It opens only after you rest on the hardware notch, or when you drag something onto it.
  - Only the visible black shape takes clicks; everything around it passes through.
  - It takes keyboard focus only for clipboard search, and hands focus back when it closes.
  - It's hidden in full-screen apps unless you turn that on.

## Project layout

```
Sources/Nxtch/
  main.swift              app entry, wiring
  NotchWindow.swift       panel, tabs model, mouse/drag/keyboard handling
  NotchView.swift         notch shape, open/closed shells, tab bar, CALayer level meter
  MediaTab.swift          now-playing card, mixer rows
  ShelfTab.swift          shelf tiles
  ClipboardTab.swift      search field, history rows
  MixerModel.swift        finds which apps make sound, keeps taps in sync, saves volumes
  AppVolumeTap.swift      process tap + aggregate device + real-time render callback
  CoreAudioHelpers.swift  Core Audio property helpers
  NowPlaying.swift        now-playing monitor (osascript helper)
  Shelf.swift             shelf store: drops, thumbnails, persistence
  Clipboard.swift         clipboard history store
  MediaControls.swift     media keys, ⌘V keystroke, launch at login
  Hotkey.swift            global shortcut (⌃⌥V)
  Settings.swift          user settings
Resources/Info.plist
build.sh
SCOPE.md
```
