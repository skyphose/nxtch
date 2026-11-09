import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// ~/Library/Application Support/nxtch/<name>
enum AppFiles {
    static func dir(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nxtch/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file URL in `dir` that doesn't exist yet, based on `name`.
    static func unique(_ name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    /// True when the file lives in nxtch's own storage (dropped text, images, links, file promises)
    /// and should be deleted when removed from the shelf. Dropped files are only referenced.
    let owned: Bool
    let added: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// The shelf: a temporary holding area for files dragged onto the notch.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// The shelf item currently being dragged out (shows the Delete drop zone).
    @Published private(set) var draggingItemID: UUID?
    @Published var deleteTargeted = false
    /// Set when a shelf drag was dropped back onto nxtch itself (shelf or Delete zone).
    private var droppedInternally = false

    private let defaultsKey = "shelfItems"
    private let storage = AppFiles.dir("Shelf")

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = saved
        }
        prune()
        items.forEach(makeThumbnail)
    }

    var isEmpty: Bool { items.isEmpty }
    var urls: [URL] { items.map(\.url) }

    // MARK: Editing

    func add(_ url: URL, owned: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        items.removeAll { $0.path == url.path }
        let item = ShelfItem(id: UUID(), path: url.path, owned: owned, added: Date())
        items.append(item)
        Log.shelf.info("added owned=\(owned, privacy: .public) count=\(self.items.count, privacy: .public)")
        makeThumbnail(item)
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        if item.owned { try? FileManager.default.removeItem(at: item.url) }
        save()
    }

    func clear() { items.forEach(remove) }

    // MARK: Dragging out

    func beginDrag(_ item: ShelfItem) {
        draggingItemID = item.id
        Log.shelf.info("drag out started")
    }

    /// Called by the drag source when a drag out of the shelf ends. Shelf items are temporary:
    /// a successful drop anywhere else takes the item off the shelf (and deletes nxtch's own copy).
    func finishDrag(_ item: ShelfItem, operation: NSDragOperation) {
        defer { endDrag() }
        if droppedInternally { droppedInternally = false; return }
        guard !operation.isEmpty else {
            Log.shelf.info("drag out cancelled; item kept")
            return
        }
        guard items.contains(where: { $0.id == item.id }) else { return }
        Log.shelf.info("dragged out op=\(operation.rawValue, privacy: .public) owned=\(item.owned, privacy: .public); removed from shelf")
        remove(item)
    }

    func endDrag() {
        guard draggingItemID != nil else { return }
        draggingItemID = nil
        deleteTargeted = false
    }

    /// Drop on the Delete zone: removes the matching shelf item(s). Matches by file path so it
    /// doesn't depend on drag state that may already have been cleared.
    func deleteDropped(_ providers: [NSItemProvider]) -> Bool {
        droppedInternally = true
        let fallback = draggingItemID
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let match = url.flatMap { u in self.items.first { $0.path == u.path } }
                            ?? self.items.first { $0.id == fallback }
                        if let match {
                            Log.shelf.info("deleted via drop zone owned=\(match.owned, privacy: .public)")
                            self.remove(match)
                        }
                        self.endDrag()
                    }
                }
            }
        }
        return handled
    }

    /// Drop items whose files were moved or deleted elsewhere.
    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    // MARK: Actions

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    /// Puts the files on the clipboard; paste in Finder to copy them (⌥⌘V to move).
    func copyToClipboard(_ items: [ShelfItem]? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects((items ?? self.items).map { $0.url as NSURL })
    }

    func airDrop(_ items: [ShelfItem]? = nil) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: (items ?? self.items).map(\.url))
    }

    // MARK: Dropping in

    /// Accepts anything dragged onto the notch: files (referenced), images, links, text and
    /// file promises (copied into nxtch's storage).
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let types = providers.map { $0.registeredTypeIdentifiers.joined(separator: ",") }.joined(separator: " | ")
        Log.shelf.info("drop providers=\(providers.count, privacy: .public) types=\(types, privacy: .public)")
        // A shelf item dropped back onto the notch: nothing to add, and don't take it off the shelf.
        if draggingItemID != nil {
            droppedInternally = true
            return false
        }
        providers.forEach(ingest)
        return !providers.isEmpty
    }

    private nonisolated func ingest(_ p: NSItemProvider) {
        let storage = AppFiles.dir("Shelf")
        let addOwned: @Sendable (URL) -> Void = { url in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.add(url, owned: true) } }
        }

        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.add(url) } }
            }
        } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            copyRepresentation(p, type: type, into: storage, done: addOwned)
        } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let name = (url.host ?? "Link") + ".webloc"
                let dest = AppFiles.unique(name, in: storage)
                let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                if (try? plist?.write(to: dest)) != nil { addOwned(dest) }
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = p.loadObject(ofClass: String.self) { text, _ in
                guard let text, !text.isEmpty else { return }
                let title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
                let name = String(title.prefix(40)).replacingOccurrences(of: "/", with: "-") + ".txt"
                let dest = AppFiles.unique(name, in: storage)
                if (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil { addOwned(dest) }
            }
        } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
            copyRepresentation(p, type: type, into: storage, done: addOwned)
        }
    }

    /// Handles real data and file promises alike: the provider hands us a temporary file to copy.
    private nonisolated func copyRepresentation(_ p: NSItemProvider, type: String, into storage: URL,
                                                done: @escaping @Sendable (URL) -> Void) {
        let suggested = p.suggestedName
        _ = p.loadFileRepresentation(forTypeIdentifier: type) { tmp, _ in
            guard let tmp else { return }
            var name = suggested ?? tmp.lastPathComponent
            if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
                name += ".\(ext)"
            }
            let dest = AppFiles.unique(name, in: storage)
            if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil { done(dest) }
        }
    }

    // MARK: Internals

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func makeThumbnail(_ item: ShelfItem) {
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.path)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96),
                                                   scale: 2, representationTypes: .thumbnail)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.thumbnails[id] != nil { self.thumbnails[id] = image }
                }
            }
        }
    }
}
