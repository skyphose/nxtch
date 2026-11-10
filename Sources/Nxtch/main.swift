import AppKit
import Combine
import ServiceManagement

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
