import AppKit
import SwiftUI

/// Clipboard tab: search field and history. Click copies; Return (or the context menu) pastes into
/// the app you were using.
struct ClipboardTab: View {
    @ObservedObject var store: ClipboardStore
    let enabled: Bool
    let shortcut: ClipboardShortcut
    /// Where the list sits inside its scroll view, for the scroll bar. Held, not observed: only the
    /// bar redraws as the list scrolls, not every row.
    @State private var scroll = ScrollTracker()

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("", text: $store.query, prompt: Text("Search").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        let items = store.visible
                        if store.selection < items.count { store.paste(items[store.selection]) }
                    }
                    .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
                if store.selecting {
                    Text("\(store.picked.count) selected").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                // The shortcut, faintly, so it's discoverable. The gear menu changes it.
                if shortcut != .off, store.query.isEmpty, !store.selecting {
                    Text(shortcut.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                }
                if !enabled { Text("Paused").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))

            let items = store.visible
            if items.isEmpty {
                Text(store.query.isEmpty ? "No history" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 1) {   // up to 100 rows, 6 visible
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                let lifted = store.hovered == item.id || (store.hovered == nil && index == store.selection)
                                ClipRow(item: item, store: store, selected: index == store.selection, lifted: lifted && !store.selecting,
                                        selecting: store.selecting, picked: store.picked.contains(item.id),
                                        justCopied: store.justCopied == item.id)
                                    .zIndex(lifted ? 1 : 0)   // the lifted row draws over its neighbors
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)   // room for a lifted row to grow into
                        .background(ScrollViewFinder(tracker: scroll))
                    }
                    .overlay(alignment: .topTrailing) { ClipScrollBar(tracker: scroll) }
                    .onHover { inside in if !inside { store.hovered = nil } }
                    .onChange(of: store.selection) { _, i in if i < items.count { proxy.scrollTo(items[i].id) } }
                }
            }
        }
        .padding(.top, 2)
    }
}

/// The list's scroll position, read from the macOS scroll view under SwiftUI's. SwiftUI's own
/// geometry doesn't make it out of that scroll view: measured, it always read zero.
@MainActor final class ScrollTracker: ObservableObject {
    @Published private(set) var viewport: CGFloat = 0
    @Published private(set) var content: CGFloat = 0
    @Published private(set) var offset: CGFloat = 0
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    func attach(_ sv: NSScrollView) {
        guard sv !== scrollView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        sv.documentView?.postsFrameChangedNotifications = true
        observers = [
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: sv.documentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
        ]
        update()
    }

    private func update() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let visible = sv.contentView.documentVisibleRect
        let height = doc.frame.height
        let top = doc.isFlipped ? visible.minY : height - visible.maxY
        if viewport != visible.height { viewport = visible.height }
        if content != height { content = height }
        if offset != top { offset = top }
    }

    /// Scrolls so the list's top is `fraction` of the way down, 0 to 1.
    func scroll(to fraction: CGFloat) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let overflow = max(0, content - viewport)
        let top = min(1, max(0, fraction)) * overflow
        let y = doc.isFlipped ? top : overflow - top
        sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.minX, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }
}

/// Sits inside the list and hands its macOS scroll view to the tracker.
private struct ScrollViewFinder: NSViewRepresentable {
    let tracker: ScrollTracker
    func makeNSView(context: Context) -> NSView { Finder(tracker: tracker) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        let tracker: ScrollTracker
        init(tracker: ScrollTracker) { self.tracker = tracker; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never takes the rows' clicks
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let sv = self.enclosingScrollView else { return }
                self.tracker.attach(sv)
            }
        }
    }
}

/// A thin bar on the right, shown only when the list is longer than the space it has. macOS's own
/// scroll bar only shows while scrolling; this one stays, and can be dragged.
private struct ClipScrollBar: View {
    @ObservedObject var tracker: ScrollTracker
    @State private var hovering = false
    @State private var dragStart: CGFloat?

    var body: some View {
        let viewport = tracker.viewport
        let overflow = tracker.content - viewport
        if overflow > 1, viewport > 0 {
            let thumb = max(18, viewport * viewport / tracker.content)
            let track = viewport - thumb
            let fraction = min(1, max(0, tracker.offset / overflow))
            let active = hovering || dragStart != nil
            Capsule()
                .fill(.white.opacity(active ? 0.5 : 0.25))
                .frame(width: active ? 5 : 3, height: thumb)
                .frame(width: 9, height: thumb)   // a wider target than it looks
                .contentShape(Rectangle())
                .onHover { hovering = $0 }   // the bar only, not the whole list
                .offset(y: fraction * track)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let start = dragStart ?? fraction * track
                        if dragStart == nil { dragStart = start }
                        if track > 0 { tracker.scroll(to: (start + v.translation.height) / track) }
                    }
                    .onEnded { _ in dragStart = nil })
                .animation(.easeOut(duration: 0.12), value: active)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    /// Not observed: a row is handed the few values it shows, so typing in the search field or
    /// moving the selection only rebuilds the rows that changed.
    let store: ClipboardStore
    let selected: Bool
    /// Under the cursor, or the keyboard's row when the cursor is elsewhere: it floats a little.
    let lifted: Bool
    let selecting: Bool
    let picked: Bool
    let justCopied: Bool

    /// App icons by bundle ID. Looking them up on every redraw is a disk hit per row.
    @MainActor private static var icons: [String: NSImage] = [:]

    /// A row lifts with a small bounce and pops when it's copied. With Reduce Motion on it only
    /// changes shade.
    private var scale: CGFloat {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 1 }
        return justCopied ? 1.02 : lifted ? 1.012 : 1
    }

    private var fill: Color {
        if picked { return Color.accentColor.opacity(0.28) }
        if justCopied { return .green.opacity(0.22) }
        if lifted { return .white.opacity(0.16) }
        return selected && !selecting ? .white.opacity(0.09) : .clear
    }

    var body: some View {
        // A button, so the row can dip while the mouse is down. In select mode a click picks the
        // row. ⌘-click starts select mode from anywhere.
        Button {
            if selecting || NSEvent.modifierFlags.contains(.command) { store.togglePick(item) } else { store.copy(item) }
        } label: { label }
        .buttonStyle(ClipRowStyle())
        .scaleEffect(scale)
        .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 5, y: 2)
        // Only entering counts. Leaving a row says nothing, or the lift would jump to the
        // keyboard's row for a moment each time the cursor crossed the gap between two rows.
        // The list clears it when the cursor leaves the list.
        .onHover { inside in if inside, store.hovered != item.id { store.hovered = item.id } }
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: lifted)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: justCopied)
        .animation(.easeOut(duration: 0.12), value: picked)
        .contextMenu {
            Button("Paste") { store.paste(item) }
            Button("Copy") { store.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Divider()
            Button(picked ? "Deselect" : "Select") { store.togglePick(item) }
            Button("Delete") { store.delete(item) }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if selecting {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(picked ? Color.accentColor : .white.opacity(0.35))
            }
            leading.frame(width: 18, height: 18)
            if item.kind == .image, let img = store.thumbnail(for: item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text(item.preview).font(.system(size: 12)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if justCopied {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
            } else {
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: NotchViewModel.clipRowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leading: some View {
        if let icon = Self.icon(item.sourceBundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: item.kind == .files ? "doc.on.doc" : item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private static func icon(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let cached = icons[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        icons[id] = icon
        return icon
    }
}

/// The row dips under the mouse and springs back on release.
private struct ClipRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
