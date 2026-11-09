import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that sits over the notch (same setup boring.notch uses).
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Geometry of the physical notch on the screen we live on.
struct NotchGeometry: Equatable {
    var notchSize: CGSize
    var screenFrame: CGRect

    static func current() -> (NSScreen, NotchGeometry)? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return nil }
        var size = CGSize(width: 200, height: 32) // fallback "fake notch" for non-notch displays
        if screen.safeAreaInsets.top > 0 { size.height = screen.safeAreaInsets.top }
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            size.width = screen.frame.width - l.width - r.width
        }
        return (screen, NotchGeometry(notchSize: size, screenFrame: screen.frame))
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var geometry: NotchGeometry

    static let openWidth: CGFloat = 480
    static let rowHeight: CGFloat = 46
    static let earWidth: CGFloat = 34
    static let maxRows = 6

    init(geometry: NotchGeometry) { self.geometry = geometry }

    func closedSize(playing: Bool) -> CGSize {
        CGSize(width: geometry.notchSize.width + (playing ? Self.earWidth * 2 : 0), height: geometry.notchSize.height)
    }

    static let nowPlayingHeight: CGFloat = 76

    func openSize(rows: Int, nowPlaying: Bool) -> CGSize {
        let r = max(1, min(rows, Self.maxRows))
        return CGSize(width: Self.openWidth,
                      height: geometry.notchSize.height + (nowPlaying ? Self.nowPlayingHeight : 0) + 36 + CGFloat(r) * Self.rowHeight + 14)
    }
}

/// Owns the panel, tracks the mouse and opens/closes the notch.
///
/// Rules that keep it from blocking anything:
/// - Closed: the panel ignores all mouse events (clicks always reach the menu bar).
/// - Opening: only by resting on the hardware notch itself (where no UI can be) for a moment,
///   and never while a mouse button is held (e.g. dragging a window to the top).
/// - Open: mouse events are accepted only inside the visible black shape; the transparent
///   rest of the window passes clicks through.
/// - Hidden on full-screen Spaces unless enabled in settings.
@MainActor
final class NotchController {
    private let panel: NotchPanel
    private let model: MixerModel
    private let nowPlaying: NowPlayingMonitor
    private let settings: AppSettings
    private let vm: NotchViewModel
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var menuTracking = false
    private var bag = Set<AnyCancellable>()
    private static let panelSize = CGSize(width: 640, height: 500)
    private static let openDwell: TimeInterval = 0.15
    private static let closeDelay: TimeInterval = 0.3

    init(model: MixerModel, nowPlaying: NowPlayingMonitor, settings: AppSettings) {
        self.model = model
        self.nowPlaying = nowPlaying
        self.settings = settings
        let geo = NotchGeometry.current()?.1 ?? NotchGeometry(notchSize: CGSize(width: 200, height: 32), screenFrame: .zero)
        vm = NotchViewModel(geometry: geo)
        panel = NotchPanel(contentRect: .zero)
        let host = NSHostingView(rootView: NotchView(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings))
        host.sizingOptions = []
        panel.contentView = host
        position()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true

        settings.$showInFullScreen
            .sink { [weak self] show in self?.applySpaceBehavior(showInFullScreen: show) }
            .store(in: &bag)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        // Keep the panel open while one of its menus (settings) is showing.
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true; self?.closeWork?.cancel(); self?.closeWork = nil }
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = false; self?.trackMouse() }
        }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.trackMouse() }
            return e
        }) { monitors.append(l) }
    }

    private func applySpaceBehavior(showInFullScreen: Bool) {
        var b: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if showInFullScreen { b.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = b
        panel.orderFrontRegardless()
    }

    private func position() {
        guard let (screen, geo) = NotchGeometry.current() else { return }
        vm.geometry = geo
        let f = screen.frame
        let s = Self.panelSize
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height), display: true)
    }

    /// The hardware notch (plus a hair of slack). Nothing else can live here, so hovering it is never accidental.
    private var notchTriggerRect: NSRect {
        let f = vm.geometry.screenFrame, n = vm.geometry.notchSize
        return NSRect(x: f.midX - n.width / 2 - 4, y: f.maxY - n.height, width: n.width + 8, height: n.height)
    }

    /// The visible black shape while open, in screen coordinates.
    private var openShapeRect: NSRect {
        let f = vm.geometry.screenFrame
        let s = vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil)
        let w = s.width + 38 // + top flares
        return NSRect(x: f.midX - w / 2, y: f.maxY - s.height, width: w, height: s.height)
    }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons != 0

        if vm.isOpen {
            let overShape = openShapeRect.contains(p)
            // Only the visible shape takes clicks; the rest of the window is click-through.
            panel.ignoresMouseEvents = !overShape
            // A little slack before closing so small overshoots don't snap it shut.
            if overShape || openShapeRect.insetBy(dx: -10, dy: -10).contains(p) || menuTracking {
                closeWork?.cancel(); closeWork = nil
            } else if closeWork == nil, !buttonDown {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.closeWork = nil; self?.setOpen(false) }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
            }
            return
        }

        panel.ignoresMouseEvents = true
        if notchTriggerRect.contains(p), !buttonDown {
            guard openWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.openWork = nil
                    // Still resting on the notch and not dragging? Then open.
                    if self.notchTriggerRect.contains(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 {
                        self.setOpen(true)
                    }
                }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDwell, execute: work)
        } else {
            openWork?.cancel(); openWork = nil
        }
    }

    private func setOpen(_ open: Bool) {
        if open { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        withAnimation(open ? .spring(response: 0.42, dampingFraction: 0.8) : .spring(response: 0.45, dampingFraction: 1.0)) {
            vm.isOpen = open
        }
        panel.ignoresMouseEvents = !(open && openShapeRect.contains(NSEvent.mouseLocation))
    }
}
