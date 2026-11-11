import AppKit
import Carbon.HIToolbox
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
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Geometry of the physical notch on the screen we live on.
struct NotchGeometry: Equatable {
    var notchSize: CGSize
    var screenFrame: CGRect

    /// A "fake notch" for displays without one.
    static let fallbackNotch = CGSize(width: 200, height: 32)

    static func current() -> (NSScreen, NotchGeometry)? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return nil }
        var size = fallbackNotch
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
    @Published var isDropTargeted = false
    @Published var geometry: NotchGeometry
    @Published var tab: NotchTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab"); tabChanged?() }
    }
    var tabChanged: (@MainActor () -> Void)?

    /// Corner radii of the open shape. The top corners flare out past the body, so the open
    /// shape is `2 * openTopRadius` wider than its content, and content sits `contentInset` in.
    static let openTopRadius: CGFloat = 19
    static let contentInset: CGFloat = openTopRadius + 12

    static let openWidth: CGFloat = 560
    static let earWidth: CGFloat = 34
    static let rowHeight: CGFloat = 46
    static let maxMixerRows = 4
    static let nowPlayingHeight: CGFloat = 76
    static let sectionLabelHeight: CGFloat = 22
    /// Shelf tiles: 4 a row leaves room for the Delete zone beside them while you drag. The shelf
    /// grows a row at a time, up to 3, then scrolls.
    static let shelfColumns = 4
    static let shelfMaxRows = 3
    static let shelfTileSize = CGSize(width: 90, height: 97)
    static let shelfSpacing: CGFloat = 6

    static func shelfHeight(items: Int) -> CGFloat {
        let rows = CGFloat(min(max(1, (items + shelfColumns - 1) / shelfColumns), shelfMaxRows))
        return 16 + rows * shelfTileSize.height + (rows - 1) * shelfSpacing + 3
    }
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

    func openSize(rows: Int, nowPlaying: Bool, shelfItems: Int) -> CGSize {
        let body: CGFloat
        switch tab {
        case .media:
            body = (nowPlaying ? Self.nowPlayingHeight : 0) + Self.sectionLabelHeight
                + CGFloat(max(1, min(rows, Self.maxMixerRows))) * Self.rowHeight
        case .shelf:
            body = Self.shelfHeight(items: shelfItems)
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
        let geo = NotchGeometry.current()?.1 ?? NotchGeometry(notchSize: NotchGeometry.fallbackNotch, screenFrame: .zero)
        vm = NotchViewModel(geometry: geo)
        panel = NotchPanel(contentRect: .zero)
        let host = NSHostingView(rootView: NotchView(vm: vm, model: model, nowPlaying: nowPlaying, settings: settings,
                                                     shelf: shelf, clipboard: clipboard))
        host.sizingOptions = []
        panel.contentView = host
        position()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = true

        observeSettings()
        observeSystem()
        installInput()
    }

    /// Settings and the tab change how the panel behaves. Meter taps follow what's on screen.
    private func observeSettings() {
        settings.onChange = { [weak self] in self?.applySettings() }
        vm.tabChanged = { [weak self] in self?.updateMeterScope() }
        applySettings()
    }

    private func applySettings() {
        var b: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if settings.showInFullScreen { b.insert(.fullScreenAuxiliary) }
        if panel.collectionBehavior != b {
            panel.collectionBehavior = b
            panel.orderFrontRegardless()
        }
        clipboard.enabled = settings.clipboardEnabled
        if let hotkey, settings.clipboardShortcut != appliedShortcut {
            hotkey.set(settings.clipboardShortcut)
            appliedShortcut = settings.clipboardShortcut
        }
        updateMeterScope()
    }

    /// Screen changes, menus opening, and a paste asking the panel to close.
    private func observeSystem() {
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
        clipboard.requestClose = { [weak self] in self?.setOpen(false) }
    }

    /// Everything that listens for input: clicks elsewhere, Esc, the cursor check and the shortcut.
    private func installInput() {
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
        // A two-finger swipe sideways flips tabs.
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            nonisolated(unsafe) let event = e   // monitors run on the main thread
            return MainActor.assumeIsolated { self?.swipe(event) ?? false } ? nil : e
        }) { monitors.append(s) }

        // Hover and drag detection: reading the cursor position is trivial, and unlike event
        // monitors it also works while another app's menu is open or during a drag.
        setPollInterval(Self.fastPoll)

        // ⌃⌥V by default: open the clipboard from anywhere. The gear menu changes or turns it off.
        hotkey = Hotkey { [weak self] in
            MainActor.assumeIsolated { self?.toggleClipboard() }
        }
        hotkey?.set(settings.clipboardShortcut)
        appliedShortcut = settings.clipboardShortcut
    }

    private var appliedShortcut: ClipboardShortcut?

    private func updateMeterScope() {
        if !settings.showMeters {
            model.meterScope = .none
        } else if vm.isOpen {
            model.meterScope = vm.tab == .media ? .all : .none
        } else {
            model.meterScope = settings.showEars ? .primary : .none
        }
    }

    /// Only touch the window when the value actually changes (this runs on every cursor check).
    private func setIgnoresMouse(_ ignore: Bool) {
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
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
        let s = vm.openSize(rows: model.apps.count, nowPlaying: nowPlaying.info != nil, shelfItems: shelf.items.count)
        let w = s.width + 2 * NotchViewModel.openTopRadius
        return NSRect(x: f.midX - w / 2, y: f.maxY - s.height, width: w, height: s.height)
    }

    /// Like `NSRect.contains`, but counts the top screen edge as inside. When the cursor is pushed
    /// against the top of the screen, `NSEvent.mouseLocation.y == screenFrame.maxY` exactly, which
    /// `contains` rejects. That made "nudging" up into the notch fail.
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

    /// The cursor check runs 10 times a second near the notch, while it's open, or while a button
    /// is held (a drag may be on its way), and 3 times a second otherwise. The check itself is a
    /// round trip to the window server, and this timer is most of nxtch's wakeups at rest.
    private static let fastPoll: TimeInterval = 0.1
    private static let slowPoll: TimeInterval = 0.33
    /// How far below the top of the screen counts as near the notch.
    private static let nearTop: CGFloat = 120
    private var pollInterval: TimeInterval = 0

    private func setPollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = .repeating(interval, tolerance: interval * 0.3) { [weak self] in self?.trackMouse() }
    }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        let buttonDown = mouseButtonDown
        updateDragState(buttonDown: buttonDown)
        let near = vm.isOpen || buttonDown || p.y > vm.geometry.screenFrame.maxY - Self.nearTop
        setPollInterval(near ? Self.fastPoll : Self.slowPoll)

        if vm.isOpen {
            let overShape = hits(openShapeRect, p)
            // Only the visible shape takes clicks; the rest of the window is click-through.
            setIgnoresMouse(!overShape)
            if pinnedOpen { return }
            // A little slack before closing so small overshoots don't snap it shut.
            if overShape || hits(openShapeRect.insetBy(dx: -10, dy: -10), p) || menuTracking {
                closeWork?.cancel(); closeWork = nil
            } else if closeWork == nil, !buttonDown {
                closeWork = after(Self.closeDelay) { [weak self] in self?.closeWork = nil; self?.setOpen(false) }
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
            openWork = after(Self.openDwell) { [weak self] in
                guard let self else { return }
                openWork = nil
                // Still resting on the notch and not dragging? Then open.
                if hits(notchTriggerRect, NSEvent.mouseLocation), !mouseButtonDown { setOpen(true, reason: "hover") }
            }
        } else {
            openWork?.cancel(); openWork = nil
        }
    }

    // MARK: Swipe between tabs

    private var swipeX: CGFloat = 0, swipeY: CGFloat = 0, swiped = false

    /// Two fingers sideways on the open notch: left for the next tab, right for the previous one,
    /// once per gesture. Mostly-vertical scrolling is left to the lists. Returns whether it took
    /// the event.
    private func swipe(_ e: NSEvent) -> Bool {
        guard vm.isOpen, e.window === panel, e.hasPreciseScrollingDeltas else { return false }
        if e.phase == .began { swipeX = 0; swipeY = 0; swiped = false }
        if swiped { return true }   // the rest of this gesture, momentum included
        guard e.phase == .began || e.phase == .changed else { return false }
        swipeX += e.scrollingDeltaX
        swipeY += e.scrollingDeltaY
        guard abs(swipeX) > 40, abs(swipeX) > 2 * abs(swipeY) else { return false }
        swiped = true
        // With natural scrolling the deltas follow the fingers; without it they are reversed.
        let fingersLeft = (e.isDirectionInvertedFromDevice ? swipeX : -swipeX) < 0
        let tabs = NotchTab.allCases
        let next = (tabs.firstIndex(of: vm.tab) ?? 0) + (fingersLeft ? 1 : -1)
        guard tabs.indices.contains(next) else { return true }
        vm.tab = tabs[next]
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return true
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
        focusSearch()
    }

    /// Puts the cursor in the clipboard search field. SwiftUI can build the tab a moment after it
    /// is picked, so this looks again for up to half a second.
    private func focusSearch(tries: Int = 10) {
        if let field = panel.contentView.flatMap(Self.textField) { panel.makeFirstResponder(field); return }
        if tries > 0 { after(0.05) { [weak self] in self?.focusSearch(tries: tries - 1) } }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField).first
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
            vm.isDropTargeted = false
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
