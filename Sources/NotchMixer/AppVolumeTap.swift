import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

/// Per-app state shared between the main thread and the real-time audio thread.
/// Main thread writes `target` gain and reads levels; audio thread reads gain and writes levels.
final class TapState: @unchecked Sendable {
    static let bandCount = 4
    /// Low-pass corners splitting the signal into 4 bands: <150, 150–600, 600–2.5k, >2.5k Hz.
    private static let corners: [Double] = [150, 600, 2500]
    /// Higher bands carry less energy; boost them so the bars look balanced.
    private static let bandBoost: [Float] = [1.0, 1.4, 2.2, 3.5]

    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let levelPtr = UnsafeMutablePointer<Float>.allocate(capacity: bandCount)

    // Audio-thread-only state.
    var current: Float
    var lp: (Float, Float, Float) = (0, 0, 0)
    var coeff: (Float, Float, Float) = (0.02, 0.08, 0.3)

    // Main-thread-only display state.
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

    /// Audio thread: publish raw RMS per band.
    @inline(__always) func store(_ b0: Float, _ b1: Float, _ b2: Float, _ b3: Float) {
        levelPtr[0] = b0; levelPtr[1] = b1; levelPtr[2] = b2; levelPtr[3] = b3
    }

    func reset() { for i in 0..<Self.bandCount { levelPtr[i] = 0 } }

    /// Main thread: smoothed 0…1 bar heights (fast attack, slow release). Safe to call from many views per frame.
    func displayLevels(now: CFTimeInterval = CACurrentMediaTime()) -> [Float] {
        let dt = Float(min(max(now - lastDisplayUpdate, 0), 0.1))
        guard dt > 1.0 / 240 else { return display }
        lastDisplayUpdate = now
        for i in 0..<Self.bandCount {
            let rms = levelPtr[i] * Self.bandBoost[i]
            let db = 20 * log10(max(rms, 1e-6))
            let target = max(0, min(1, (db + 54) / 48)) // -54 dBFS → 0, -6 dBFS → 1
            let rate: Float = target > display[i] ? 30 : 7  // attack / release per second
            display[i] += (target - display[i]) * min(1, rate * dt)
        }
        return display
    }
}

/// Taps every process of one app.
/// - `passthrough == true`: listen-only (app audio untouched), used just for metering.
/// - `passthrough == false`: original output is muted and re-played at `state.target` gain.
final class AppVolumeTap {
    let processObjects: Set<AudioObjectID>
    let outputUID: String
    let passthrough: Bool
    private let state: TapState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "notchmixer.tap", qos: .userInteractive)

    init(processObjects: Set<AudioObjectID>, outputUID: String, passthrough: Bool, state: TapState) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.passthrough = passthrough
        self.state = state
        do { try start() } catch { stop(); throw error }
    }

    deinit { stop(); state.reset() }

    private func start() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: Array(processObjects))
        desc.uuid = UUID()
        desc.name = "NotchMixer tap"
        desc.isPrivate = true
        desc.muteBehavior = passthrough ? .unmuted : .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Creating process tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchMixer",
            kAudioAggregateDeviceUIDKey: "dev.notchmixer.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating aggregate device")

        state.configure(sampleRate: CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(48000)) ?? 48000)
        let state = self.state
        let passthrough = self.passthrough
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

    /// Real-time callback. No allocations, no locks.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: TapState, passthrough: Bool) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buf in outList where buf.mData != nil { memset(buf.mData, 0, Int(buf.mDataByteSize)) }

        var inChannels = 0
        for buf in inList { inChannels += Int(buf.mNumberChannels) }
        guard inChannels > 0, let first = inList.first, first.mNumberChannels > 0,
              let firstData = first.mData?.assumingMemoryBound(to: Float.self) else { state.store(0, 0, 0, 0); return }
        let fc = Int(first.mNumberChannels)
        let inFrames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * fc)
        guard inFrames > 0 else { return }

        let start = passthrough ? 1 : state.current
        let target = passthrough ? 1 : state.target
        let step = (target - start) / Float(inFrames)

        // --- Metering: mono mix of the first buffer, post-gain, split into 4 bands.
        var (l0, l1, l2) = state.lp
        let (c0, c1, c2) = state.coeff
        var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
        var g = start
        for f in 0..<inFrames {
            g += step
            var x: Float = 0
            for ch in 0..<fc { x += firstData[f * fc + ch] }
            x = x / Float(fc) * g
            l0 += c0 * (x - l0); l1 += c1 * (x - l1); l2 += c2 * (x - l2)
            let b0 = l0, b1 = l1 - l0, b2 = l2 - l1, b3 = x - l2
            s0 += b0 * b0; s1 += b1 * b1; s2 += b2 * b2; s3 += b3 * b3
        }
        state.lp = (l0, l1, l2)
        let n = Float(inFrames)
        state.store(sqrt(s0 / n), sqrt(s1 / n), sqrt(s2 / n), sqrt(s3 / n))

        guard !passthrough else { return }

        // --- Volume: copy tap input → device output with a smoothed gain.
        var outChannelBase = 0
        for obuf in outList {
            let oc = Int(obuf.mNumberChannels)
            defer { outChannelBase += oc }
            guard oc > 0, let odata = obuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(inFrames, Int(obuf.mDataByteSize) / (MemoryLayout<Float>.size * oc))
            guard frames > 0 else { continue }

            for ch in 0..<oc {
                var src = (outChannelBase + ch) % inChannels
                var sdata: UnsafeMutablePointer<Float>?
                var sc = 1
                for ibuf in inList {
                    let n = Int(ibuf.mNumberChannels)
                    if src < n { sdata = ibuf.mData?.assumingMemoryBound(to: Float.self); sc = n; break }
                    src -= n
                }
                guard let sdata else { continue }
                var g = start
                for f in 0..<frames {
                    g += step
                    odata[f * oc + ch] = softClip(sdata[f * sc + src] * g)
                }
            }
        }
        state.current = target
    }

    /// Transparent below 0.8; above it, smoothly compresses toward ±1 so boosted audio doesn't crackle.
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.8 else { return x }
        let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }
}
