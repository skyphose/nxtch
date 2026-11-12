import AppKit
import Combine
import CoreAudio

struct AppEntry: Identifiable, Equatable {
    let id: String            // bundle identifier of the owning app
    let name: String
    let icon: NSImage
    /// The icon's most vivid color, for this app's level meter.
    let tint: NSColor
    var processObjects: Set<AudioObjectID>
    var isPlaying: Bool

    /// One app's meter fades from its color to a lighter shade of it.
    var meterColors: [NSColor] { [tint, tint.blended(withFraction: 0.5, of: .white) ?? tint] }

    // NSImage compares by identity, so leave the icon (and name, derived from the same app) out.
    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

/// Which apps get a listen-only metering tap. Volume taps are unaffected.
enum MeterScope {
    case none       // no meter on screen
    case primary    // closed notch with ears: one tap of every playing app, mixed
    case all        // media tab open: every playing app
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var outputName = ""
    @Published private(set) var lastError: String?
    @Published private var volumes: [String: Float]
    @Published private var muted: Set<String>

    nonisolated static let maxVolume: Float = 1.5

    /// A slider position as a level: kept inside 0...maxVolume, and pulled to exactly 100% when
    /// within 2% of it, so it's easy to get back to untouched, zero-latency audio.
    nonisolated static func level(_ value: Float, snap: Bool) -> Float {
        snap && abs(value - 1) < 0.02 ? 1 : min(max(value, 0), maxVolume)
    }

    /// Taps cost CPU here and in coreaudiod, so meters only run where they're visible.
    var meterScope: MeterScope = .primary { didSet { if meterScope != oldValue { resync() } } }
    /// Which app owns the now-playing media (used by `.primary`).
    var isNowPlayingOwner: (AppEntry) -> Bool = { _ in false }

    /// The closed notch meters the now-playing app, so move its tap when that app changes.
    func nowPlayingOwnerChanged() { if meterScope == .primary { resync() } }

    /// The closed notch's meter listens to every playing app at once, through one tap of all
    /// their processes. One tap costs the same whatever it covers, and the meter doesn't go
    /// flat when the app listed first happens to be the quiet one.
    @Published private var mixTap: AppVolumeTap?
    private let mixState = TapState(1)
    var mixMeter: TapState? { mixTap != nil ? mixState : nil }

    private func syncMix(outputUID: String?) {
        let objects = meterScope == .primary && tapsAllowed
            ? apps.filter(\.isPlaying).reduce(into: Set<AudioObjectID>()) { $0.formUnion($1.processObjects) } : []
        guard !objects.isEmpty, let outputUID else {
            if mixTap != nil { mixTap = nil }
            return
        }
        if let tap = mixTap, tap.processObjects == objects { return }
        if mixTap != nil { mixTap = nil }   // the old tap must be gone before the new one starts
        let began = Date()
        mixTap = try? AppVolumeTap(processObjects: objects, outputUID: outputUID, passthrough: true, state: mixState)
        Log.audio.info("mix tap \(self.mixTap == nil ? "failed" : "started", privacy: .public) processes=\(objects.count, privacy: .public) ms=\(Int(Date().timeIntervalSince(began) * 1000), privacy: .public)")
    }

