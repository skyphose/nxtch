import AppKit
import CoreAudio
import Combine

struct AppEntry: Identifiable, Equatable {
    let id: String            // bundle identifier of the owning app
    let name: String
    let icon: NSImage
    var processObjects: Set<AudioObjectID>
    var isPlaying: Bool

    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var outputName: String = ""
    @Published private(set) var lastError: String?
    @Published private var volumes: [String: Float]
    @Published private var muted: Set<String>

    private var taps: [String: AppVolumeTap] = [:]
    private var states: [String: TapState] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var anyPlaying: Bool { apps.contains { $0.isPlaying } }

    init() {
        volumes = (defaults.dictionary(forKey: "volumes") as? [String: Float]) ?? [:]
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])
        refresh()
        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        // IsRunningOutput changes per process; a cheap poll keeps the "playing" state fresh.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Public

    func volume(_ id: String) -> Float { volumes[id] ?? 1 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }
    /// Live level meter for an app, or nil when it isn't being tapped.
    func meter(_ id: String) -> TapState? { taps[id] != nil ? states[id] : nil }

    static let maxVolume: Float = 1.5

    func setVolume(_ id: String, _ value: Float) {
        // Snap to 100% so it's easy to get back to untouched (zero-latency) audio.
        let value = abs(value - 1) < 0.04 ? 1 : min(max(value, 0), Self.maxVolume)
        volumes[id] = value
        if value > 0, muted.contains(id) { muted.remove(id) }
        apply(id, outputUID: CA.deviceUID(CA.defaultOutputDevice))
        persist()
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        apply(id, outputUID: CA.deviceUID(CA.defaultOutputDevice))
        persist()
    }

    // MARK: Internals

    private func effectiveGain(_ id: String) -> Float { muted.contains(id) ? 0 : (volumes[id] ?? 1) }

    private func persist() {
        defaults.set(volumes, forKey: "volumes")
        defaults.set(Array(muted), forKey: "muted")
    }

    /// Make the tap for one app match what it needs:
    /// - custom gain → volume tap (original muted, re-played at gain, also meters)
    /// - 100% but playing → listen-only tap for metering
    /// - otherwise → no tap
    private func apply(_ id: String, outputUID: String?) {
        let gain = effectiveGain(id)
        let needsVolume = abs(gain - 1) > 0.001
        guard let entry = apps.first(where: { $0.id == id }), !entry.processObjects.isEmpty,
              needsVolume || entry.isPlaying, let outputUID else {
            taps[id] = nil
            return
        }
        let state = states[id] ?? TapState(gain)
        states[id] = state
        state.target = gain

        let passthrough = !needsVolume
        if let tap = taps[id], tap.processObjects == entry.processObjects,
           tap.outputUID == outputUID, tap.passthrough == passthrough { return }
        taps[id] = nil
        do {
            taps[id] = try AppVolumeTap(processObjects: entry.processObjects, outputUID: outputUID,
                                        passthrough: passthrough, state: state)
            lastError = nil
        } catch {
            lastError = "\(entry.name): \(error)"
            NSLog("NotchMixer: \(error)")
        }
    }

    private func outputChanged() {
        outputName = CA.name(CA.defaultOutputDevice) ?? ""
        taps.removeAll()
        let uid = CA.deviceUID(CA.defaultOutputDevice)
        for app in apps { apply(app.id, outputUID: uid) }
    }

    private func refresh() {
        let output = CA.defaultOutputDevice
        outputName = CA.name(output) ?? ""
        let outputUID = CA.deviceUID(output)
        let me = ProcessInfo.processInfo.processIdentifier
        var grouped: [String: AppEntry] = [:]

        for proc in AudioProcess.all() where proc.pid != me {
            let owner = NSRunningApplication(processIdentifier: ResponsiblePID.of(proc.pid))
                ?? NSRunningApplication(processIdentifier: proc.pid)
            guard let app = owner, app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier, app.processIdentifier != me else { continue }
            if var e = grouped[bid] {
                e.processObjects.insert(proc.objectID)
                e.isPlaying = e.isPlaying || proc.isRunningOutput
                grouped[bid] = e
            } else {
                grouped[bid] = AppEntry(id: bid, name: app.localizedName ?? bid,
                                        icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!,
                                        processObjects: [proc.objectID], isPlaying: proc.isRunningOutput)
            }
        }

        // Show apps that are playing, played in the last 2 minutes, or have a custom setting.
        let now = Date()
        for e in grouped.values where e.isPlaying { lastPlayed[e.id] = now }
        let visible = grouped.values.filter { e in
            e.isPlaying || effectiveGain(e.id) != 1 || (lastPlayed[e.id].map { now.timeIntervalSince($0) < 120 } ?? false)
        }
        let sorted = visible.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if sorted != apps { apps = sorted }

        let visibleIDs = Set(sorted.map(\.id))
        for id in taps.keys where !visibleIDs.contains(id) { taps[id] = nil }
        for app in sorted { apply(app.id, outputUID: outputUID) }
    }
}
