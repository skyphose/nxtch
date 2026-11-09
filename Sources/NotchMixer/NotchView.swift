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

    private var topRadius: CGFloat { vm.isOpen ? 19 : 6 }
    private var bottomRadius: CGFloat { vm.isOpen ? 24 : 12 }

    var body: some View {
        let size = vm.isOpen
            ? vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil)
            : vm.closedSize(playing: model.anyPlaying && settings.showEars)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if vm.isOpen {
                    OpenContent(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings)
                        .padding(.horizontal, topRadius + 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                } else {
                    ClosedContent(vm: vm, model: model, nowPlaying: nowPlaying, showEars: settings.showEars)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width + topRadius * 2, height: size.height, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .shadow(color: vm.isOpen ? .black.opacity(0.6) : .clear, radius: 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.anyPlaying && settings.showEars)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.apps.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: nowPlaying.info != nil)
        .preferredColorScheme(.dark)
    }
}

// MARK: Closed: ears beside the hardware notch while audio plays

private struct ClosedContent: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var model: MixerModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    let showEars: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showEars, let app = model.apps.first(where: \.isPlaying) {
                // Prefer the app that owns the now-playing media; show its artwork.
                let media = nowPlaying.info.flatMap { info in model.apps.contains { $0.isPlaying && info.belongs(to: $0.id) } ? info : nil }
                let owner = media.flatMap { m in model.apps.first { m.belongs(to: $0.id) } } ?? app
                Group {
                    if let art = media?.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(nsImage: owner.icon).resizable().interpolation(.high)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: NotchViewModel.earWidth)
                Spacer(minLength: vm.geometry.notchSize.width)
                LevelMeter(state: model.meter(owner.id), color: .white.opacity(0.9))
                    .frame(width: 16, height: 14)
                    .frame(width: NotchViewModel.earWidth)
            }
        }
        .frame(height: vm.geometry.notchSize.height)
    }
}

// MARK: Open: now playing + per-app mixer

private struct OpenContent: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var model: MixerModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.geometry.notchSize.height) // hidden behind the camera housing
            if let info = nowPlaying.info {
                NowPlayingCard(monitor: nowPlaying, info: info,
                               app: model.apps.first { info.belongs(to: $0.id) },
                               meter: model.apps.first { info.belongs(to: $0.id) }.flatMap { model.meter($0.id) })
                    .frame(height: NotchViewModel.nowPlayingHeight)
                    .transition(.opacity)
            }
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill").font(.system(size: 11))
                Text(model.outputName.isEmpty ? "Output" : model.outputName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let err = model.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).help(err)
                }
                Menu {
                    Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    Toggle("Show Activity Beside Notch", isOn: $settings.showEars)
                    Toggle("Show in Full Screen", isOn: $settings.showInFullScreen)
                    Divider()
                    Button("Quit NotchMixer") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(height: 36)

            if model.apps.isEmpty {
                Text("No apps are playing audio")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(height: NotchViewModel.rowHeight)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(model.apps) { app in
                            AppRow(app: app, model: model,
                                   media: nowPlaying.info.flatMap { $0.belongs(to: app.id) ? $0 : nil })
                        }
                    }
                }
            }
        }
    }
}

private struct NowPlayingCard: View {
    @ObservedObject var monitor: NowPlayingMonitor
    let info: NowPlayingInfo
    let app: AppEntry?
    let meter: TapState?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let art = info.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let app {
                    Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                        .offset(x: 6, y: 6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openSourceApp() }
            .help("Open \(app?.name ?? "app")")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    LevelMeter(state: info.isPlaying ? meter : nil, color: .white.opacity(0.9))
                        .frame(width: 12, height: 10)
                }
                if monitor.controlsNeedPermission {
                    Text("Allow NotchMixer in Privacy & Security › Accessibility to use controls")
                        .font(.system(size: 10)).foregroundStyle(.yellow).lineLimit(2)
                } else if let subtitle = [info.artist, info.album].compactMap({ $0 }).filter({ !$0.isEmpty }).first {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if info.duration != nil {
                    ProgressLine(info: info).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                control("backward.fill", .previous, size: 13)
                control(info.isPlaying ? "pause.fill" : "play.fill", .playPause, size: 19)
                control("forward.fill", .next, size: 13)
            }
        }
        .foregroundStyle(.white)
    }

    private func control(_ symbol: String, _ key: MediaKey, size: CGFloat) -> some View {
        Button { monitor.controlsNeedPermission = !key.send() } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func openSourceApp() {
        guard let id = info.parentBundleID ?? info.bundleID ?? app?.id,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct ProgressLine: View {
    let info: NowPlayingInfo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = info.position(at: ctx.date) ?? 0
            let dur = info.duration ?? 1
            HStack(spacing: 6) {
                Text(fmt(pos)).frame(width: 34, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: g.size.width * CGFloat(max(0, min(1, pos / dur))))
                    }
                }
                .frame(height: 3)
                Text(fmt(dur)).frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct AppRow: View {
    let app: AppEntry
    @ObservedObject var model: MixerModel
    let media: NowPlayingInfo?

    var body: some View {
        let muted = model.isMuted(app.id)
        let volume = model.volume(app.id)
        HStack(spacing: 10) {
            Image(nsImage: app.icon).resizable().interpolation(.high)
                .frame(width: 26, height: 26)
                .opacity(muted ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1).layoutPriority(1)
                    if let media {
                        Text([media.title, media.artist].compactMap { $0 }.joined(separator: " — "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if app.isPlaying {
                        LevelMeter(state: muted ? nil : model.meter(app.id), color: .green)
                            .frame(width: 12, height: 9)
                    }
                }
                Slider(value: Binding(get: { Double(muted ? 0 : volume) },
                                      set: { model.setVolume(app.id, Float($0)) }),
                       in: 0...Double(MixerModel.maxVolume))
                    .controlSize(.mini)
                    .tint(volume > 1.001 && !muted ? .orange : .white)
                    .background(alignment: .leading) {
                        // Tick at 100%.
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.35))
                                .frame(width: 1.5, height: 8)
                                .offset(x: (g.size.width - 12) / CGFloat(MixerModel.maxVolume) + 5.25, y: g.size.height / 2 - 4)
                        }
                    }
            }
            Text("\(Int(((muted ? 0 : volume) * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(volume > 1.001 && !muted ? .orange : .secondary)
                .frame(width: 40, alignment: .trailing)
            Button { model.toggleMute(app.id) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : speakerIcon(volume))
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted ? .red : .white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .frame(height: NotchViewModel.rowHeight)
    }

    private func speakerIcon(_ v: Float) -> String {
        v < 0.01 ? "speaker.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill"
            : v <= 1.001 ? "speaker.wave.3.fill" : "speaker.plus.fill"
    }
}

/// Four bars driven by the real audio: low, low-mid, high-mid, high.
struct LevelMeter: View {
    let state: TapState?
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: state == nil)) { _ in
            let levels = state?.displayLevels(now: CACurrentMediaTime()) ?? [0, 0, 0, 0]
            GeometryReader { geo in
                HStack(alignment: .center, spacing: geo.size.width * 0.12) {
                    ForEach(0..<levels.count, id: \.self) { i in
                        Capsule().fill(color)
                            .frame(height: max(geo.size.width * 0.18, geo.size.height * CGFloat(levels[i])))
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
