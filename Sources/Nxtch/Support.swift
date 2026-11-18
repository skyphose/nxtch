import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import os

// Small shared pieces with no state of their own: timing, animation curves, logging, the global
// shortcut, the synthesized paste, and nxtch's folders on disk.

// MARK: Main-thread timing

/// Runs `body` on the main actor after `delay` seconds. Cancel the returned item to call it off.
@MainActor @discardableResult
func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem { MainActor.assumeIsolated(body) }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
}

/// Runs `body` on the main thread on its next pass, from whatever thread this is called on.
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
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
    /// Small controls reacting to the pointer, and pressing anything.
    static let control = Animation.spring(response: 0.2, dampingFraction: 0.7)
    /// A clipboard row floating up under the cursor: a little bounce.
    static let lift = Animation.spring(response: 0.22, dampingFraction: 0.6)
    /// A row popping when it's copied: more bounce, so it reads as done.
    static let pop = Animation.spring(response: 0.25, dampingFraction: 0.5)
    /// Shade and image changes: nothing moves, so no spring.
    static let fade = Animation.easeOut(duration: 0.15)

    /// With Reduce Motion on, a short fade replaces the springs.
    static func notch(opening: Bool) -> Animation {
        Motion.reduced ? .fade : (opening ? .notch : .notchClose)
    }
}

enum Motion {
    /// Reduce Motion is on: things fade or change shade, nothing grows, shrinks or bounces.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// `s`, or 1 with Reduce Motion on.
    static func scale(_ s: CGFloat) -> CGFloat { reduced ? 1 : s }
}

// MARK: Logging

/// State changes only, never per frame. Read with:
///   /usr/bin/log stream --info --predicate 'subsystem == "dev.nxtch.app"'
enum Log {
    static let subsystem = "dev.nxtch.app"
    static let notch = Logger(subsystem: subsystem, category: "notch")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let memory = Logger(subsystem: subsystem, category: "memory")
}

// MARK: Memory watchdog

/// nxtch's own memory, the "footprint" Activity Monitor shows, from one kernel call.
func memoryFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

/// Checks nxtch's memory once a minute. Past the budget it logs a warning, once. Far past it
/// (something is leaking) it logs a fault and restarts nxtch, which frees everything.
@MainActor
final class MemoryWatchdog {
    enum Verdict: Equatable { case fine, warn, restart }

    /// nxtch idles around 16 MB and settles near 34 MB once the panel has been opened.
    nonisolated static let warnBytes: UInt64 = 150 << 20
    nonisolated static let restartBytes: UInt64 = 400 << 20
    /// No restart this soon after launch, so a leak that fills up in seconds can't loop.
    nonisolated static let minUptime: TimeInterval = 10 * 60

    nonisolated static func verdict(_ bytes: UInt64, uptime: TimeInterval) -> Verdict {
        if bytes >= restartBytes, uptime >= minUptime { return .restart }
        return bytes >= warnBytes ? .warn : .fine
    }

    private let launched = Date()
    private var warned = false
    private var timer: Timer?

    init() { timer = .repeating(60, tolerance: 15) { [weak self] in self?.check() } }

    private func check() {
        guard let used = memoryFootprint() else { return }
        let mb = used >> 20
        switch Self.verdict(used, uptime: Date().timeIntervalSince(launched)) {
        case .fine: return
        case .warn:
            if !warned { warned = true; Log.memory.error("using \(mb, privacy: .public) MB, past the \(Self.warnBytes >> 20, privacy: .public) MB warning line") }
        case .restart:
            Log.memory.fault("using \(mb, privacy: .public) MB, past \(Self.restartBytes >> 20, privacy: .public) MB: restarting")
            restart()
        }
    }

    /// Opens a fresh copy a second after this one quits. The bundle path goes in as an argument,
    /// never into the command text.
    private func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        relaunch.environment = [:]   // nothing inherited, like the now-playing helper
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

// MARK: Global shortcut

/// The shortcut that opens clipboard history. A short list rather than a recorder: each one is
/// free in the apps most people use (not ⇧⌘V, paste and match style, or ⌥⌘V, Finder's move).
/// Where a letter sits on the keyboard layout in use. Shortcuts are registered by key position,
/// and "V" is not in the same place on every layout: on Dvorak it is where QWERTY has the period.
enum KeyLayout {
    /// The key code that types `letter`, or nil if the layout has no such key. `command` asks
    /// which key gives it with ⌘ held, which differs on layouts like "Dvorak - QWERTY ⌘".
    /// `layoutID` picks a layout by id (for tests); nil is the current one, or the Latin one
    /// beside it when the current layout has no Latin letters.
    static func code(for letter: Character, command: Bool = false, layoutID: String? = nil) -> Int? {
        let source: TISInputSource?
        if let layoutID {
            let filter = [kTISPropertyInputSourceID as String: layoutID] as CFDictionary
            source = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        } else {
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let want = String(letter).lowercased()
        return data.withUnsafeBytes { bytes -> Int? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), command ? UInt32(cmdKey >> 8) : 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == want { return code }
            }
            return nil
        }
    }

