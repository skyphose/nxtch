import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nowPlaying: NowPlayingMonitor?
    private var notch: NotchController?
    private var watchdog: MemoryWatchdog?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = MixerModel(), nowPlaying = NowPlayingMonitor(), settings = AppSettings()
        let shelf = ShelfStore(), clipboard = ClipboardStore()
        model.isNowPlayingOwner = { [weak nowPlaying] app in
            MainActor.assumeIsolated { nowPlaying?.info?.belongs(to: app.id) ?? false }
        }
        nowPlaying.ownerChanged = { [weak model] in model?.nowPlayingOwnerChanged() }
        self.nowPlaying = nowPlaying
        notch = NotchController(model: model, nowPlaying: nowPlaying, settings: settings, shelf: shelf, clipboard: clipboard)
        watchdog = MemoryWatchdog()
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

// MARK: Settings

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    /// Called after any setting below changes (not launch at login, which only the system reads).
    var onChange: (@MainActor () -> Void)?

    /// App icon and level meter beside the notch while audio plays. They can cover menu bar items.
    @Published var showEars: Bool { didSet { d.set(showEars, forKey: "showEars"); onChange?() } }
    /// Appear on full-screen Spaces. Off by default so it never covers full-screen content.
    @Published var showInFullScreen: Bool { didSet { d.set(showInFullScreen, forKey: "showInFullScreen"); onChange?() } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled"); onChange?() } }
    @Published var clipboardShortcut: ClipboardShortcut {
        didSet { d.set(clipboardShortcut.rawValue, forKey: "clipboardShortcut"); onChange?() }
    }
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
        clipboardShortcut = ClipboardShortcut(rawValue: d.string(forKey: "clipboardShortcut") ?? "") ?? .controlOptionV
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
