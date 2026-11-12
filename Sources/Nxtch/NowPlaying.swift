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

extension NowPlayingInfo {
    /// One report from the helper. nil when nothing is playing (no title).
    /// Any web page can set these through the Media Session API, so text is capped and times are
    /// kept in a sane range.
    init?(json o: [String: Any]) {
        guard let title = o["title"] as? String, !title.isEmpty else { return nil }
        func text(_ key: String) -> String? { (o[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) } }
        func seconds(_ key: String) -> Double? { (o[key] as? Double).flatMap { $0.isFinite && $0 >= 0 && $0 < 1e7 ? $0 : nil } }
        self.init(
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
}

enum MediaKey: Int32 {
    case playPause = 2   // kMRTogglePlayPause
    case next = 4        // kMRNextTrack
    case previous = 5    // kMRPreviousTrack
}

@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    /// What the helper last said. `info` can run ahead of it after a button press.
    private var reported: NowPlayingInfo?
    /// Called when a different app takes over now playing.
    var ownerChanged: (@MainActor () -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 2

    /// The helper is a second process of about 22 MB, more than nxtch itself. So it only runs
    /// while it has something to report: an app is playing, or the notch is open. Two minutes
    /// after both stop being true it quits, and what was playing is forgotten until it's back.
    private var pipe: Pipe?
    private var needed = false
    private var stopWork: DispatchWorkItem?
    private static let linger: TimeInterval = 120

    func setNeeded(_ now: Bool) {
        guard now != needed else { return }
        needed = now
        stopWork?.cancel(); stopWork = nil
        if now {
            if process == nil { launch() }
        } else {
            stopWork = after(Self.linger) { [weak self] in self?.stopWork = nil; self?.stop() }
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil   // nothing late from the old helper
        pipe = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        buffer.removeAll()
        if reported != nil || info != nil {
            reported = nil
            info = nil
            ownerChanged?()
        }
        Log.audio.info("now-playing helper stopped")
    }

    /// Sends a media command and flips the play state right away (the helper confirms within ~1 s).
    func send(_ key: MediaKey) {
        Log.notch.info("media command \(key.rawValue, privacy: .public)")
        _ = Self.osascript(Self.commandScript, String(key.rawValue))
        if key == .playPause, var i = info {
            if i.isPlaying, let pos = i.position() { i.elapsed = pos }   // freeze progress where it is
            i.isPlaying.toggle()
            i.timestamp = Date()
            info = i
            // The helper only reports changes. If the app ignored the press, nothing comes back,
            // so fall back to what it last said.
            after(1.5) { [weak self] in if let self, info != reported { info = reported } }
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
        guard needed, process == nil else { return }   // a restart that was queued before a stop
        Log.audio.info("now-playing helper started")
        let pipe = Pipe()   // JXA console.log writes to stderr
        self.pipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            onMain { self?.consume(data) }
        }
        let started = Date()
        process = Self.osascript(Self.monitorScript, String(ProcessInfo.processInfo.processIdentifier), stderr: pipe)
        process?.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.process = nil
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
        let new = NowPlayingInfo(json: o)
        let ownerMoved = new?.bundleID != reported?.bundleID || new?.parentBundleID != reported?.parentBundleID
        reported = new
        info = new
        if ownerMoved { ownerChanged?() }
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

    // Waits for MediaRemote's change notifications instead of checking every second: a change
    // is read 0.2 s after its first notification (each one arrives as a burst of about 20), with
    // a full re-read every 60 s as a safety net. Measured: 0.4 wakeups/s and ~0% cpu, against 29
    // and 0.5% for the old once-a-second check (JXA's delay() wakes ~28 times a second).
    private static let monitorScript = #"""
    ObjC.import('Foundation');
    ObjC.bindFunction('getppid', ['int', []]);
    ObjC.bindFunction('dispatch_get_global_queue', ['id', ['long', 'unsigned long']]);
    function run(argv) {
      const parentPID = parseInt(argv[0]);
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      ObjC.bindFunction('MRMediaRemoteRegisterForNowPlayingNotifications', ['void', ['id']]);
      const R = $.NSClassFromString('MRNowPlayingRequest');
      const str = (d, k) => { const v = d.objectForKey(k); return v.isNil() ? null : ObjC.unwrap(v); };
      let last = '', due = 0, safety = 0;
      $.NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock($(), $(), $.NSOperationQueue.mainQueue, n => {
        const name = ObjC.unwrap(n.name);
        if (!due && (name.indexOf('MRMediaRemote') >= 0 || name.indexOf('NowPlaying') >= 0)) due = Date.now() + 200;
      });
      $.MRMediaRemoteRegisterForNowPlayingNotifications($.dispatch_get_global_queue(0, 0));
      const read = () => {
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
      };
      while (true) {
        if ($.getppid() !== parentPID) return;   // nxtch is gone
        const now = Date.now();
        if (now >= safety || (due && now >= due)) { due = 0; safety = now + 60000; read(); }
        // Wake for a pending read, else at most every 10 s to notice nxtch quitting.
        const wait = due ? Math.max(0.05, (due - Date.now()) / 1000) : 10;
        const ran = $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode, $.NSDate.dateWithTimeIntervalSinceNow(wait));
        if (!ran) { $.NSThread.sleepForTimeInterval(1); due = Date.now(); }   // no notifications: check once a second
      }
    }
    """#
}
