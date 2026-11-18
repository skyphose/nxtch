import AppKit
import SwiftUI

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
        detach()
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

    /// Each opening of the notch builds a new list and tracker, so the old one's observers go.
    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollView = nil
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

/// Put in a scroll view's content as a background: hands its macOS scroll view to the tracker.
struct ScrollViewFinder: NSViewRepresentable {
    let tracker: ScrollTracker
    func makeNSView(context: Context) -> NSView { Finder(tracker: tracker) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        let tracker: ScrollTracker
        init(tracker: ScrollTracker) { self.tracker = tracker; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never takes the rows' clicks
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { tracker.detach() }
        }
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
struct ThinScrollBar: View {
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
                .animation(.fade, value: active)
        }
    }
}
