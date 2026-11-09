import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what) failed (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(status: status, what: what) }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static var defaultOutputDevice: AudioDeviceID {
        CA.get(system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(kAudioObjectUnknown)) ?? AudioDeviceID(kAudioObjectUnknown)
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ object: AudioObjectID) -> String? { string(object, kAudioObjectPropertyName) }

    @discardableResult
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       queue: DispatchQueue = .main, _ block: @escaping () -> Void) -> Bool {
        var addr = address(selector)
        return AudioObjectAddPropertyListenerBlock(object, &addr, queue) { _, _ in block() } == noErr
    }
}

/// One Core Audio "process object" — any process that has opened an audio client.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool

    static func all() -> [AudioProcess] {
        CA.objectList(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.get(id, kAudioProcessPropertyPID, pid_t(-1)), pid > 0 else { return nil }
            let running = (CA.get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            return AudioProcess(objectID: id, pid: pid,
                                bundleID: CA.string(id, kAudioProcessPropertyBundleID),
                                isRunningOutput: running)
        }
    }
}

/// Maps helper processes (Chrome Helper, WebKit GPU process, …) to the app that owns them.
enum ResponsiblePID {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func of(_ pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }
}
