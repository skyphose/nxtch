import SwiftUI
import QuartzCore

/// Notch silhouette: small outward curves at the top, rounded bottom corners (boring.notch style).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + topRadius, y: r.minY + topRadius),
                       control: CGPoint(x: r.minX + topRadius, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + topRadius, y: r.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: r.minX + topRadius + bottomRadius, y: r.maxY),
                       control: CGPoint(x: r.minX + topRadius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topRadius - bottomRadius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - topRadius, y: r.maxY - bottomRadius),
                       control: CGPoint(x: r.maxX - topRadius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topRadius, y: r.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - topRadius, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var model: MixerModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var clipboard: ClipboardStore
    @State private var dropTargeted = false

    private var topRadius: CGFloat { vm.isOpen ? 19 : 6 }
    private var bottomRadius: CGFloat { vm.isOpen ? 24 : 12 }
    private var earsVisible: Bool { settings.showEars && (model.anyPlaying || !shelf.isEmpty) }

    /// The left ear holds an icon per playing app, the right ear one meter. The ears can differ
    /// in width, so the closed shape is shifted to keep the hardware notch in its middle.
    private var leftEar: CGFloat { earsVisible ? NotchViewModel.leftEarWidth(icons: model.playingApps.count) : 0 }
    private var rightEar: CGFloat { earsVisible ? NotchViewModel.earWidth : 0 }

    var body: some View {
        let size = vm.isOpen
            ? vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil)
            : vm.closedSize(leftEar: leftEar, rightEar: rightEar)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if vm.isOpen {
                    OpenContent(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings,
                                shelf: shelf, clipboard: clipboard)
                        .padding(.horizontal, topRadius + 12)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    ClosedContent(vm: vm, model: model, shelf: shelf, showEars: earsVisible, leftEar: leftEar)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width + topRadius * 2, height: size.height, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .overlay {
                if dropTargeted {
                    NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .shadow(color: vm.isOpen ? .black.opacity(0.6) : .clear, radius: 8)
            .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
                vm.tab = .shelf
                return shelf.handleDrop(providers)
            }
            .offset(x: vm.isOpen ? 0 : (rightEar - leftEar) / 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: leftEar + rightEar)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.apps.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: nowPlaying.info != nil)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: vm.tab)
        .preferredColorScheme(.dark)
    }
}

// MARK: Closed: ears beside the hardware notch

private struct ClosedContent: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var model: MixerModel
    @ObservedObject var shelf: ShelfStore
    let showEars: Bool
    let leftEar: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if showEars {
                if let owner = model.primaryApp {
                    // Every playing app on the left, the meter's app first. One meter on the right.
                    HStack(spacing: NotchViewModel.earIconGap) {
                        ForEach(model.playingApps.prefix(NotchViewModel.maxEarIcons)) { app in
                            Image(nsImage: app.icon).resizable().interpolation(.high)
                                .frame(width: NotchViewModel.earIcon, height: NotchViewModel.earIcon)
                        }
                    }
                    .frame(width: leftEar)
                    Spacer(minLength: vm.geometry.notchSize.width)
                    LevelMeter(state: model.meter(owner.id), colors: model.playingColors)
                        .frame(width: 16, height: 14)
                        .frame(width: NotchViewModel.earWidth)
                } else if !shelf.isEmpty {
                    Image(systemName: "tray.full.fill").font(.system(size: 12))
                        .frame(width: NotchViewModel.earWidth)
                    Spacer(minLength: vm.geometry.notchSize.width)
                    Text("\(shelf.items.count)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: NotchViewModel.earWidth)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(height: vm.geometry.notchSize.height)
    }
}

// MARK: Open: tabs on the notch row, tab content below

private struct OpenContent: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var model: MixerModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var clipboard: ClipboardStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchTab.allCases, id: \.self) { tab in
                    Button { vm.tab = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 22)
                            .background(Capsule().fill(vm.tab == tab ? .white.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .foregroundStyle(vm.tab == tab ? .white : .white.opacity(0.5))
                    .help(tab.title)
                }
                Spacer(minLength: vm.geometry.notchSize.width + 16)
                actions
                Menu {
                    Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    Toggle("Activity Beside Notch", isOn: $settings.showEars)
                    Toggle("Full Screen", isOn: $settings.showInFullScreen)
                    Toggle("Clipboard History", isOn: $settings.clipboardEnabled)
                    Divider()
                    Button("Quit") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)
            }
            .frame(height: vm.geometry.notchSize.height)

            Group {
                switch vm.tab {
                case .media: MediaTab(model: model, nowPlaying: nowPlaying)
                case .shelf: ShelfTab(shelf: shelf)
                case .clipboard: ClipboardTab(store: clipboard, enabled: settings.clipboardEnabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var actions: some View {
        switch vm.tab {
        case .media:
            if model.hasCustomLevels {
                iconButton("arrow.counterclockwise", "Reset All to 100%") { model.resetAll() }
            }
        case .shelf:
            if !shelf.isEmpty {
                iconButton(shelf.allSelected ? "checkmark.circle.fill" : "checkmark.circle",
                           shelf.allSelected ? "Deselect All" : "Select All") { shelf.toggleSelectAll() }
                iconButton("square.and.arrow.up", "AirDrop") { shelf.airDrop(shelf.actionItems) }
                iconButton("doc.on.doc", "Copy") { shelf.copyToClipboard(shelf.actionItems) }
                iconButton("trash", "Clear") { shelf.clear() }
            }
        case .clipboard:
            if !clipboard.items.isEmpty {
                iconButton("trash", "Clear") { clipboard.clear() }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.white.opacity(0.6))
        .help(help)
    }
}

/// Four bars driven by the real audio: low, low-mid, high-mid, high. The bars are filled with a
/// left-to-right fade through `colors`.
///
/// Drawn with plain CALayers on its own timer rather than a SwiftUI TimelineView: animating
/// through SwiftUI re-lays-out the whole hosting view every frame (~10% CPU for one meter).
/// Runs at 30 fps while there's sound and drops to 4 fps during silence.
struct LevelMeter: NSViewRepresentable {
    let state: TapState?
    var colors: [NSColor]

    func makeNSView(context: Context) -> MeterView { MeterView() }

    func updateNSView(_ view: MeterView, context: Context) {
        if view.colors != colors { view.colors = colors }
        if view.state !== state { view.state = state }
    }
}

final class MeterView: NSView {
    var state: TapState? { didSet { updateTimer() } }
    var colors: [NSColor] = [.white] { didSet { applyColors() } }

    /// The fade, shown only where the bars are: the bars live in its mask.
    private let gradient = CAGradientLayer()
    private let mask = CALayer()
    private var bars: [CALayer] = []
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var silentTicks = 0
    private var levels: [Float] = [0, 0, 0, 0]
    private static let active: TimeInterval = 1.0 / 30
    private static let idle: TimeInterval = 0.25

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

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
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

    private func updateTimer() {
        if window != nil && state != nil {
            if timer == nil { schedule(Self.active) }
        } else {
            timer?.invalidate(); timer = nil; interval = 0
            levels = [0, 0, 0, 0]
            drawBars()
        }
    }

    private func schedule(_ i: TimeInterval) {
        timer?.invalidate()
        interval = i
        let t = Timer(timeInterval: i, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = i * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let state else { return }
        levels = state.displayLevels()
        drawBars()
        let silent = (levels.max() ?? 0) < 0.01
        silentTicks = silent ? silentTicks + 1 : 0
        if silent, silentTicks > 30, interval == Self.active { schedule(Self.idle) }
        else if !silent, interval == Self.idle { schedule(Self.active) }
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
