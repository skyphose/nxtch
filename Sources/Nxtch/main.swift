import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: MixerModel?
    private var nowPlaying: NowPlayingMonitor?
    private var settings: AppSettings?
    private var shelf: ShelfStore?
    private var clipboard: ClipboardStore?
    private var bag = Set<AnyCancellable>()
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = MixerModel()
        let nowPlaying = NowPlayingMonitor()
        let settings = AppSettings()
        let shelf = ShelfStore()
        let clipboard = ClipboardStore()
        self.model = model
        self.nowPlaying = nowPlaying
        self.settings = settings
        self.shelf = shelf
        self.clipboard = clipboard
        model.isNowPlayingOwner = { [weak nowPlaying] app in
            MainActor.assumeIsolated { nowPlaying?.info?.belongs(to: app.id) ?? false }
        }
        settings.$clipboardEnabled.sink { clipboard.enabled = $0 }.store(in: &bag)
        notch = NotchController(model: model, nowPlaying: nowPlaying, settings: settings,
                                shelf: shelf, clipboard: clipboard)
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
