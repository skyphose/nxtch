import AppKit
import SwiftUI

/// Clipboard tab: search field and history. Click copies; Return (or the context menu) pastes into
/// the app you were using.
struct ClipboardTab: View {
    @ObservedObject var store: ClipboardStore
    let enabled: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("", text: $store.query, prompt: Text("Search").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit {
                        let items = store.visible
                        if store.selection < items.count { store.paste(items[store.selection]) }
                    }
                    .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
                if !enabled { Text("Paused").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))

            let items = store.visible
            if items.isEmpty {
                Text(store.query.isEmpty ? "Nothing copied yet" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, store: store, selected: index == store.selection).id(item.id)
                            }
                        }
                    }
                    .onChange(of: store.selection) { _, i in if i < items.count { proxy.scrollTo(items[i].id) } }
                }
            }
        }
        .padding(.top, 2)
        // ⌃⌥V makes the panel key; put the cursor in the search field.
        .onReceive(NotificationCenter.default.publisher(for: .nxtchFocusSearch)) { _ in searchFocused = true }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let selected: Bool

    /// App icons by bundle ID. Looking them up on every redraw is a disk hit per row.
    @MainActor private static var icons: [String: NSImage] = [:]

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 22, height: 22)
            if item.kind == .image, let img = store.thumbnail(for: item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 24).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text(item.preview).font(.system(size: 12)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.justCopied == item.id {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
            } else {
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: NotchViewModel.clipRowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? .white.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.copy(item) }
        .contextMenu {
            Button("Paste") { store.paste(item) }
            Button("Copy") { store.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Divider()
            Button("Delete") { store.delete(item) }
        }
    }

    @ViewBuilder private var leading: some View {
        if let icon = Self.icon(item.sourceBundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: item.kind == .files ? "doc.on.doc" : item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private static func icon(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let cached = icons[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 22, height: 22)
        icons[id] = icon
        return icon
    }
}
