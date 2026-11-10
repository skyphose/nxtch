import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Borderless, non-activating panel that sits over the notch (same setup boring.notch uses).
/// It only becomes key when a text field needs it (clipboard search) and never activates the app,
/// so the app you're using stays frontmost.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Geometry of the physical notch on the screen we live on.
struct NotchGeometry: Equatable {
    var notchSize: CGSize
    var screenFrame: CGRect

    static func current() -> (NSScreen, NotchGeometry)? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return nil }
        var size = CGSize(width: 200, height: 32) // fallback "fake notch" for non-notch displays
        if screen.safeAreaInsets.top > 0 { size.height = screen.safeAreaInsets.top }
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            size.width = screen.frame.width - l.width - r.width
        }
        return (screen, NotchGeometry(notchSize: size, screenFrame: screen.frame))
    }
}

enum NotchTab: String, CaseIterable {
    case media, shelf, clipboard

    var symbol: String {
        switch self {
        case .media: return "waveform"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        }
    }

    var title: String { rawValue.capitalized }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var geometry: NotchGeometry
    @Published var tab: NotchTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }

    static let openWidth: CGFloat = 560
    static let earWidth: CGFloat = 34
    static let rowHeight: CGFloat = 46
    static let maxMixerRows = 4
    static let nowPlayingHeight: CGFloat = 76
    static let sectionLabelHeight: CGFloat = 22
    static let shelfHeight: CGFloat = 116
    static let clipRowHeight: CGFloat = 32
    static let clipVisibleRows = 6

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        tab = NotchTab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .media
    }

    static let earIcon: CGFloat = 18
    static let earIconGap: CGFloat = 3
    static let maxEarIcons = 4

    /// The left ear grows with the number of playing apps (up to `maxEarIcons`).
    static func leftEarWidth(icons: Int) -> CGFloat {
        earWidth + CGFloat(max(0, min(icons, maxEarIcons) - 1)) * (earIcon + earIconGap)
    }

    func closedSize(leftEar: CGFloat, rightEar: CGFloat) -> CGSize {
        CGSize(width: geometry.notchSize.width + leftEar + rightEar, height: geometry.notchSize.height)
    }

    func openSize(rows: Int, nowPlaying: Bool) -> CGSize {
        let body: CGFloat
        switch tab {
        case .media:
            body = (nowPlaying ? Self.nowPlayingHeight : 0) + Self.sectionLabelHeight
                + CGFloat(max(1, min(rows, Self.maxMixerRows))) * Self.rowHeight
        case .shelf:
            body = Self.shelfHeight
        case .clipboard:
            body = 30 + CGFloat(Self.clipVisibleRows) * (Self.clipRowHeight + 1)
        }
        return CGSize(width: Self.openWidth, height: geometry.notchSize.height + body + 10)
    }
}

/// Owns the panel, tracks the mouse and opens/closes the notch.
///
/// Rules that keep it from blocking anything:
/// - Closed: the panel ignores all mouse events (clicks always reach the menu bar).
/// - Opening by hover: only by resting on the hardware notch itself (where no UI can be) for a
///   moment, and never while a mouse button is held.
/// - Opening by drag: dragging content (files, text, images) over the notch opens the shelf.
/// - Open: mouse events are accepted only inside the visible black shape; the transparent rest of
///   the window passes clicks through.
/// - Keyboard: the panel only takes key focus when you click its search field or press ⌃⌥V, and
///   gives it back when it closes.
/// - Hidden on full-screen Spaces unless enabled in settings.
@MainActor
final class NotchController {
    private let panel: NotchPanel
    private let model: MixerModel
    private let nowPlaying: NowPlayingMonitor
    private let settings: AppSettings
    private let shelf: ShelfStore
    private let clipboard: ClipboardStore
    private let vm: NotchViewModel
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var menuTracking = false
    /// Opened with the keyboard shortcut: stays open until Esc, a click outside, or the shortcut again.
    private var pinnedOpen = false
    private var pollTimer: Timer?
    private var hotkey: Hotkey?
    private var bag = Set<AnyCancellable>()

    // Drag detection: a drag is in progress when a mouse button is down and the drag pasteboard
    // has changed since the button went down.
    private var buttonWasDown = false
    private var dragBaseline = 0
    private var contentDragActive = false

    private static let panelSize = CGSize(width: 680, height: 520)
    private static let openDwell: TimeInterval = 0.15
    private static let closeDelay: TimeInterval = 0.3

