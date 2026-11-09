import AppKit
import ApplicationServices
import ServiceManagement

/// Media commands, sent through macOS's now-playing system (the same path as Control Center's
/// buttons), so they need no permission. MediaRemote only accepts Apple-signed callers, so — like
/// reading now-playing info — the command goes through a one-shot `osascript` (JXA) call.
enum MediaKey: Int32 {
    case playPause = 2   // kMRTogglePlayPause
    case next = 4        // kMRNextTrack
    case previous = 5    // kMRPreviousTrack

    func send() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", Self.script, String(rawValue)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private static let script = #"""
    ObjC.import('Foundation');
    function run(argv) {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      $.MRMediaRemoteSendCommand(parseInt(argv[0]), $());
      delay(0.4);  // the send is asynchronous: exiting immediately drops the command
    }
    """#
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("nxtch: launch at login: \(error)")
        }
    }
}

/// Synthesized keystrokes (needs Accessibility, same as media keys).
enum Keystroke {
    @discardableResult
    static func paste() -> Bool {
        guard InputPermission.ensure() else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // kVK_ANSI_V
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Accessibility permission, needed to send media keys and ⌘V.
///
/// `AXIsProcessTrustedWithOptions(prompt:)` is the request that reliably shows the system
/// dialog and adds nxtch to System Settings › Privacy & Security › Accessibility (with its toggle).
enum InputPermission {
    static var granted: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    /// True if allowed; otherwise asks (once per launch) and returns false.
    static func ensure() -> Bool {
        if granted { return true }
        if !asked {
            asked = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static var asked = false
}
