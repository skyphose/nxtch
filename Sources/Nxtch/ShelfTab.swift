import SwiftUI

/// Shelf tab: files parked on the notch. Drag them back out to wherever they should go.
struct ShelfTab: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .light))
                Text("Drop here").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(0.18))
            )
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { item in ShelfTile(item: item, shelf: shelf) }
                    }
                    .padding(.vertical, 8)
                }
                if shelf.draggingItemID != nil {
                    DeleteZone(shelf: shelf)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: shelf.draggingItemID != nil)
        }
    }
}

/// Appears while you drag an item out of the shelf: drop on it to delete the item.
private struct DeleteZone: View {
    @ObservedObject var shelf: ShelfStore
    @State private var hot = false

    var body: some View {
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
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hot)
        .padding(.vertical, 8)
        .onDrop(of: [.fileURL], isTargeted: $hot) { _ in
            shelf.deleteDragged()
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore

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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
        .contentShape(Rectangle())
        // AppKit drag source + click/menu handling, so we learn whether a drag out succeeded.
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 { shelf?.open(item) }
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let shelf else { return }
        mouseDownEvent = nil
        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let image = shelf.thumbnails[item.id] ?? NSWorkspace.shared.icon(forFile: item.path)
        let p = convert(down.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: image)
        shelf.beginDrag(item)
        beginDraggingSession(with: [dragItem], event: down, source: self)
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
        shelf?.finishDrag(item, operation: operation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shelf, let item else { return nil }
        let menu = NSMenu()
        let entries: [(String, () -> Void)] = [
            ("Open", { shelf.open(item) }), ("Show in Finder", { shelf.reveal(item) }),
            ("Copy", { shelf.copyToClipboard([item]) }), ("AirDrop…", { shelf.airDrop([item]) }), ("", {}),
            ("Delete", { shelf.remove(item) }),
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
