import SwiftUI

/// Media tab: now playing card, then the per-app mixer.
struct MediaTab: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var nowPlaying: NowPlayingMonitor

    var body: some View {
        VStack(spacing: 0) {
            if let info = nowPlaying.info {
                let owner = model.apps.first { info.belongs(to: $0.id) }
                NowPlayingCard(monitor: nowPlaying, info: info, app: owner, meter: owner.flatMap { model.meter($0.id) })
                    .frame(height: NotchViewModel.nowPlayingHeight)
                    .transition(.opacity)
            }
            HStack(spacing: 5) {
                Image(systemName: "hifispeaker.fill")
                Text(model.outputName.isEmpty ? "Output" : model.outputName).lineLimit(1)
                Spacer()
                if let err = model.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(err)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(height: NotchViewModel.sectionLabelHeight)

            if model.apps.isEmpty {
                Text("Nothing playing")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
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
            Group {
                if let app {
                    Image(nsImage: app.icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
            .onTapGesture { openSourceApp() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    LevelMeter(state: info.isPlaying ? meter : nil, colors: app?.meterColors ?? [.white])
                        .frame(width: 12, height: 10)
                }
                if let subtitle = [info.artist, info.album].compactMap({ $0 }).filter({ !$0.isEmpty }).first {
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
        Button { monitor.send(key) } label: {
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

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.control, value: configuration.isPressed)
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

    /// The slider sticks to 100% as it passes. Holding ⇧ turns that off, so any value can be set.
    private func adjust(to value: Double) {
        model.setVolume(app.id, Float(value), snap: !NSEvent.modifierFlags.contains(.shift))
    }

    var body: some View {
        let muted = model.isMuted(app.id)
        let volume = model.volume(app.id)
        let boosted = volume > 1.001 && !muted
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
                        LevelMeter(state: muted ? nil : model.meter(app.id), colors: app.meterColors)
                            .frame(width: 12, height: 9)
                    }
                }
                Slider(value: Binding(get: { Double(muted ? 0 : volume) }, set: { adjust(to: $0) }),
                       in: 0...Double(MixerModel.maxVolume))
                    .controlSize(.mini)
                    .tint(boosted ? .orange : .white)
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
                .foregroundStyle(boosted ? .orange : .secondary)
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

