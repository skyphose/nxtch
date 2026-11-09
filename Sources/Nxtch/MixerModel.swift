import AppKit
import Combine
import CoreAudio

struct AppEntry: Identifiable, Equatable {
    let id: String            // bundle identifier of the owning app
    let name: String
    let icon: NSImage
    var processObjects: Set<AudioObjectID>
    var isPlaying: Bool

    // NSImage compares by identity, so leave the icon (and name, derived from the same app) out.
    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

/// Which apps get a listen-only metering tap. Volume taps are unaffected.
enum MeterScope {
    case none       // no meter on screen
    case primary    // closed notch with ears: only the app shown in the ears
    case all        // media tab open: every playing app
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var outputName = ""
    @Published private(set) var lastError: String?
    @Published private var volumes: [String: Float]
    @Published private var muted: Set<String>

    static let maxVolume: Float = 1.5

    /// Taps cost CPU here and in coreaudiod, so meters only run where they're visible.
    var meterScope: MeterScope = .primary { didSet { if meterScope != oldValue { resync() } } }
    /// Which app owns the now-playing media (used by `.primary`).
    var isNowPlayingOwner: (AppEntry) -> Bool = { _ in false }

    private var taps: [String: AppVolumeTap] = [:]
    private var states: [String: TapState] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var icons: [String: NSImage] = [:]   // NSRunningApplication.icon reads from disk every call
    private var listened = Set<AudioObjectID>()
    private var refreshPending = false
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        volumes = (defaults.dictionary(forKey: "volumes") as? [String: Float]) ?? [:]
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])
        refresh()
        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            MainActor.assumeIsolated { self?.taps.removeAll(); self?.refresh() }
        }
        // Changes arrive as Core Audio notifications. This slow timer is a safety net and ages
        // out "recently played".
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 1
    }

    var anyPlaying: Bool { apps.contains { $0.isPlaying } }

    /// The app the closed notch shows: the now-playing owner if it's playing, else the first playing app.
    var primaryApp: AppEntry? { apps.first { $0.isPlaying && isNowPlayingOwner($0) } ?? apps.first(where: \.isPlaying) }

    func volume(_ id: String) -> Float { volumes[id] ?? 1 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }
    /// Live level meter for an app, or nil when it isn't tapped.
    func meter(_ id: String) -> TapState? { taps[id] != nil ? states[id] : nil }

    func setVolume(_ id: String, _ value: Float) {
        // Snap to 100% so it's easy to get back to untouched, zero-latency audio.
        let value = abs(value - 1) < 0.04 ? 1 : min(max(value, 0), Self.maxVolume)
        volumes[id] = value
        if value > 0 { muted.remove(id) }
        changed(id)
    }

    func toggleMute(_ id: String) {
        if muted.remove(id) == nil { muted.insert(id) }
        changed(id)
    }

    // MARK: Internals

    private func changed(_ id: String) {
        apply(id, outputUID: CA.deviceUID(CA.defaultOutputDevice))
        defaults.set(volumes, forKey: "volumes")
        defaults.set(Array(muted), forKey: "muted")
    }

    private func gain(_ id: String) -> Float { muted.contains(id) ? 0 : (volumes[id] ?? 1) }

    private func resync() {
        let uid = CA.deviceUID(CA.defaultOutputDevice)
        for app in apps { apply(app.id, outputUID: uid) }
    }

    /// Coalesces bursts of Core Audio notifications into one refresh.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.refreshPending = false; self?.refresh() }
        }
    }

    /// Makes one app's tap match what it needs: a custom gain gets a volume tap (which also
    /// meters), a playing app whose meter is on screen gets a listen-only tap, anything else none.
    private func apply(_ id: String, outputUID: String?) {
        let gain = gain(id)
        let needsVolume = abs(gain - 1) > 0.001
        let wantsMeter: Bool
        switch meterScope {
        case .none: wantsMeter = false
        case .all: wantsMeter = true
        case .primary: wantsMeter = primaryApp?.id == id
        }
        guard let entry = apps.first(where: { $0.id == id }), !entry.processObjects.isEmpty,
              needsVolume || (entry.isPlaying && wantsMeter), let outputUID else {
            taps[id] = nil
            return
        }
        let state = states[id] ?? TapState(gain)
        states[id] = state
        state.target = gain

        if let tap = taps[id], tap.processObjects == entry.processObjects,
           tap.outputUID == outputUID, tap.passthrough == !needsVolume { return }
        taps[id] = nil
        do {
            taps[id] = try AppVolumeTap(processObjects: entry.processObjects, outputUID: outputUID,
                                        passthrough: !needsVolume, state: state)
            if lastError != nil { lastError = nil }
        } catch {
            lastError = "\(entry.name): \(error)"
            NSLog("nxtch: \(error)")
        }
    }

    private func refresh() {
        let output = CA.defaultOutputDevice
        let name = CA.name(output) ?? ""
        if name != outputName { outputName = name }
        let me = ProcessInfo.processInfo.processIdentifier
        let processes = AudioProcess.all()

        // Listen for each process starting or stopping output instead of polling.
        for proc in processes where !listened.contains(proc.objectID) {
            CA.listen(proc.objectID, kAudioProcessPropertyIsRunningOutput) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        listened = Set(processes.map(\.objectID))

        var grouped: [String: AppEntry] = [:]
        for proc in processes where proc.pid != me {
            guard let app = NSRunningApplication(processIdentifier: proc.responsiblePID)
                    ?? NSRunningApplication(processIdentifier: proc.pid),
                  app.activationPolicy == .regular, let bid = app.bundleIdentifier, app.processIdentifier != me
            else { continue }
            if grouped[bid] == nil {
                if icons[bid] == nil { icons[bid] = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
                grouped[bid] = AppEntry(id: bid, name: app.localizedName ?? bid, icon: icons[bid]!, processObjects: [], isPlaying: false)
            }
            grouped[bid]!.processObjects.insert(proc.objectID)
            grouped[bid]!.isPlaying = grouped[bid]!.isPlaying || proc.isRunningOutput
        }

        // Show apps that are playing, played in the last 2 minutes, or have a custom setting.
        let now = Date()
        for e in grouped.values where e.isPlaying { lastPlayed[e.id] = now }
        let visible = grouped.values
            .filter { $0.isPlaying || gain($0.id) != 1 || now.timeIntervalSince(lastPlayed[$0.id] ?? .distantPast) < 120 }
            .sorted { $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if visible != apps { apps = visible }

        let ids = Set(visible.map(\.id))
        for id in taps.keys where !ids.contains(id) { taps[id] = nil }
        let uid = CA.deviceUID(output)
        for app in visible { apply(app.id, outputUID: uid) }
    }
}
