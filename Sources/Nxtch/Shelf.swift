import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    /// The file lives in nxtch's own storage (dropped text, images, links, file promises) and is
    /// deleted with the item. Dropped files are only referenced.
    let owned: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    /// Dragging out only copies this one, never moves it. Worked out from where the file is, not
    /// saved, so older shelf lists still load.
    var copyOnly: Bool { !owned && Self.copyOnly(url, home: URL(fileURLWithPath: NSHomeDirectory())) }

    /// A file that belongs to another app rather than to you: anything in ~/Library (Mail and
    /// Messages attachments), inside a package (a Photos library, an app bundle), outside your
    /// home folder and external disks, or in a folder you can't write to. Moving one of those
    /// would pull it out of the app that keeps it.
    nonisolated static func copyOnly(_ file: URL, home: URL) -> Bool {
        // Links resolved and case folded, so a symlinked folder, /Volumes/Macintosh HD (a link
        // to /) or ~/library can't pass for one of your own folders.
        // The folder is resolved, then the name put back: the file itself may be gone already.
        let file = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent)
        let path = file.path.lowercased()
        let homePath = home.resolvingSymlinksInPath().path.lowercased() + "/"
        if path.hasPrefix(homePath + "library/") { return true }
        if !path.hasPrefix(homePath), !path.hasPrefix("/volumes/") { return true }
        var dir = file.deletingLastPathComponent()
        while dir.path.count > 1 {
            if NSWorkspace.shared.isFilePackage(atPath: dir.path) { return true }
            dir.deleteLastPathComponent()
        }
        return !FileManager.default.isWritableFile(atPath: file.deletingLastPathComponent().path)
    }
}

