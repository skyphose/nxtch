import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

// MARK: Core Audio helpers

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(status: status, what: what) }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let value = get(object, selector, Unmanaged<CFString>?.none) ?? nil else { return nil }
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

    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
        var addr = address(selector)
        AudioObjectAddPropertyListenerBlock(object, &addr, .main) { _, _ in block() }
    }
}

/// One Core Audio process object: any process that has opened an audio client.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let isRunningOutput: Bool

    static func all() -> [AudioProcess] {
        CA.objectList(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.get(id, kAudioProcessPropertyPID, pid_t(-1)), pid > 0 else { return nil }
            return AudioProcess(objectID: id, pid: pid,
                                isRunningOutput: (CA.get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
        }
    }

    /// The app that owns this process (Chrome Helper → Chrome, WebKit's GPU process → Safari).
    var responsiblePID: pid_t {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = Self.responsibleSym else { return pid }
        let r = unsafeBitCast(sym, to: Fn.self)(pid)
        return r > 0 ? r : pid
    }
    private static let responsibleSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
}

// MARK: Tap state

/// Per-app state shared between the main thread (writes the target gain, reads levels) and the
/// real-time audio thread (reads the gain, writes levels).
final class TapState: @unchecked Sendable {
    static let bandCount = 4
    /// Low-pass corners splitting the signal into 4 bands: <150, 150-600, 600-2.5k, >2.5k Hz.
    private static let corners: [Double] = [150, 600, 2500]
    /// Higher bands carry less energy; boost them so the bars look balanced.
    private static let bandBoost: [Float] = [1.0, 1.4, 2.2, 3.5]

    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let levelPtr = UnsafeMutablePointer<Float>.allocate(capacity: bandCount)

    // Audio thread only.
    var current: Float
    var lp: (Float, Float, Float) = (0, 0, 0)
    var coeff: (Float, Float, Float) = (0.02, 0.08, 0.3)

    // Main thread only.
    private var display = [Float](repeating: 0, count: bandCount)
    private var lastDisplayUpdate: CFTimeInterval = 0

    init(_ gain: Float) {
        gainPtr.initialize(to: gain)
        levelPtr.initialize(repeating: 0, count: Self.bandCount)
        current = gain
    }
    deinit { gainPtr.deallocate(); levelPtr.deallocate() }

    var target: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = newValue }
    }

    func configure(sampleRate: Double) {
        let c = Self.corners.map { Float(1 - exp(-2 * Double.pi * $0 / max(sampleRate, 8000))) }
        coeff = (c[0], c[1], c[2])
        lp = (0, 0, 0)
    }

    func store(_ b0: Float, _ b1: Float, _ b2: Float, _ b3: Float) {
        levelPtr[0] = b0; levelPtr[1] = b1; levelPtr[2] = b2; levelPtr[3] = b3
    }

    func reset() { store(0, 0, 0, 0) }

    /// Smoothed 0...1 bar heights (fast attack, slow release). Safe to call from several views per frame.
    func displayLevels(now: CFTimeInterval = CACurrentMediaTime()) -> [Float] {
        let dt = Float(min(max(now - lastDisplayUpdate, 0), 0.1))
        guard dt > 1.0 / 240 else { return display }
        lastDisplayUpdate = now
        for i in 0..<Self.bandCount {
            let db = 20 * log10(max(levelPtr[i] * Self.bandBoost[i], 1e-6))
            let target = max(0, min(1, (db + 54) / 48))   // -54 dBFS -> 0, -6 dBFS -> 1
            let rate: Float = target > display[i] ? 30 : 7  // attack / release per second
            display[i] += (target - display[i]) * min(1, rate * dt)
        }
        return display
    }
}

// MARK: Process tap

