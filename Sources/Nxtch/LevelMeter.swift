import AppKit
import QuartzCore
import SwiftUI

/// Four bars driven by the real audio: low, low-mid, high-mid, high. The bars are filled with a
/// left-to-right fade through `colors`.
///
/// Drawn with plain CALayers off a shared timer (`MeterClock`) rather than a SwiftUI TimelineView:
/// animating through SwiftUI re-lays-out the whole hosting view every frame (~10% CPU for one meter).
struct LevelMeter: NSViewRepresentable {
    let state: TapState?
    var colors: [NSColor]

    func makeNSView(context: Context) -> MeterView { MeterView() }

    func updateNSView(_ view: MeterView, context: Context) {
        if view.colors != colors { view.colors = colors }
        if view.state !== state { view.state = state }
    }
}

/// One timer for every meter on screen, instead of one each: with five apps in the media tab
/// that is 30 wakeups a second, not 150. 30 fps while any meter has sound, 4 fps in silence, and
/// stopped when no meter is visible.
@MainActor
final class MeterClock {
    static let shared = MeterClock()
    private let meters = NSHashTable<MeterView>.weakObjects()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var silentTicks = 0
    private static let active: TimeInterval = 1.0 / 30
    private static let idle: TimeInterval = 0.25

    func add(_ meter: MeterView) {
        meters.add(meter)
        if timer == nil { schedule(Self.active) }
    }

    func remove(_ meter: MeterView) {
        meters.remove(meter)
        if meters.allObjects.isEmpty { stop() }
    }

    private func stop() { timer?.invalidate(); timer = nil; interval = 0; silentTicks = 0 }

    private func schedule(_ i: TimeInterval) {
        timer?.invalidate()
        interval = i
        let t = Timer(timeInterval: i, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = i * 0.3
        RunLoop.main.add(t, forMode: .common)   // .common: keeps running while a slider is dragged
        timer = t
    }

    private func tick() {
        let live = meters.allObjects
        guard !live.isEmpty else { stop(); return }
        var loud = false
        for meter in live where meter.tick() { loud = true }
        silentTicks = loud ? 0 : silentTicks + 1
        if !loud, silentTicks > 30, interval == Self.active { schedule(Self.idle) }
        else if loud, interval == Self.idle { schedule(Self.active) }
    }
}

final class MeterView: NSView {
    var state: TapState? { didSet { updateClock() } }
    var colors: [NSColor] = [.white] { didSet { applyColors() } }

    /// The fade, shown only where the bars are: the bars live in its mask.
    private let gradient = CAGradientLayer()
    private let mask = CALayer()
    private var bars: [CALayer] = []
    private var levels: [Float] = [0, 0, 0, 0]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.mask = mask
        layer?.addSublayer(gradient)
        for _ in 0..<TapState.bandCount {
            let bar = CALayer()
            bar.backgroundColor = .white   // only its shape matters: it is a mask
            mask.addSublayer(bar)
            bars.append(bar)
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
    override func layout() { super.layout(); drawBars() }

    /// One or two colours fade left to right. Three or more go round the centre like a colour
    /// wheel, so each of them shows up in a meter this small.
    private func applyColors() {
        let c = colors.isEmpty ? [NSColor.white] : colors
        let wheel = c.count >= 3
        gradient.type = wheel ? .conic : .axial
        gradient.startPoint = wheel ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: 0, y: 0.5)
        gradient.endPoint = wheel ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 1, y: 0.5)
        gradient.colors = (wheel ? c + [c[0]] : c.count == 1 ? [c[0], c[0]] : c).map(\.cgColor)
    }

    /// On the shared clock only while on screen with something to show.
    private func updateClock() {
        if window != nil && state != nil {
            MeterClock.shared.add(self)
        } else {
            MeterClock.shared.remove(self)
            levels = [0, 0, 0, 0]
            drawBars()
        }
    }

    /// Called by the clock. Returns whether this meter has sound.
    func tick() -> Bool {
        guard let state else { return false }
        levels = state.displayLevels()
        drawBars()
        return (levels.max() ?? 0) >= 0.01
    }

    private func drawBars() {
        let n = CGFloat(bars.count)
        let gap = bounds.width * 0.12
        let w = (bounds.width - gap * (n - 1)) / n
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        mask.frame = bounds
        for (i, bar) in bars.enumerated() {
            let h = max(w, bounds.height * CGFloat(i < levels.count ? levels[i] : 0))
            bar.frame = CGRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }
}

// MARK: Meter colour

extension NSImage {
    private static let noColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// The most vivid colour in the image: the dominant hue among its saturated pixels, brightened
    /// enough to read on black. White for an image with no real colour (a grey or monochrome icon).
    var vividColor: NSColor {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Self.noColor }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        // Bucket pixels by hue, weighted by how colourful and opaque they are.
        let buckets = 12
        var weight = [CGFloat](repeating: 0, count: buckets)
        var sum = [(r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: buckets)
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = CGFloat(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = CGFloat(px[i]) / 255 / a, g = CGFloat(px[i + 1]) / 255 / a, b = CGFloat(px[i + 2]) / 255 / a
            let hi = max(r, g, b), lo = min(r, g, b), sat = hi == 0 ? 0 : (hi - lo) / hi
            guard sat > 0.25, hi > 0.2 else { continue }
            var hue: CGFloat = 0
            if hi == r { hue = (g - b) / (hi - lo) } else if hi == g { hue = 2 + (b - r) / (hi - lo) } else { hue = 4 + (r - g) / (hi - lo) }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
            let k = min(buckets - 1, Int(hue * CGFloat(buckets))), w = sat * hi * a
            weight[k] += w
            sum[k].r += r * w; sum[k].g += g * w; sum[k].b += b * w
        }
        // A colour often straddles two buckets (a fox that is orange and amber), so the winner is
        // the fullest bucket counted together with its two neighbours, and all three are averaged.
        let near = { (k: Int) in [(k + buckets - 1) % buckets, k, (k + 1) % buckets] }
        let total = { (k: Int) in near(k).reduce(0) { $0 + weight[$1] } }
        guard let k = weight.indices.max(by: { total($0) < total($1) }), total(k) > 2 else { return Self.noColor }
        let w = total(k), rgb = near(k).reduce((r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))) { ($0.r + sum[$1].r, $0.g + sum[$1].g, $0.b + sum[$1].b) }
        let c = NSColor(srgbRed: rgb.r / w, green: rgb.g / w, blue: rgb.b / w, alpha: 1)
        return NSColor(hue: c.hueComponent, saturation: max(c.saturationComponent, 0.55), brightness: max(c.brightnessComponent, 0.9), alpha: 1)
    }
}
