import AppKit
import Combine

// Since macOS 15.4 the private MediaRemote framework only answers Apple-signed processes, so
// nxtch talks to it through one: /usr/bin/osascript running JXA. A long-running helper reports
// what's playing; each playback button runs a short one-shot script.

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

    func belongs(to appID: String) -> Bool { bundleID == appID || parentBundleID == appID }

    /// Playback position extrapolated to `date`.
    func position(at date: Date = Date()) -> Double? {
        guard let elapsed else { return nil }
        guard isPlaying, let timestamp else { return elapsed }
        let p = elapsed + date.timeIntervalSince(timestamp) * rate
        return duration.map { min(p, $0) } ?? p
    }
}

enum MediaKey: Int32 {
    case playPause = 2   // kMRTogglePlayPause
    case next = 4        // kMRNextTrack
    case previous = 5    // kMRPreviousTrack
}

@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?

    private var process: Process?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 2

    init() { launch() }

    func stop() { process?.terminationHandler = nil; process?.terminate() }

    /// Sends a media command and flips the play state right away (the helper confirms within ~1 s).
    func send(_ key: MediaKey) {
        Log.notch.info("media command \(key.rawValue, privacy: .public)")
        _ = Self.osascript(Self.commandScript, String(key.rawValue))
        if key == .playPause, var i = info {
            if i.isPlaying, let pos = i.position() { i.elapsed = pos }   // freeze progress where it is
            i.isPlaying.toggle()
            i.timestamp = Date()
            info = i
        }
    }

    private static func osascript(_ script: String, _ arg: String, stderr: Pipe? = nil) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script, arg]
        p.environment = ["HOME": NSHomeDirectory()]   // nothing inherited from whatever launched nxtch
        p.standardOutput = FileHandle.nullDevice
        p.standardError = stderr ?? FileHandle.nullDevice
        do { try p.run(); return p } catch { NSLog("nxtch: osascript failed: \(error)"); return nil }
    }

    private func launch() {
        let pipe = Pipe()   // JXA console.log writes to stderr
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        let started = Date()
        process = Self.osascript(Self.monitorScript, String(ProcessInfo.processInfo.processIdentifier), stderr: pipe)
        process?.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Restart, backing off if it keeps dying right away.
                    self.restartDelay = Date().timeIntervalSince(started) > 60 ? 2 : min(self.restartDelay * 2, 300)
                    after(self.restartDelay) { self.launch() }
                }
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        if buffer.count > 1 << 20 { buffer.removeAll() }   // a line is a few hundred bytes
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
        }
    }

    private func handle(_ o: [String: Any]) {
        guard let title = o["title"] as? String, !title.isEmpty else { info = nil; return }
        // Any web page can set these through the Media Session API, so keep them in a sane range.
        func seconds(_ key: String) -> Double? { (o[key] as? Double).flatMap { $0.isFinite && $0 >= 0 && $0 < 1e7 ? $0 : nil } }
        func text(_ key: String) -> String? { (o[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) } }
        info = NowPlayingInfo(
            title: String(title.prefix(300)),
            artist: text("artist"),
            album: text("album"),
            bundleID: o["bundle"] as? String,
            parentBundleID: o["parent"] as? String,
            isPlaying: o["playing"] as? Bool ?? false,
            elapsed: seconds("elapsed"),
            duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil },
            timestamp: (o["timestamp"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil },
            rate: (o["rate"] as? Double).map { $0.isFinite ? min(max($0, -8), 8) : 1 } ?? 1)
    }

    private static let commandScript = #"""
    ObjC.import('Foundation');
    function run(argv) {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      $.MRMediaRemoteSendCommand(parseInt(argv[0]), $());
      delay(0.4);  // the send is asynchronous: exiting immediately drops the command
    }
    """#

    private static let monitorScript = #"""
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
          const info = item.isNil() ? null : item.nowPlayingInfo;
          if (info && !info.isNil()) {
            out.title = str(info, 'kMRMediaRemoteNowPlayingInfoTitle');
            out.artist = str(info, 'kMRMediaRemoteNowPlayingInfoArtist');
            out.album = str(info, 'kMRMediaRemoteNowPlayingInfoAlbum');
            out.elapsed = str(info, 'kMRMediaRemoteNowPlayingInfoElapsedTime');
            out.duration = str(info, 'kMRMediaRemoteNowPlayingInfoDuration');
            out.rate = str(info, 'kMRMediaRemoteNowPlayingInfoPlaybackRate');
            const ts = info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
            if (!ts.isNil()) out.timestamp = ts.timeIntervalSince1970;
          }
          const path = R.localNowPlayingPlayerPath;
          const c = path.isNil() ? null : path.client;
          if (c && !c.isNil()) {
            out.bundle = ObjC.unwrap(c.bundleIdentifier);
            out.parent = ObjC.unwrap(c.parentApplicationBundleIdentifier);
          }
        } catch (e) { out.error = String(e); }
        const j = JSON.stringify(out);
        if (j !== last) { console.log(j); last = j; }
        delay(1);
      }
    }
    """#
}
