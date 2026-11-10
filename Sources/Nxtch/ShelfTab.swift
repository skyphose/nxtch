import SwiftUI

/// Shelf tab: files parked on the notch. Drag them back out to wherever they should go.
struct ShelfTab: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        if shelf.items.isEmpty {
            // No words: files go in, files come out.
            VStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .medium))
                Image(systemName: "tray").font(.system(size: 28, weight: .light))
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(0.18))
            )
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                // Grows down a row at a time (the panel follows), and scrolls past the last one.
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(NotchViewModel.shelfTileSize.width),
                                                                 spacing: NotchViewModel.shelfSpacing),
                                             count: NotchViewModel.shelfColumns),
                              alignment: .leading, spacing: NotchViewModel.shelfSpacing) {
                        ForEach(shelf.items) { item in ShelfTile(item: item, shelf: shelf) }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if shelf.isDragging {
                    DeleteZone(shelf: shelf)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.notch, value: shelf.isDragging)
        }
    }
}

/// Appears while you drag an item out of the shelf: drop on it to delete the item.
private struct DeleteZone: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        let hot = shelf.deleteTargeted
        VStack(spacing: 6) {
            Image(systemName: hot ? "trash.fill" : "trash").font(.system(size: 26, weight: .semibold))
            Text("Delete").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(hot ? .white : .red)
        .frame(width: 110)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hot ? Color.red : Color.red.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(hot ? 0 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .scaleEffect(hot ? 1.05 : 1)
        .animation(.control, value: hot)
        .padding(.vertical, 8)
        .onDrop(of: [.fileURL], isTargeted: $shelf.deleteTargeted) { _ in
            shelf.deleteDragged()
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    private var selected: Bool { shelf.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumb = shelf.thumbnails[item.id] {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc").font(.system(size: 28))
                }
            }
            .frame(width: 54, height: 54)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 78, height: 26, alignment: .top)
        }
        .foregroundStyle(.white)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.35) : .white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
        .overlay(alignment: .topLeading) {
            if shelf.showsTicks {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.5))
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        // AppKit drag source + click/menu handling, so we learn whether a drag out succeeded.
        // It also takes clicks on the tick circle above.
        .overlay(ShelfDragSource(item: item, shelf: shelf))
    }
}

/// Starts shelf drags through AppKit: unlike SwiftUI's `onDrag`, an `NSDraggingSource` is told
/// how the drag ended, so a successful drop elsewhere can take the item off the shelf.
private struct ShelfDragSource: NSViewRepresentable {
    let item: ShelfItem
    let shelf: ShelfStore

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let v = ShelfDragSourceView()
        v.item = item
        v.shelf = shelf
        return v
    }

    func updateNSView(_ v: ShelfDragSourceView, context: Context) {
        v.item = item
        v.shelf = shelf
    }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    var item: ShelfItem!
    weak var shelf: ShelfStore?
    private var mouseDownEvent: NSEvent?
    private var dragged: [ShelfItem] = []
    /// Where ShelfTile draws the tick circle: the tile's top-left corner.
    private static let tickArea = NSRect(x: 0, y: 0, width: 30, height: 30)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click on the tick circle ticks or unticks the tile. Anywhere else, a press may start a
    /// drag, and a double click opens the item.
    override func mouseDown(with event: NSEvent) {
        guard let shelf else { return }
        if shelf.showsTicks, Self.tickArea.contains(convert(event.locationInWindow, from: nil)) {
            shelf.toggle(item)
            return
        }
        mouseDownEvent = event
        if event.clickCount == 2 { shelf.open(item) }
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let shelf else { return }
        mouseDownEvent = nil
        dragged = shelf.group(of: item)
        let p = convert(down.locationInWindow, from: nil)
        let dragItems = dragged.enumerated().map { i, it in
            let d = NSDraggingItem(pasteboardWriter: it.url as NSURL)
            let image = shelf.thumbnails[it.id] ?? NSWorkspace.shared.icon(forFile: it.path)
            let o = CGFloat(min(i, 4)) * 6   // fan the pile out a little
            d.setDraggingFrame(NSRect(x: p.x - 24 + o, y: p.y - 24 + o, width: 48, height: 48), contents: image)
            return d
        }
        shelf.beginDrag(dragged)
        beginDraggingSession(with: dragItems, event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return [.copy, .generic] }
        // The shelf is a file mover: the destination is offered a move first, for your own files
        // as much as for things nxtch saved. nxtch never moves or deletes an original itself. The
        // destination does the move, so a target that only reads the file (an upload, an
        // attachment) takes a copy and the original stays where it was.
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return [.copy] }    // ⌥: leave the original in place
        if flags.contains(.command) { return [.move] }   // ⌘: move or nothing
        return [.move, .copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        shelf?.finishDrag(dragged, operation: operation)
        dragged = []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shelf, let item else { return nil }
        // An unticked tile's menu acts on that tile alone, a ticked one's on every ticked tile.
        let group = shelf.group(of: item)
        let menu = NSMenu()
        let entries: [(String, () -> Void)] = [
            ("Open", { group.forEach(shelf.open) }),
            ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting(group.map(\.url)) }),
            ("Copy", { shelf.copyToClipboard(group) }), ("AirDrop…", { shelf.airDrop(group) }), ("", {}),
            ("Delete", { shelf.remove(group) }),
        ]
        for (title, action) in entries {
            menu.addItem(title.isEmpty ? .separator() : ClosureMenuItem(title: title, action: action))
        }
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