/// Taps every process of one app.
/// - `passthrough`: listen only (the app's audio is untouched), for metering.
/// - otherwise: the original output is muted and re-played at `state.target` gain.
final class AppVolumeTap {
    let processObjects: Set<AudioObjectID>
    let outputUID: String
    let passthrough: Bool
    private let state: TapState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "nxtch.tap", qos: .userInteractive)

    init(processObjects: Set<AudioObjectID>, outputUID: String, passthrough: Bool, state: TapState) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.passthrough = passthrough
        self.state = state
        do {
            try start(tapOnly: passthrough)
        } catch where passthrough {
            // The tap-only device is only proven on the macOS versions I run. If one refuses it,
            // listen the older way, through an aggregate that includes the output device.
            stop()
            do { try start(tapOnly: false) } catch { stop(); throw error }
        } catch { stop(); throw error }
    }

    deinit { stop(); state.reset() }

    private func start(tapOnly: Bool) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: Array(processObjects))
        desc.uuid = UUID()
        desc.name = "nxtch tap"
        desc.isPrivate = true
        desc.muteBehavior = passthrough ? .unmuted : .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Creating process tap")

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "nxtch",
            kAudioAggregateDeviceUIDKey: "dev.nxtch.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        if tapOnly {
            // Listening only: the tap alone, with no output device in the aggregate. nxtch then
            // isn't an output client of your speakers, and coreaudiod has no silent stream of
            // ours to mix: about 1 point less coreaudiod cpu, measured.
            aggregate[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: desc.uuid.uuidString]]
        } else {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            aggregate[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]
        }
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating aggregate device")

        state.configure(sampleRate: CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(48000)) ?? 48000)
        let state = self.state, passthrough = self.passthrough
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            AppVolumeTap.render(input: input, output: output, state: state, passthrough: passthrough)
        }, "Creating IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting aggregate device")
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Real-time callback: no allocations, no locks. A stereo-mixdown tap delivers one interleaved
    /// buffer, so the input is read from the first buffer only.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               state: TapState, passthrough: Bool) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buf in outList where buf.mData != nil { memset(buf.mData, 0, Int(buf.mDataByteSize)) }

        let first = input.pointee.mBuffers
        let fc = Int(first.mNumberChannels)
        guard input.pointee.mNumberBuffers > 0, fc > 0, let src = first.mData?.assumingMemoryBound(to: Float.self) else {
            state.reset(); return
        }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * fc)
        guard frames > 0 else { return }

        let start = passthrough ? 1 : state.current
        let target = passthrough ? 1 : state.target
        let step = (target - start) / Float(frames)

        // Metering: mono mix, post-gain, split into 4 bands by three one-pole low-passes.
        var (l0, l1, l2) = state.lp
        let (c0, c1, c2) = state.coeff
        var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
        var g = start
        for f in 0..<frames {
            g += step
            var x: Float = 0
            for ch in 0..<fc { x += src[f * fc + ch] }
            x = x / Float(fc) * g
            l0 += c0 * (x - l0); l1 += c1 * (x - l1); l2 += c2 * (x - l2)
            let b0 = l0, b1 = l1 - l0, b2 = l2 - l1, b3 = x - l2
            s0 += b0 * b0; s1 += b1 * b1; s2 += b2 * b2; s3 += b3 * b3
        }
        state.lp = (l0, l1, l2)
        let n = Float(frames)
        state.store(sqrt(s0 / n), sqrt(s1 / n), sqrt(s2 / n), sqrt(s3 / n))
        guard !passthrough else { return }

        // Volume: tap input -> device output, gain ramped across the buffer.
        var outChannel = 0
        for obuf in outList {
            let oc = Int(obuf.mNumberChannels)
            defer { outChannel += oc }
            guard oc > 0, let dst = obuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(obuf.mDataByteSize) / (MemoryLayout<Float>.size * oc))
            for ch in 0..<oc {
                let sc = (outChannel + ch) % fc
                var g = start
                for f in 0..<count {
                    g += step
                    dst[f * oc + ch] = softClip(src[f * fc + sc] * g)
                }
            }
        }
        state.current = target
    }

    /// Transparent below 0.8; above it, compresses smoothly toward ±1 so boosted audio doesn't crackle.
    private static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.8 else { return x }
        let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }
}
