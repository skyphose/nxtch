import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: MixerModel?
    private var nowPlaying: NowPlayingMonitor?
    private var settings: AppSettings?
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = MixerModel()
        let nowPlaying = NowPlayingMonitor()
        let settings = AppSettings()
        self.model = model
        self.nowPlaying = nowPlaying
        self.settings = settings
        notch = NotchController(model: model, nowPlaying: nowPlaying, settings: settings)
    }

    func applicationWillTerminate(_ notification: Notification) { nowPlaying?.stop() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
