import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// ~/Library/Application Support/nxtch/<name>, readable by this user only.
enum AppFiles {
    static func dir(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nxtch/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)   // also fixes existing folders
        return url
    }

    /// A file name that can't leave its folder or disguise itself: no path separators or "..",
    /// no control or bidi-override characters, not hidden, not absurdly long.
    static func safeName(_ raw: String, fallback: String = "item") -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }))
        .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        let ext = (cleaned as NSString).pathExtension
        let name = cleaned.count <= 120 || ext.isEmpty || ext.count > 10
            ? String(cleaned.prefix(120))
            : String((cleaned as NSString).deletingPathExtension.prefix(110)) + "." + ext
        return name.isEmpty ? fallback : name
    }

    /// A URL in `dir` for `name` (sanitized) that doesn't exist yet.
    static func unique(_ name: String, in dir: URL) -> URL? {
        let safe = safeName(name)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var url = dir.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return contains(dir, url) ? url : nil
    }

    static func contains(_ dir: URL, _ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == dir.standardizedFileURL.path
    }
}

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    /// The file lives in nxtch's own storage (dropped text, images, links, file promises) and is
    /// deleted with the item. Dropped files are only referenced.
    let owned: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// A temporary holding area for anything dragged onto the notch.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// The item being dragged out of the shelf (shows the Delete zone).
    @Published private(set) var draggingItemID: UUID?
    /// The current drag out ended on nxtch itself (shelf or Delete zone), not somewhere else.
    private var droppedInternally = false

    private let storage = AppFiles.dir("Shelf")

    init() {
        if let data = UserDefaults.standard.data(forKey: "shelfItems"),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = saved
        }
        prune()
        items.forEach(makeThumbnail)
    }

    var isEmpty: Bool { items.isEmpty }

    func add(_ url: URL, owned: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        items.removeAll { $0.path == url.path }
        let item = ShelfItem(id: UUID(), path: url.path, owned: owned)
        items.append(item)
        Log.shelf.info("added owned=\(owned, privacy: .public) count=\(self.items.count, privacy: .public)")
        makeThumbnail(item)
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        // Only ever delete nxtch's own copies, even if the saved list was tampered with.
        if item.owned, AppFiles.contains(storage, item.url) { try? FileManager.default.removeItem(at: item.url) }
        save()
    }

    func clear() { items.forEach(remove) }

    /// Drops items whose files were moved or deleted elsewhere.
    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    /// Puts the files on the clipboard: paste in Finder to copy them, ⌥⌘V to move them.
    func copyToClipboard(_ items: [ShelfItem]? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects((items ?? self.items).map { $0.url as NSURL })
    }

    func airDrop(_ items: [ShelfItem]? = nil) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: (items ?? self.items).map(\.url))
    }

    // MARK: Dragging out

    func beginDrag(_ item: ShelfItem) { draggingItemID = item.id }

    /// Shelf items are temporary: a successful drop anywhere else takes the item off the shelf.
    func finishDrag(_ item: ShelfItem, operation: NSDragOperation) {
        defer { draggingItemID = nil; droppedInternally = false }
        guard !droppedInternally, !operation.isEmpty, items.contains(where: { $0.id == item.id }) else { return }
        Log.shelf.info("dragged out op=\(operation.rawValue, privacy: .public); removed from shelf")
        remove(item)
    }

    /// A drop on the Delete zone. The only thing that can be dragged there is a shelf item.
    func deleteDragged() -> Bool {
        droppedInternally = true
        guard let item = items.first(where: { $0.id == draggingItemID }) else { return false }
        Log.shelf.info("deleted via drop zone")
        remove(item)
        return true
    }

    // MARK: Dropping in

    /// Accepts anything dragged onto the notch: files are referenced; images, links, text and
    /// file promises are saved into nxtch's storage.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // A shelf item dropped back onto the notch: nothing to add, and it stays on the shelf.
        if draggingItemID != nil { droppedInternally = true; return false }
        Log.shelf.info("drop providers=\(providers.count, privacy: .public)")
        providers.forEach(ingest)
        return !providers.isEmpty
    }

    private nonisolated func ingest(_ p: NSItemProvider) {
        let storage = AppFiles.dir("Shelf")
        let add: @Sendable (URL, Bool) -> Void = { url, owned in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.add(url, owned: owned) } }
        }
        let has = { (t: UTType) in p.hasItemConformingToTypeIdentifier(t.identifier) }
        let firstType = { (t: UTType) in p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: t) == true } }

        if has(.fileURL) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url, url.isFileURL { add(url, false) } }
        } else if let type = firstType(.image) ?? (has(.url) || has(.plainText) ? nil : firstType(.data)) {
            // Real data and file promises alike: the provider hands over a temporary file to copy.
            let suggested = p.suggestedName
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { tmp, _ in
                guard let tmp else { return }
                var name = suggested ?? tmp.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension { name += ".\(ext)" }
                if let dest = AppFiles.unique(name, in: storage), (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil {
                    add(dest, true)
                }
            }
        } else if has(.url) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let dest = AppFiles.unique((url.host() ?? "link") + ".webloc", in: storage),
                      let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0),
                      (try? data.write(to: dest, options: .withoutOverwriting)) != nil else { return }
                add(dest, true)
            }
        } else if has(.plainText) {
            _ = p.loadObject(ofClass: String.self) { text, _ in
                guard let text, !text.isEmpty else { return }
                let title = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? "text"
                guard let dest = AppFiles.unique(AppFiles.safeName(title, fallback: "text") + ".txt", in: storage),
                      (try? Data(text.utf8).write(to: dest, options: .withoutOverwriting)) != nil else { return }
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
