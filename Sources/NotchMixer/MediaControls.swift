import AppKit
import ServiceManagement

/// Sends hardware media-key events (the same as F7/F8/F9), which macOS routes to the
/// current Now Playing app. Needs the "Accessibility" permission to post events.
enum MediaKey: Int {
    case playPause = 16   // NX_KEYTYPE_PLAY
    case next = 17        // NX_KEYTYPE_NEXT
    case previous = 18    // NX_KEYTYPE_PREVIOUS

    /// Returns false when permission is missing (macOS shows its prompt the first time).
    @discardableResult
    func send() -> Bool {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return false }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (rawValue << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NotchMixer: launch at login: \(error)")
        }
    }
}