    /// The V key for shortcuts, and for ⌘V. Falls back to its QWERTY position.
    static var v: Int { code(for: "v") ?? kVK_ANSI_V }
    static var pasteV: Int { code(for: "v", command: true) ?? v }
}

/// How long clipboard history keeps unpinned items. Off stops recording; what is already there stays,
/// and still goes after a week.
enum ClipboardKeep: String, CaseIterable, Identifiable {
    case off, hour, day, week, twoWeeks, month

    var id: Self { self }

    var title: String {
        switch self {
        case .off: return "Off"
        case .hour: return "1 Hour"
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .twoWeeks: return "2 Weeks"
        case .month: return "1 Month"
        }
    }

    /// The saved choice. Before the menu it was a switch: on kept a week.
    static var saved: ClipboardKeep {
        let d = UserDefaults.standard
        return ClipboardKeep(rawValue: d.string(forKey: "clipboardKeep") ?? "")
            ?? (d.object(forKey: "clipboardEnabled") as? Bool == false ? .off : .week)
    }

    var maxAge: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .off, .week: return 7 * 86_400
        case .twoWeeks: return 14 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

enum ClipboardShortcut: String, CaseIterable, Identifiable {
    case controlOptionV, controlCommandV, controlShiftV, off

    var id: Self { self }

    var title: String {
        switch self {
        case .controlOptionV: return "⌃⌥V"
        case .controlCommandV: return "⌃⌘V"
        case .controlShiftV: return "⌃⇧V"
        case .off: return "Off"
        }
    }

    /// Carbon key code and modifiers, or nil when off.
    var keys: (code: Int, modifiers: Int)? {
        switch self {
        case .controlOptionV: return (KeyLayout.v, controlKey | optionKey)
        // With ⌘ held, layouts like "Dvorak - QWERTY ⌘" switch to QWERTY: V is where ⌘ puts it.
        case .controlCommandV: return (KeyLayout.pasteV, controlKey | cmdKey)
        case .controlShiftV: return (KeyLayout.v, controlKey | shiftKey)
        case .off: return nil
        }
    }
}

/// A system-wide shortcut through Carbon's RegisterEventHotKey (needs no permission). One event
/// handler serves every shortcut and tells them apart by id; changing a shortcut only swaps its
/// registration.
final class Hotkey {
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]

    init(id: UInt32, _ handler: @escaping () -> Void) {
        self.id = id
        let first = Self.handlers.isEmpty
        Self.handlers[id] = handler
        guard first else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let id = pressed.id
            DispatchQueue.main.async { Hotkey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers the key, replacing the previous one. nil just unregisters.
    func set(code: Int?, modifiers: Int = 0) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let code else { return }
        let hotkey = EventHotKeyID(signature: OSType(0x6E787463) /* 'nxtc' */, id: id)
        let status = RegisterEventHotKey(UInt32(code), UInt32(modifiers), hotkey, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.notch.error("hotkey \(self.id, privacy: .public) not registered (\(status)); another app may own it") }
    }

    func set(_ shortcut: ClipboardShortcut) { set(code: shortcut.keys?.code, modifiers: shortcut.keys?.modifiers ?? 0) }

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
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyLayout.pasteV), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        return true
    }
}

// MARK: Files on disk

/// ~/Library/Application Support/nxtch/<name>: readable by this user only, kept out of Time Machine.
enum AppFiles {
    static func dir(_ name: String) -> URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nxtch/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Never through a symlink: that would change wherever the link points instead.
        guard isOwnFolder(url) else { return url }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)   // also fixes existing folders
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// `dir` and the nxtch folder above it are real folders, not symlinks to somewhere else.
    /// Everything nxtch writes or deletes goes through this, so a swapped-in link can't send a
    /// delete into your Documents.
    static func isOwnFolder(_ dir: URL) -> Bool {
        [dir, dir.deletingLastPathComponent()].allSatisfy {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeDirectory
        }
    }

    /// A file name that can't leave its folder or disguise itself: no path separators or "..",
    /// no control or bidi-override characters, not hidden, not absurdly long.
    static func safeName(_ raw: String, fallback: String = "item") -> String {
        let cleaned = raw.withoutInvisibles
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
        url.standardizedFileURL.deletingLastPathComponent().path == dir.standardizedFileURL.path && isOwnFolder(dir)
    }
}

extension String {
    /// Without control and format characters (bidi overrides, zero-width joiners and the like),
    /// which can hide or disguise what a string really says.
    var withoutInvisibles: String {
        String(String.UnicodeScalarView(unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }))
    }
}