/// A temporary holding area for anything dragged onto the notch.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// Ticked tiles: each tile's circle, or the check mark button for all of them.
    @Published private(set) var selection: Set<UUID> = []
    /// The items being dragged out of the shelf (shows the Delete zone).
    @Published private(set) var dragging: Set<UUID> = []
    /// A drag is over the Delete zone.
    @Published var deleteTargeted = false
    var isDragging: Bool { !dragging.isEmpty }
    /// The current drag out ended on nxtch itself (shelf or Delete zone), not somewhere else.
    private var droppedInternally = false

    private let storage = AppFiles.dir("Shelf")
    /// Largest thing nxtch will copy into its own storage. Files it only references have no limit.
    nonisolated static let maxCopiedBytes = 1 << 30

    init() {
        let data = UserDefaults.standard.data(forKey: "shelfItems")
        let saved = data.flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) }
        items = saved ?? []
        prune()
        // A list that won't load may still name the only copy of some dropped text: keep the files.
        if data == nil || saved != nil { sweep() }
        items.forEach(makeThumbnail)
    }

    var isEmpty: Bool { items.isEmpty }

    func add(_ url: URL, owned: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        forget(Set(items.filter { $0.path == url.path }.map(\.id)))   // the same file again moves to the end
        let item = ShelfItem(id: UUID(), path: url.path, owned: owned)
        items.append(item)
        Log.shelf.info("added owned=\(owned, privacy: .public) count=\(self.items.count, privacy: .public)")
        makeThumbnail(item)
        save()
    }

    func remove(_ gone: [ShelfItem]) { remove(gone, deleteFile: true) }

    /// Takes items off the shelf in one go: one redraw and one save, however many there are.
    private func remove(_ gone: [ShelfItem], deleteFile: Bool) {
        guard !gone.isEmpty else { return }
        forget(Set(gone.map(\.id)))
        if deleteFile { gone.forEach(deleteOwned) }
        save()
    }

    /// Drops items along with their thumbnails and selection.
    private func forget(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        thumbnails = thumbnails.filter { !ids.contains($0.key) }
        selection.subtract(ids)
    }

    /// Only ever deletes nxtch's own copies, even if the saved list was tampered with, and never
    /// one that is (back) on the shelf.
    private func deleteOwned(_ item: ShelfItem) {
        guard item.owned, AppFiles.contains(storage, item.url), !items.contains(where: { $0.path == item.path }) else { return }
        try? FileManager.default.removeItem(at: item.url)
    }

    /// Deletes files left in nxtch's storage that no shelf item points at (nxtch quit before a
    /// dragged-out copy was cleaned up).
    private func sweep() {
        // Never through a symlink: if the folder were swapped for a link to somewhere else, this
        // would empty that place instead.
        guard AppFiles.isOwnFolder(storage) else { return }
        let kept = Set(items.map(\.url.standardizedFileURL.path))
        let files = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        for f in files where !kept.contains(f.standardizedFileURL.path) { try? FileManager.default.removeItem(at: f) }
    }

    /// What the header buttons and a tile's menu act on: the selection, or everything without one.
    var actionItems: [ShelfItem] { selection.isEmpty ? items : items.filter { selection.contains($0.id) } }

    /// The items a click, drag or menu on `item` applies to: the whole selection when `item` is
    /// part of it, otherwise just `item`.
    func group(of item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    func clear() { remove(actionItems) }

    // MARK: Selection

    /// Tiles only get a tick circle when there is more than one.
    var showsTicks: Bool { items.count > 1 }

    func toggle(_ item: ShelfItem) {
        if selection.remove(item.id) == nil { selection.insert(item.id) }
    }

    var allSelected: Bool { !items.isEmpty && selection.count == items.count }

    /// The check mark button: selects everything, or clears the selection when everything already is.
    func toggleSelectAll() { selection = allSelected ? [] : Set(items.map(\.id)) }

    /// Drops items whose files were moved or deleted elsewhere.
    func prune() {
        remove(items.filter { !FileManager.default.fileExists(atPath: $0.path) }, deleteFile: false)
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }

    /// Puts the files on the clipboard: paste in Finder to copy them, ⌥⌘V to move them.
    func copyToClipboard(_ items: [ShelfItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items.map { $0.url as NSURL })
    }

    func airDrop(_ items: [ShelfItem]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items.map(\.url))
    }

    // MARK: Dragging out

    func beginDrag(_ dragged: [ShelfItem]) { dragging = Set(dragged.map(\.id)) }

    /// Shelf items are temporary: a successful drop anywhere else takes them off the shelf.
    func finishDrag(_ dragged: [ShelfItem], operation: NSDragOperation) {
        defer { dragging = []; deleteTargeted = false; droppedInternally = false }
        guard !droppedInternally, !operation.isEmpty else { return }
        let ids = Set(items.map(\.id))
        remove(dragged.filter { ids.contains($0.id) && leavesShelf($0, operation) }, deleteFile: false)
    }

    /// Whether a dragged-out item leaves the shelf.
    private func leavesShelf(_ item: ShelfItem, _ operation: NSDragOperation) -> Bool {
        // nxtch's own copy is deleted with the item, so only let go of it when the destination
        // said it moved or copied the file. A drop that just took the path keeps it on the shelf.
        if item.owned, operation.isDisjoint(with: [.move, .copy]) {
            Log.shelf.info("dragged out op=\(operation.rawValue, privacy: .public); kept (not moved or copied)")
            return false
        }
        Log.shelf.info("dragged out op=\(operation.rawValue, privacy: .public); removed from shelf")
        // The drag ending only means the destination accepted. Finder moves or copies the file
        // afterwards, so deleting nxtch's copy now pulls it out from under Finder (error -8058).
        // A move takes the file away by itself; a copy leaves ours behind, deleted ten minutes
        // later (a big copy to a slow disk can take a while), or at the next launch.
        if item.owned, !operation.contains(.move) {
            after(600) { [weak self] in self?.deleteOwned(item) }
        }
        return true
    }

    /// A drop on the Delete zone. The only thing that can be dragged there is a shelf item.
    func deleteDragged() -> Bool {
        droppedInternally = true
        let doomed = items.filter { dragging.contains($0.id) }
        guard !doomed.isEmpty else { return false }
        Log.shelf.info("deleted via drop zone count=\(doomed.count, privacy: .public)")
        remove(doomed)
        return true
    }

    // MARK: Dropping in

    /// Accepts anything dragged onto the notch: files are referenced; images, links, text and
    /// file promises are saved into nxtch's storage.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // A shelf item dropped back onto the notch: nothing to add, and it stays on the shelf.
        if isDragging { droppedInternally = true; return false }
        Log.shelf.info("drop providers=\(providers.count, privacy: .public)")
        providers.forEach(ingest)
        return !providers.isEmpty
    }

    private nonisolated func ingest(_ p: NSItemProvider) {
        let storage = self.storage
        let add: @Sendable (URL, Bool) -> Void = { url, owned in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.add(url, owned: owned) } }
        }
        let has = { (t: UTType) in p.hasItemConformingToTypeIdentifier(t.identifier) }
        let firstType = { (t: UTType) in p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: t) == true } }

        if has(.fileURL) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url, url.isFileURL { add(url, false) } }
            return
        }

        // Things with no file behind them (a dragged link, selected text) are saved as a file.
        let isLink = has(.url), isText = has(.plainText)
        let saveLinkOrText = {
            if isLink {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    // Only web and mail links: a .webloc opens whatever its URL scheme points at.
                    guard let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                          let dest = AppFiles.unique((url.host() ?? "link") + ".webloc", in: storage),
                          let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0),
                          (try? data.write(to: dest, options: .withoutOverwriting)) != nil else { return }
                    add(dest, true)
                }
            } else if isText {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    let title = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? "text"
                    guard let dest = AppFiles.unique(AppFiles.safeName(title, fallback: "text") + ".txt", in: storage),
                          (try? Data(text.utf8).write(to: dest, options: .withoutOverwriting)) != nil else { return }
                    add(dest, true)
                }
            }
        }

        // A file dragged from Finder often arrives as its content type (a PDF, an image, plain
        // text) with no file URL. Asked for in place, the provider hands over the original itself:
        // that one is referenced like any other file, so dragging it out moves the original and
        // nothing is duplicated. Anything else comes as a temporary file, which is copied in,
        // unless it is a link or text, which are saved under a name of their own.
        let image = firstType(.image)
        guard let type = image ?? firstType(.data) else { saveLinkOrText(); return }
        let copiesFile = image != nil || !(isLink || isText)
        let suggested = p.suggestedName
        _ = p.loadInPlaceFileRepresentation(forTypeIdentifier: type) { tmp, inPlace, _ in
            Log.shelf.info("file representation inPlace=\(inPlace, privacy: .public)")
            if let tmp, inPlace { add(tmp, false); return }
            guard copiesFile else { saveLinkOrText(); return }
            guard let tmp else { return }
            // A copy this big is almost certainly a mistake, and would fill the disk without a word.
            if let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > ShelfStore.maxCopiedBytes {
                Log.shelf.info("drop skipped: over the size limit for copied items")
                return
            }
            var name = suggested ?? tmp.lastPathComponent
            if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension { name += ".\(ext)" }
            if let dest = AppFiles.unique(name, in: storage), (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil {
                add(dest, true)
            }
        }
    }

    // MARK: Internals

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "shelfItems") }
    }

    private func makeThumbnail(_ item: ShelfItem) {
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.path)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.thumbnails[id] != nil { self.thumbnails[id] = image } } }
        }
    }
}
