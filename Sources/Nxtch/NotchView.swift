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

    var body: some View {
        let size = vm.isOpen
            ? vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil)
            : vm.closedSize(ears: earsVisible)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if vm.isOpen {
                    OpenContent(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings,
                                shelf: shelf, clipboard: clipboard)
                        .padding(.horizontal, topRadius + 12)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    ClosedContent(vm: vm, model: model, nowPlaying: nowPlaying, shelf: shelf, showEars: earsVisible)
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: earsVisible)
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
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var shelf: ShelfStore
    let showEars: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showEars {
                if let owner = model.primaryApp {
                    Image(nsImage: owner.icon).resizable().interpolation(.high)
                        .frame(width: 18, height: 18)
                        .frame(width: NotchViewModel.earWidth)
                    Spacer(minLength: vm.geometry.notchSize.width)
                    LevelMeter(state: model.meter(owner.id), color: .white.opacity(0.9))
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
                    Toggle("Show Activity Beside Notch", isOn: $settings.showEars)
                    Toggle("Show in Full Screen", isOn: $settings.showInFullScreen)
                    Toggle("Record Clipboard History", isOn: $settings.clipboardEnabled)
                    Divider()
                    Button("Quit nxtch") { NSApp.terminate(nil) }
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
        case .media: EmptyView()
        case .shelf:
            if !shelf.isEmpty {
                iconButton("square.and.arrow.up", "AirDrop all") { shelf.airDrop() }
                iconButton("doc.on.doc", "Copy all (paste in Finder)") { shelf.copyToClipboard() }
                iconButton("trash", "Delete all from shelf") { shelf.clear() }
            }
        case .clipboard:
            if !clipboard.items.isEmpty {
                iconButton("trash", "Clear history (keeps pinned)") { clipboard.clear() }
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

/// Four bars driven by the real audio: low, low-mid, high-mid, high.
///
/// Drawn with plain CALayers on its own timer rather than a SwiftUI TimelineView: animating
/// through SwiftUI re-lays-out the whole hosting view every frame (~10% CPU for one meter).
/// Runs at 30 fps while there's sound and drops to 4 fps during silence.
struct LevelMeter: NSViewRepresentable {
    let state: TapState?
    var color: Color

    func makeNSView(context: Context) -> MeterView { MeterView() }

    func updateNSView(_ view: MeterView, context: Context) {
        view.color = NSColor(color)
        if view.state !== state { view.state = state }
    }
}

final class MeterView: NSView {
    var state: TapState? { didSet { updateTimer() } }
    var color: NSColor = .white { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }

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
        for _ in 0..<TapState.bandCount {
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    override func layout() { super.layout(); drawBars() }

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
        for (i, bar) in bars.enumerated() {
            let h = max(w, bounds.height * CGFloat(i < levels.count ? levels[i] : 0))
            bar.frame = CGRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }
}
