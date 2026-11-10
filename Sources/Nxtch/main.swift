import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nowPlaying: NowPlayingMonitor?
    private var notch: NotchController?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = MixerModel(), nowPlaying = NowPlayingMonitor(), settings = AppSettings()
        let shelf = ShelfStore(), clipboard = ClipboardStore()
        model.isNowPlayingOwner = { [weak nowPlaying] app in
            MainActor.assumeIsolated { nowPlaying?.info?.belongs(to: app.id) ?? false }
        }
        settings.$clipboardEnabled.sink { clipboard.enabled = $0 }.store(in: &bag)
        self.nowPlaying = nowPlaying
        notch = NotchController(model: model, nowPlaying: nowPlaying, settings: settings, shelf: shelf, clipboard: clipboard)
    }

    func applicationWillTerminate(_ notification: Notification) { nowPlaying?.stop() }
}

// `build.sh --uninstall` runs this before it removes the app.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

// MARK: Main-thread timing

/// Runs `body` on the main actor after `delay` seconds.
@MainActor
func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
}

extension Timer {
    /// A repeating main-thread timer. The tolerance lets macOS batch wakeups.
    @MainActor
    static func repeating(_ interval: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let t = scheduledTimer(withTimeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated(body) }
        t.tolerance = tolerance
        return t
    }
}

// MARK: Animation

extension Animation {
    /// The panel opening, and anything inside it changing size.
    static let notch = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// The panel closing: quicker, and no bounce on the way out.
    static let notchClose = Animation.spring(response: 0.24, dampingFraction: 1)
    /// Small controls reacting to the pointer.
    static let control = Animation.spring(response: 0.2, dampingFraction: 0.7)

    /// With Reduce Motion on, a short fade replaces the springs.
    static func notch(opening: Bool) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.12) : (opening ? .notch : .notchClose)
    }
}

// MARK: Settings

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    /// App icon and level meter beside the notch while audio plays. They can cover menu bar items.
    @Published var showEars: Bool { didSet { d.set(showEars, forKey: "showEars") } }
    /// Appear on full-screen Spaces. Off by default so it never covers full-screen content.
    @Published var showInFullScreen: Bool { didSet { d.set(showInFullScreen, forKey: "showInFullScreen") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("nxtch: launch at login: \(error)") }
        }
    }

    init() {
        d.register(defaults: ["showEars": true, "showInFullScreen": false, "clipboardEnabled": true])
        showEars = d.bool(forKey: "showEars")
        showInFullScreen = d.bool(forKey: "showInFullScreen")
        clipboardEnabled = d.bool(forKey: "clipboardEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Logging

/// State changes only, never per frame. Read with:
///   /usr/bin/log stream --info --predicate 'subsystem == "dev.nxtch.app"'
enum Log {
    static let notch = Logger(subsystem: "dev.nxtch.app", category: "notch")
    static let shelf = Logger(subsystem: "dev.nxtch.app", category: "shelf")
    static let clipboard = Logger(subsystem: "dev.nxtch.app", category: "clipboard")
}

extension Notification.Name {
    static let nxtchRequestClose = Notification.Name("nxtchRequestClose")
    static let nxtchFocusSearch = Notification.Name("nxtchFocusSearch")
}

// MARK: Global shortcut

/// One system-wide shortcut through Carbon's RegisterEventHotKey (needs no permission).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        Self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x6E787463) /* 'nxtc' */, id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.notch.error("hotkey not registered (\(status)); another app may own it") }
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}

// MARK: Synthesized ⌘V

/// Presses ⌘V, but only if `pid` is the frontmost app: if focus didn't come back to the app you
/// were in, the item stays on the clipboard instead of landing somewhere else.
/// Needs Accessibility; without it, does nothing and asks once.
enum Keystroke {
    private static var asked = false

    @discardableResult
    static func paste(into pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            Log.clipboard.info("paste skipped: target app is no longer frontmost")
            return false
        }
        guard AXIsProcessTrusted() || CGPreflightPostEventAccess() else {
            if !asked {
                asked = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            return false
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        return true
    }
}
