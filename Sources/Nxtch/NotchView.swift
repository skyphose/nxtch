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

    private var topRadius: CGFloat { vm.isOpen ? NotchViewModel.openTopRadius : 6 }
    private var bottomRadius: CGFloat { vm.isOpen ? 24 : 12 }
    private var earsVisible: Bool { settings.showEars && (model.anyPlaying || !shelf.isEmpty) }

    /// The ears can differ in width, so the closed shape is shifted to keep the hardware notch
    /// in its middle.
    private var leftEar: CGFloat { vm.ears(settings: settings, model: model, shelf: shelf).left }
    private var rightEar: CGFloat { vm.ears(settings: settings, model: model, shelf: shelf).right }

    var body: some View {
        let size = vm.isOpen
            ? vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil, shelfItems: shelf.items.count)
            : vm.closedSize(leftEar: leftEar, rightEar: rightEar)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if vm.isOpen {
                    OpenContent(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings,
                                shelf: shelf, clipboard: clipboard)
                        .padding(.horizontal, NotchViewModel.contentInset)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    ClosedContent(vm: vm, model: model, shelf: shelf, showEars: earsVisible, showMeter: settings.showMeters, leftEar: leftEar)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width + topRadius * 2, height: size.height, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .overlay {
                if vm.isDropTargeted {
                    NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .shadow(color: vm.isOpen ? .black.opacity(0.6) : .clear, radius: 8)
            .onDrop(of: [.item], isTargeted: $vm.isDropTargeted) { providers in
                vm.tab = .shelf
                return shelf.handleDrop(providers)
            }
            .offset(x: vm.isOpen ? 0 : (rightEar - leftEar) / 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.notch, value: leftEar + rightEar)
        .animation(.notch, value: model.apps.count)
        .animation(.notch, value: shelf.items.count)
        .animation(.notch, value: nowPlaying.info != nil)
        .animation(.notch, value: vm.tab)
        .preferredColorScheme(.dark)
    }
}

// MARK: Closed: ears beside the hardware notch

private struct ClosedContent: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var model: MixerModel
    @ObservedObject var shelf: ShelfStore
    let showEars: Bool
    let showMeter: Bool
    let leftEar: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if showEars {
                if let owner = model.primaryApp {
                    // Every playing app on the left, the meter's app first. One meter on the right.
                    HStack(spacing: NotchViewModel.earIconGap) {
                        ForEach(model.playingApps.prefix(NotchViewModel.maxEarIcons)) { app in
                            Image(nsImage: app.icon).resizable().interpolation(.high)
                                .frame(width: vm.earIcon, height: vm.earIcon)
                        }
                    }
                    .frame(width: leftEar)
                    Spacer(minLength: vm.geometry.notchSize.width)
                    if showMeter {
                        LevelMeter(state: model.meter(owner.id), colors: model.playingColors)
                            .frame(width: (vm.earIcon * 0.89).rounded(), height: (vm.earIcon * 0.78).rounded())
                            .frame(width: vm.earWidth)
                    }
                } else if !shelf.isEmpty {
                    Image(systemName: "tray.full.fill").font(.system(size: (vm.earIcon * 0.67).rounded()))
                        .frame(width: vm.earWidth)
                    Spacer(minLength: vm.geometry.notchSize.width)
                    Text("\(shelf.items.count)").font(.system(size: (vm.earIcon * 0.67).rounded(), weight: .semibold).monospacedDigit())
                        .frame(width: vm.earWidth)
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
                    Toggle("Level Meters", isOn: $settings.showMeters)
                    Toggle("Full Screen", isOn: $settings.showInFullScreen)
                    Toggle("Clipboard History", isOn: $settings.clipboardEnabled)
                    Picker("Clipboard Shortcut", selection: $settings.clipboardShortcut) {
                        ForEach(ClipboardShortcut.allCases) { Text($0.title).tag($0) }
                    }
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
                case .media: MediaTab(model: model, nowPlaying: nowPlaying, meters: settings.showMeters)
                case .shelf: ShelfTab(shelf: shelf)
                case .clipboard: ClipboardTab(store: clipboard, enabled: settings.clipboardEnabled, shortcut: settings.clipboardShortcut)
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
                iconButton("trash", shelf.selection.isEmpty ? "Clear All" : "Delete Selected") { shelf.clear() }
            }
        case .clipboard:
            if !clipboard.items.isEmpty {
                iconButton(clipboard.selecting ? "checkmark.circle.fill" : "checkmark.circle",
                           clipboard.selecting ? "Done" : "Select") { clipboard.selecting.toggle() }
                if clipboard.selecting {
                    // Nothing picked yet: the button waits, it never falls back to clearing everything.
                    iconButton("trash", "Delete Selected") { clipboard.deletePicked() }
                        .disabled(clipboard.picked.isEmpty)
                        .opacity(clipboard.picked.isEmpty ? 0.35 : 1)
                } else {
                    iconButton("trash", "Clear All") { clipboard.clear() }
                }
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
