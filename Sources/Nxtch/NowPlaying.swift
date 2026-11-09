import AppKit
import Combine

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var bundleID: String?
    var parentBundleID: String?
    var isPlaying: Bool
    var elapsed: Double?
    var duration: Double?
    var timestamp: Date?
    var rate: Double

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album && a.bundleID == b.bundleID
            && a.isPlaying == b.isPlaying && a.elapsed == b.elapsed && a.duration == b.duration
            && a.timestamp == b.timestamp
    }

    /// Whether this media belongs to the app with the given bundle ID.
    func belongs(to appID: String) -> Bool { bundleID == appID || parentBundleID == appID }

    /// Playback position extrapolated to `date`.
    func position(at date: Date = Date()) -> Double? {
        guard let elapsed else { return nil }
        guard isPlaying, let timestamp else { return elapsed }
        let p = elapsed + date.timeIntervalSince(timestamp) * rate
        return duration.map { min(p, $0) } ?? p
    }
}

/// Reads the system "Now Playing" info.
///
/// Since macOS 15.4 the private MediaRemote API only answers Apple-signed processes, so — like
/// boring.notch — we ask through an Apple-signed binary: a long-running `osascript` (JXA) helper
/// that prints a JSON line whenever the now-playing state changes.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    /// Sends a media command and updates the play state right away (the helper confirms within ~1 s).
    func send(_ key: MediaKey) {
        key.send()
        if key == .playPause, var i = info {
            if i.isPlaying, let pos = i.position() { i.elapsed = pos }   // freeze progress where it is
            i.isPlaying.toggle()
            i.timestamp = Date()
            info = i
        }
    }

    private var process: Process?
    private var buffer = Data()

    init() { launch() }

    func stop() { process?.terminationHandler = nil; process?.terminate() }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", Self.script, String(ProcessInfo.processInfo.processIdentifier)]
        let pipe = Pipe()
        p.standardError = pipe      // JXA console.log writes to stderr
        p.standardOutput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { self?.launch() } // helper died → restart
            }
        }
        do { try p.run(); process = p } catch { NSLog("nxtch: now-playing helper failed: \(error)") }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ o: [String: Any]) {
        guard let title = o["title"] as? String, !title.isEmpty else { info = nil; return }
        info = NowPlayingInfo(
            title: title,
            artist: (o["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: o["album"] as? String,
            bundleID: o["bundle"] as? String,
            parentBundleID: o["parent"] as? String,
            isPlaying: o["playing"] as? Bool ?? false,
            elapsed: o["elapsed"] as? Double,
            duration: (o["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            timestamp: (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) },
            rate: o["rate"] as? Double ?? 1)
    }

    private static let script = #"""
    ObjC.import('Foundation');
    ObjC.import('AppKit');
    function run(argv) {
      const parentPID = parseInt(argv[0]);
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      const R = $.NSClassFromString('MRNowPlayingRequest');
      const str = (d, k) => { const v = d.objectForKey(k); return v.isNil() ? null : ObjC.unwrap(v); };
      let last = '';
      while (true) {
        if ($.NSRunningApplication.runningApplicationWithProcessIdentifier(parentPID).isNil()) return;
        const out = { playing: false };
        try {
          out.playing = !!R.localIsPlaying;
          const item = R.localNowPlayingItem;
          if (!item.isNil()) {
            const info = item.nowPlayingInfo;
            if (!info.isNil()) {
              out.title = str(info, 'kMRMediaRemoteNowPlayingInfoTitle');
              out.artist = str(info, 'kMRMediaRemoteNowPlayingInfoArtist');
              out.album = str(info, 'kMRMediaRemoteNowPlayingInfoAlbum');
              out.elapsed = str(info, 'kMRMediaRemoteNowPlayingInfoElapsedTime');
              out.duration = str(info, 'kMRMediaRemoteNowPlayingInfoDuration');
              out.rate = str(info, 'kMRMediaRemoteNowPlayingInfoPlaybackRate');
              const ts = info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
              if (!ts.isNil()) out.timestamp = ts.timeIntervalSince1970;
            }
          }
          const path = R.localNowPlayingPlayerPath;
          if (!path.isNil()) {
            const c = path.client;
            if (!c.isNil()) {
              out.bundle = ObjC.unwrap(c.bundleIdentifier);
              out.parent = ObjC.unwrap(c.parentApplicationBundleIdentifier);
            }
          }
        } catch (e) { out.error = String(e); }
        const j = JSON.stringify(out);
        if (j !== last) { console.log(j); last = j; }
        delay(1);
      }
    }
    """#
}