    init(model: MixerModel, nowPlaying: NowPlayingMonitor, settings: AppSettings,
         shelf: ShelfStore, clipboard: ClipboardStore) {
        self.model = model
        self.nowPlaying = nowPlaying
        self.settings = settings
        self.shelf = shelf
        self.clipboard = clipboard
        let geo = NotchGeometry.current()?.1 ?? NotchGeometry(notchSize: CGSize(width: 200, height: 32), screenFrame: .zero)
        vm = NotchViewModel(geometry: geo)
        panel = NotchPanel(contentRect: .zero)
        let host = NSHostingView(rootView: NotchView(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings,
                                                     shelf: shelf, clipboard: clipboard))
        host.sizingOptions = []
        panel.contentView = host
        position()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true

        settings.$showInFullScreen
            .sink { [weak self] show in self?.applySpaceBehavior(showInFullScreen: show) }
            .store(in: &bag)
        // Meter taps follow what's on screen. (@Published fires before the value changes, hence .receive.)
        settings.$showEars.combineLatest(vm.$tab).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateMeterScope() } }
            .store(in: &bag)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        // Keep the panel open while one of its menus (settings, context menus) is showing.
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true; self?.closeWork?.cancel(); self?.closeWork = nil }
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = false; self?.trackMouse() }
        }
        nc.addObserver(forName: .nxtchRequestClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOpen(false) }
        }

        // A click in another app closes nxtch. That's all nxtch watches system-wide: hover and
        // drags come from the cursor check below, since watching every mouse move woke nxtch
        // 60-120 times a second whenever the mouse moved anywhere.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(g) }
        // Esc closes when the panel has keyboard focus.
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { self?.setOpen(false) }
                return nil
            }
            return e
        }) { monitors.append(k) }

        // Hover and drag detection: reading the cursor position is trivial, and unlike event
        // monitors it also works while another app's menu is open or during a drag.
        pollTimer = .repeating(0.1, tolerance: 0.03) { [weak self] in self?.trackMouse() }

        // ⌃⌥V: open the clipboard from anywhere.
        hotkey = Hotkey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.toggleClipboard() }
        }
    }

    private func updateMeterScope() {
        if vm.isOpen {
            model.meterScope = vm.tab == .media ? .all : .none
        } else {
            model.meterScope = settings.showEars ? .primary : .none
        }
    }

    /// Only touch the window when the value actually changes (this runs on every mouse move).
    private func setIgnoresMouse(_ ignore: Bool) {
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
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

    // MARK: Geometry

    /// The hardware notch (plus a hair of slack). Nothing else can live here, so hovering it is never accidental.
    private var notchTriggerRect: NSRect {
        let f = vm.geometry.screenFrame, n = vm.geometry.notchSize
        return NSRect(x: f.midX - n.width / 2 - 4, y: f.maxY - n.height, width: n.width + 8, height: n.height)
    }

    /// While dragging content, a more generous target around the notch.
    private var dragTriggerRect: NSRect {
        let f = vm.geometry.screenFrame, n = vm.geometry.notchSize
        return NSRect(x: f.midX - n.width / 2 - 60, y: f.maxY - n.height - 30, width: n.width + 120, height: n.height + 30)
    }

    /// The visible black shape while open, in screen coordinates.
    private var openShapeRect: NSRect {
        let f = vm.geometry.screenFrame
        let s = vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil)
        let w = s.width + 38 // + top flares
        return NSRect(x: f.midX - w / 2, y: f.maxY - s.height, width: w, height: s.height)
    }

    /// Like `NSRect.contains`, but counts the top screen edge as inside. When the cursor is pushed
    /// against the top of the screen, `NSEvent.mouseLocation.y == screenFrame.maxY` exactly, which
    /// `contains` rejects — that made "nudging" up into the notch fail.
    private func hits(_ r: NSRect, _ p: NSPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY + 1
    }

    // MARK: Mouse

    /// Mouse button state from the combined session (real and synthesized input).
    private var mouseButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    private func updateDragState(buttonDown: Bool) {
        // Reading a pasteboard is a cross-process call, so only do it while a button is held.
        if buttonDown {
            let count = NSPasteboard(name: .drag).changeCount
            if !buttonWasDown { dragBaseline = count }
            if count != dragBaseline, !contentDragActive {
                contentDragActive = true
                Log.notch.info("content drag detected")
            }
        } else {
            contentDragActive = false
        }
        buttonWasDown = buttonDown
    }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        let buttonDown = mouseButtonDown
        updateDragState(buttonDown: buttonDown)

        if vm.isOpen {
            let overShape = hits(openShapeRect, p)
            // Only the visible shape takes clicks; the rest of the window is click-through.
            setIgnoresMouse(!overShape)
            if pinnedOpen { return }
            // A little slack before closing so small overshoots don't snap it shut.
            if overShape || hits(openShapeRect.insetBy(dx: -10, dy: -10), p) || menuTracking {
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

        setIgnoresMouse(true)

        // Dragging something over the notch opens the shelf immediately.
        if contentDragActive, hits(dragTriggerRect, p) {
            openWork?.cancel(); openWork = nil
            vm.tab = .shelf
            setOpen(true, reason: "drag")
            return
        }

        if hits(notchTriggerRect, p), !buttonDown {
            guard openWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.openWork = nil
                    // Still resting on the notch and not dragging? Then open.
                    if self.hits(self.notchTriggerRect, NSEvent.mouseLocation), !self.mouseButtonDown {
                        self.setOpen(true, reason: "hover")
                    }
                }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDwell, execute: work)
        } else {
            openWork?.cancel(); openWork = nil
        }
    }

    private func clickedOutside() {
        guard vm.isOpen, !menuTracking, !hits(openShapeRect, NSEvent.mouseLocation) else { return }
        setOpen(false)
    }

    // MARK: Open / close

    private func toggleClipboard() {
        if vm.isOpen && pinnedOpen && vm.tab == .clipboard { setOpen(false); return }
        vm.tab = .clipboard
        pinnedOpen = true
        if !vm.isOpen { setOpen(true, reason: "hotkey") }
        // Take keyboard focus (without activating nxtch) so you can type to search right away.
        panel.makeKey()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .nxtchFocusSearch, object: nil) }
    }

    private func setOpen(_ open: Bool, reason: String = "") {
        closeWork?.cancel(); closeWork = nil
        guard open != vm.isOpen else { return }
        Log.notch.info("\(open ? "opened" : "closed", privacy: .public) reason=\(reason, privacy: .public) tab=\(self.vm.tab.rawValue, privacy: .public) key=\(self.panel.isKeyWindow, privacy: .public)")
        if open {
            shelf.prune()
            clipboard.expire()
            clipboard.selecting = false
            clipboard.pasteTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        } else {
            pinnedOpen = false
            // Hand keyboard focus back to the app you were using.
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        withAnimation(.notch(opening: open)) {
            vm.isOpen = open
        }
        setIgnoresMouse(!(open && hits(openShapeRect, NSEvent.mouseLocation)))
        updateMeterScope()
    }
}
