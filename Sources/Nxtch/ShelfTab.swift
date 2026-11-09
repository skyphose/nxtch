import SwiftUI

/// Shelf tab: files parked on the notch. Drag them back out to wherever they should go.
struct ShelfTab: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .light))
                Text("Drop files, images, links or text on the notch").font(.system(size: 12, weight: .medium))
                Text("Drag them back out whenever you're ready").font(.system(size: 11)).foregroundStyle(.secondary)
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
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hot)
        .padding(.vertical, 8)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { shelf.deleteTargeted }, set: { shelf.deleteTargeted = $0 })) { providers in
            shelf.deleteDropped(providers)
        }
        .help("Drop here to delete from the shelf (original files are never trashed)")
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
        .help(item.path)
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
        // Things nxtch saved itself (text, links, images, promises) move out: no original to keep.
        if item.owned { return [.move, .copy, .generic] }
        // Your own files copy out by default; hold ⌘ to move them.
        return NSEvent.modifierFlags.contains(.command) ? [.move] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        shelf?.finishDrag(item, operation: operation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let mi = ClosureMenuItem(title: title, action: action)
            menu.addItem(mi)
        }
        guard let shelf, let item else { return nil }
        add("Open") { shelf.open(item) }
        add("Show in Finder") { shelf.reveal(item) }
        add("Copy") { shelf.copyToClipboard([item]) }
        add("AirDrop…") { shelf.airDrop([item]) }
        menu.addItem(.separator())
        add("Delete") { shelf.remove(item) }
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
