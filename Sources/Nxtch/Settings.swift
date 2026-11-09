import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    /// Show the app icon / level meter "ears" beside the notch while audio plays.
    /// They can cover menu bar items, so this can be turned off.
    @Published var showEars: Bool { didSet { d.set(showEars, forKey: "showEars") } }

    /// Appear on full-screen Spaces. Off by default so it never covers full-screen content.
    @Published var showInFullScreen: Bool { didSet { d.set(showInFullScreen, forKey: "showInFullScreen") } }

    /// Record clipboard history.
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }

    @Published var launchAtLogin: Bool { didSet { if launchAtLogin != LaunchAtLogin.isEnabled { LaunchAtLogin.set(launchAtLogin) } } }

    init() {
        d.register(defaults: ["showEars": true, "showInFullScreen": false, "clipboardEnabled": true])
        showEars = d.bool(forKey: "showEars")
        showInFullScreen = d.bool(forKey: "showInFullScreen")
        clipboardEnabled = d.bool(forKey: "clipboardEnabled")
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
