import AppKit
import Combine
import CoreAudio

struct AppEntry: Identifiable, Equatable {
    let id: String            // bundle identifier of the owning app
    let name: String
    let icon: NSImage
    /// The icon's most vivid colour, for this app's level meter.
    let tint: NSColor
    var processObjects: Set<AudioObjectID>
    var isPlaying: Bool

    /// One app's meter fades from its colour to a lighter shade of it.
    var meterColors: [NSColor] { [tint, tint.blended(withFraction: 0.5, of: .white) ?? tint] }

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
    private var tints: [String: NSColor] = [:]   // worked out once per app, from its icon
    private var listened = Set<AudioObjectID>()
    private var refreshPending = false
    private var persistPending = false
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
        timer = .repeating(5, tolerance: 1) { [weak self] in self?.refresh() }
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
        // Snap to 100% so it's easy to get back to untouched, zero-latency audio.
        let value = snap && abs(value - 1) < 0.02 ? 1 : min(max(value, 0), Self.maxVolume)
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

    /// The closed notch's meter: a fade through the colours of every app shown beside it, or one
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

    private func gain(_ id: String) -> Float { muted.contains(id) ? 0 : (volumes[id] ?? 1) }

    private func resync() {
        let uid = CA.deviceUID(CA.defaultOutputDevice)
        for app in apps { apply(app.id, outputUID: uid) }
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
                if icons[bid] == nil {
                    icons[bid] = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
                    tints[bid] = icons[bid]!.vividColor
                }
                grouped[bid] = AppEntry(id: bid, name: app.localizedName ?? bid, icon: icons[bid]!, tint: tints[bid] ?? .white,
                                        processObjects: [], isPlaying: false)
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

extension NSImage {
    private static let noColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// The most vivid colour in the image: the dominant hue among its saturated pixels, brightened
    /// enough to read on black. White for an image with no real colour (a grey or monochrome icon).
    var vividColor: NSColor {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Self.noColor }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        // Bucket pixels by hue, weighted by how colourful and opaque they are.
        let buckets = 12
        var weight = [CGFloat](repeating: 0, count: buckets)
        var sum = [(r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: buckets)
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = CGFloat(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = CGFloat(px[i]) / 255 / a, g = CGFloat(px[i + 1]) / 255 / a, b = CGFloat(px[i + 2]) / 255 / a
            let hi = max(r, g, b), lo = min(r, g, b), sat = hi == 0 ? 0 : (hi - lo) / hi
            guard sat > 0.25, hi > 0.2 else { continue }
            var hue: CGFloat = 0
            if hi == r { hue = (g - b) / (hi - lo) } else if hi == g { hue = 2 + (b - r) / (hi - lo) } else { hue = 4 + (r - g) / (hi - lo) }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
            let k = min(buckets - 1, Int(hue * CGFloat(buckets))), w = sat * hi * a
            weight[k] += w
            sum[k].r += r * w; sum[k].g += g * w; sum[k].b += b * w
        }
        // A colour often straddles two buckets (a fox that is orange and amber), so the winner is
        // the fullest bucket counted together with its two neighbours, and all three are averaged.
        let near = { (k: Int) in [(k + buckets - 1) % buckets, k, (k + 1) % buckets] }
        let total = { (k: Int) in near(k).reduce(0) { $0 + weight[$1] } }
        guard let k = weight.indices.max(by: { total($0) < total($1) }), total(k) > 2 else { return Self.noColor }
        let w = total(k), rgb = near(k).reduce((r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))) { ($0.r + sum[$1].r, $0.g + sum[$1].g, $0.b + sum[$1].b) }
        let c = NSColor(srgbRed: rgb.r / w, green: rgb.g / w, blue: rgb.b / w, alpha: 1)
        return NSColor(hue: c.hueComponent, saturation: max(c.saturationComponent, 0.55), brightness: max(c.brightnessComponent, 0.9), alpha: 1)
    }
}