    /// Which apps are tapped. Published so a meter's view is rebuilt when its tap moves to
    /// another app: otherwise the closed notch kept showing the old app's meter, gone flat.
    @Published private var taps: [String: AppVolumeTap] = [:]
    private var states: [String: TapState] = [:]
    private var lastPlayed: [String: Date] = [:]
    private static let blank = NSImage()
    private var icons: [String: NSImage] = [:]   // NSRunningApplication.icon reads from disk every call
    private var tints: [String: NSColor] = [:]   // worked out once per app, from its icon
    private var listened = Set<AudioObjectID>()
    private var refreshPending = false
    private var persistPending = false
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        // Saved levels go through the same limits as a slider; anything not a number is dropped.
        volumes = ((defaults.dictionary(forKey: "volumes") as? [String: Float]) ?? [:])
            .compactMapValues { $0.isFinite ? Self.level($0, snap: false) : nil }
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])
        // Not during launch: starting a tap can take a second, and waits on the macOS permission
        // prompt the first time. The notch should be on screen before that, not after.
        onMain { [weak self] in self?.refresh() }
        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            MainActor.assumeIsolated { self?.taps.removeAll(); self?.mixTap = nil; self?.refresh() }
        }
        // Changes arrive as Core Audio notifications. This slow timer is a safety net and ages
        // out "recently played".
        timer = .repeating(30, tolerance: 5) { [weak self] in self?.refresh() }
    }

    var anyPlaying: Bool { apps.contains { $0.isPlaying } }

    /// The app the closed notch shows: the now-playing owner if it's playing, else the first playing app.
    var primaryApp: AppEntry? { apps.first { $0.isPlaying && isNowPlayingOwner($0) } ?? apps.first(where: \.isPlaying) }

    func volume(_ id: String) -> Float { volumes[id] ?? 1 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }
    /// Live level meter for an app, or nil when it isn't tapped.
    func meter(_ id: String) -> TapState? { taps[id] != nil ? states[id] : nil }

    /// `snap: false` (⇧ held) keeps every value as is.
    func setVolume(_ id: String, _ value: Float, snap: Bool = true) {
        let value = Self.level(value, snap: snap)
        volumes[id] = value
        if value > 0 { muted.remove(id) }
        changed(id)
    }

    func toggleMute(_ id: String) {
        if muted.remove(id) == nil { muted.insert(id) }
        changed(id)
    }

    /// Some app is muted or away from 100%.
    var hasCustomLevels: Bool { !muted.isEmpty || volumes.values.contains { abs($0 - 1) > 0.001 } }

    /// Every app back to 100% and unmuted, which also drops every volume tap.
    func resetAll() {
        volumes = [:]
        muted = []
        persist()
        resync()
    }

    /// The closed notch's meter: a fade through the colors of every app shown beside it, or one
    /// app's own fade when only one is playing.
    var playingColors: [NSColor] {
        let shown = playingApps.prefix(NotchViewModel.maxEarIcons)
        return shown.count == 1 ? shown[shown.startIndex].meterColors : shown.map(\.tint)
    }

    /// The playing apps for the closed notch: the one that owns the meter first.
    var playingApps: [AppEntry] {
        guard let primary = primaryApp else { return [] }
        return [primary] + apps.filter { $0.isPlaying && $0.id != primary.id }
    }

    // MARK: Internals

    private func changed(_ id: String) {
        apply(id, outputUID: CA.deviceUID(CA.defaultOutputDevice))
        persist()
    }

    /// Saves the levels shortly after the last change: a slider drag changes them many times a
    /// second, and each write to the defaults database is a cross-process call.
    private func persist() {
        guard !persistPending else { return }
        persistPending = true
        after(0.5) { [weak self] in
            guard let self else { return }
            persistPending = false
            defaults.set(volumes, forKey: "volumes")
            defaults.set(Array(muted), forKey: "muted")
        }
    }

    /// False until the launch permission question has been answered. No tap starts before that:
    /// a tap started on the main thread would freeze the notch for as long as the question is up.
    /// Called when the list of apps, or which of them are playing, changes.
    var appsChanged: (@MainActor () -> Void)?

    private var tapsAllowed = false

    func audioPermissionAnswered() {
        tapsAllowed = true
        resync()
    }

    private func gain(_ id: String) -> Float { muted.contains(id) ? 0 : (volumes[id] ?? 1) }

    private func resync() {
        let uid = CA.deviceUID(CA.defaultOutputDevice)
        for app in apps { apply(app.id, outputUID: uid) }
        syncMix(outputUID: uid)
    }

    /// Coalesces bursts of Core Audio notifications into one refresh.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        after(0.1) { [weak self] in self?.refreshPending = false; self?.refresh() }
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
        case .primary: wantsMeter = false   // the mix tap covers the closed notch
        }
        guard tapsAllowed, let entry = apps.first(where: { $0.id == id }), !entry.processObjects.isEmpty,
              needsVolume || (entry.isPlaying && wantsMeter), let outputUID else {
            if taps[id] != nil {
                let began = Date()
                taps[id] = nil
                Log.audio.info("tap stopped app=\(id, privacy: .public) ms=\(Int(Date().timeIntervalSince(began) * 1000), privacy: .public)")
            }
            return
        }
        let state = states[id] ?? TapState(gain)
        states[id] = state
        state.target = gain

        if let tap = taps[id], tap.processObjects == entry.processObjects,
           tap.outputUID == outputUID, tap.passthrough == !needsVolume { return }
        let began = Date()
        if taps[id] != nil { taps[id] = nil }   // the old tap must be gone before the new one starts
        do {
            taps[id] = try AppVolumeTap(processObjects: entry.processObjects, outputUID: outputUID,
                                        passthrough: !needsVolume, state: state)
            if lastError != nil { lastError = nil }
            Log.audio.info("tap started app=\(id, privacy: .public) volume=\(needsVolume, privacy: .public) ms=\(Int(Date().timeIntervalSince(began) * 1000), privacy: .public)")
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

        // Listen for each process starting or stopping audio instead of polling. macOS announces
        // IsRunning and, measured here, never IsRunningOutput, which is the one nxtch reads. So it
        // listens to both, and looks twice: the output flag can settle a moment after the notice.
        for proc in processes where !listened.contains(proc.objectID) {
            for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput] {
                CA.listen(proc.objectID, selector) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.scheduleRefresh()
                        after(0.5) { self?.scheduleRefresh() }
                    }
                }
            }
        }
        listened = Set(processes.map(\.objectID))

        var grouped: [String: AppEntry] = [:]
        var running: [String: NSRunningApplication] = [:]
        for proc in processes where proc.pid != me {
            guard let app = NSRunningApplication(processIdentifier: proc.responsiblePID)
                    ?? NSRunningApplication(processIdentifier: proc.pid),
                  app.activationPolicy == .regular, let bid = app.bundleIdentifier, app.processIdentifier != me
            else { continue }
            if grouped[bid] == nil {
                // The icon and its color are only read (from disk) for apps that end up shown.
                grouped[bid] = AppEntry(id: bid, name: app.localizedName ?? bid, icon: icons[bid] ?? Self.blank, tint: tints[bid] ?? .white,
                                        processObjects: [], isPlaying: false)
                if icons[bid] == nil { running[bid] = app }
            }
            grouped[bid]!.processObjects.insert(proc.objectID)
            grouped[bid]!.isPlaying = grouped[bid]!.isPlaying || proc.isRunningOutput
        }

        // Show apps that are playing, played in the last 2 minutes, or have a custom setting.
        let now = Date()
        for e in grouped.values where e.isPlaying { lastPlayed[e.id] = now }
        var visible = grouped.values
            .filter { $0.isPlaying || gain($0.id) != 1 || now.timeIntervalSince(lastPlayed[$0.id] ?? .distantPast) < 120 }
            .sorted { $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for i in visible.indices where icons[visible[i].id] == nil {
            let e = visible[i]
            let icon = running[e.id]?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            icons[e.id] = icon
            tints[e.id] = icon.vividColor
            visible[i] = AppEntry(id: e.id, name: e.name, icon: icon, tint: tints[e.id] ?? .white,
                                  processObjects: e.processObjects, isPlaying: e.isPlaying)
        }
        if visible != apps {
            apps = visible
            appsChanged?()
            Log.audio.info("apps: \(visible.map { $0.name + ($0.isPlaying ? "*" : "") }.joined(separator: ", "), privacy: .public)")
        }

        let ids = Set(visible.map(\.id))
        for id in taps.keys where !ids.contains(id) { taps[id] = nil }
        // Taps start on the next pass of the run loop, not here: starting one can take a second,
        // and the list above should reach the screen (the icons beside the notch) first.
        guard !tapsPending else { return }
        tapsPending = true
        onMain { [weak self] in self?.tapsPending = false; self?.resync() }
    }

    private var tapsPending = false
}
