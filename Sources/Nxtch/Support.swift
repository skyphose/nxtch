import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import os

// Small shared pieces with no state of their own: timing, animation curves, logging, the global
// shortcut, the synthesized paste, and nxtch's folders on disk.

// MARK: Main-thread timing

/// Runs `body` on the main actor after `delay` seconds.
@MainActor
func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
}

extension Timer {
    /// A repeating main-thread timer. The tolerance lets macOS batch wakeups.
    @MainActor
    static func repeating(_ interval: TimeInterval, tolerance: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let t = scheduledTimer(withTimeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated(body) }
        t.tolerance = tolerance
        return t
    }
}

// MARK: Animation

extension Animation {
    /// The panel opening, and anything inside it changing size.
    static let notch = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// The panel closing: quicker, and no bounce on the way out.
    static let notchClose = Animation.spring(response: 0.24, dampingFraction: 1)
    /// Small controls reacting to the pointer.
    static let control = Animation.spring(response: 0.2, dampingFraction: 0.7)

    /// With Reduce Motion on, a short fade replaces the springs.
    static func notch(opening: Bool) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.12) : (opening ? .notch : .notchClose)
    }
}

// MARK: Logging

/// State changes only, never per frame. Read with:
///   /usr/bin/log stream --info --predicate 'subsystem == "dev.nxtch.app"'
enum Log {
    static let subsystem = "dev.nxtch.app"
    static let notch = Logger(subsystem: subsystem, category: "notch")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
}

extension Notification.Name {
    static let nxtchRequestClose = Notification.Name("nxtchRequestClose")
}

// MARK: Global shortcut

/// One system-wide shortcut through Carbon's RegisterEventHotKey (needs no permission).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        Self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x6E787463) /* 'nxtc' */, id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.notch.error("hotkey not registered (\(status)); another app may own it") }
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}

// MARK: Synthesized ⌘V

/// Presses ⌘V, but only if `pid` is the frontmost app: if focus didn't come back to the app you
/// were in, the item stays on the clipboard instead of landing somewhere else.
/// Needs Accessibility; without it, does nothing and asks once.
enum Keystroke {
    private static var asked = false

    @discardableResult
    static func paste(into pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            Log.clipboard.info("paste skipped: target app is no longer frontmost")
            return false
        }
        guard AXIsProcessTrusted() || CGPreflightPostEventAccess() else {
            if !asked {
                asked = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            return false
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        return true
    }
}

// MARK: Files on disk

/// ~/Library/Application Support/nxtch/<name>, readable by this user only.
enum AppFiles {
    static func dir(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nxtch/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)   // also fixes existing folders
        return url
    }

    /// A file name that can't leave its folder or disguise itself: no path separators or "..",
    /// no control or bidi-override characters, not hidden, not absurdly long.
    static func safeName(_ raw: String, fallback: String = "item") -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }))
        .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        let ext = (cleaned as NSString).pathExtension
        let name = cleaned.count <= 120 || ext.isEmpty || ext.count > 10
            ? String(cleaned.prefix(120))
            : String((cleaned as NSString).deletingPathExtension.prefix(110)) + "." + ext
        return name.isEmpty ? fallback : name
    }

    /// A URL in `dir` for `name` (sanitized) that doesn't exist yet.
    static func unique(_ name: String, in dir: URL) -> URL? {
        let safe = safeName(name)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var url = dir.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return contains(dir, url) ? url : nil
    }

    static func contains(_ dir: URL, _ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == dir.standardizedFileURL.path
    }
}
