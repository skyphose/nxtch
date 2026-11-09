# NotchMixer

Per-app volume control that lives in the MacBook notch.

Hover the notch and it opens into a mixer: every app making sound gets a volume slider (0–150%), a mute button and a live level meter. When something is playing, a card up top shows the title, artist, artwork and progress, with previous / play-pause / next.

## Requirements

- macOS 14.2 or later (process taps arrived in 14.2)
- Apple Silicon Mac with a notch (on other displays it falls back to a small pill at the top center)
- Swift toolchain: the Xcode Command Line Tools are enough

## Build

```bash
./build.sh            # builds NotchMixer.app in this folder
./build.sh --run      # builds and launches it
./build.sh --install  # builds, copies to /Applications and launches from there
```

`build.sh` calls `swiftc` directly rather than `swift build`, because SwiftPM is broken in some Command Line Tools installs. `Package.swift` is there for editors and for anyone with a working SwiftPM.

## Permissions

| Permission | Asked when | Why |
| --- | --- | --- |
| System Audio Recording | The first time an app plays sound | Needed to read each app's audio (meters) and to change its volume |
| Accessibility | The first time you press a playback button | Playback buttons work by sending media-key presses |

The app is signed ad hoc, so macOS may ask again after each rebuild.

## How it works

- **Per-app volume.** Core Audio process taps (`AudioHardwareCreateProcessTap`). For an app set to anything other than 100%, NotchMixer taps its audio, mutes the original and plays it back through the default output with the chosen gain, ramped smoothly and run through a soft limiter. At exactly 100% the app is only listened to for metering; its audio isn't altered or delayed.
- **Grouping.** Helper processes (Chrome Helper, WebKit's audio process, and so on) are grouped under the app that owns them.
- **Meters.** The audio callback splits each app's sound into four bands with simple one-pole filters and publishes their levels.
- **Now playing.** Since macOS 15.4 the private MediaRemote framework only answers Apple-signed programs. Like boring.notch, NotchMixer asks through `osascript` (JXA), which is Apple-signed: a small helper reports changes about once a second and quits when NotchMixer quits. This relies on private API and may break in a future macOS.
- **Notch panel.** A borderless, non-activating `NSPanel` above the menu bar, in the style of boring.notch. It's built so it doesn't get in the way:
  - It opens only after you rest the pointer on the hardware notch, and not while a mouse button is held.
  - When open, only the visible black shape takes clicks; everything around it passes through.
  - When closed, it takes no clicks at all.
  - It's hidden in full-screen apps unless you turn that on.
  - It never takes keyboard focus.

## Settings (gear icon)

- Launch at Login
- Show Activity Beside Notch
- Show in Full Screen
- Quit

## Project layout

```
Sources/NotchMixer/
  main.swift              app entry point
  NotchWindow.swift       panel, notch geometry, mouse handling
  NotchView.swift         SwiftUI: notch shape, mixer rows, now-playing card, meters
  MixerModel.swift        finds which apps make sound, keeps taps in sync, saves volumes
  AppVolumeTap.swift      process tap + aggregate device + real-time render callback
  CoreAudioHelpers.swift  Core Audio property helpers
  NowPlaying.swift        now-playing monitor (osascript helper)
  MediaControls.swift     media keys, launch at login
  Settings.swift          user settings
Resources/Info.plist
build.sh
```
