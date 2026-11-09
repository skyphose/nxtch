import AppKit
import SwiftUI

/// Clipboard tab: search field + history. Click copies; Return (or the context menu) pastes into
/// the app you were using.
struct ClipboardTab: View {
    @ObservedObject var store: ClipboardStore
    let enabled: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                SearchField(store: store)
                if !enabled {
                    Text("Paused").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))

            let items = store.visible
            if items.isEmpty {
                Text(store.query.isEmpty ? "Copy something and it will show up here" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, store: store, selected: index == store.selection)
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: store.selection) { _, i in
                        if i < items.count { proxy.scrollTo(items[i].id) }
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 22, height: 22)
            if item.kind == .image, let img = store.image(for: item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text("\(Int(img.size.width))×\(Int(img.size.height))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(item.preview).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
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
        if let id = item.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: item.kind == .files ? "doc.on.doc" : item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// AppKit text field so we control focus and arrow/Return/Esc handling.
private struct SearchField: NSViewRepresentable {
    @ObservedObject var store: ClipboardStore

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 12)
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(
            string: "Search clipboard  ·  ⌃⌥V", attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35),
                                                              .font: NSFont.systemFont(ofSize: 12)])
        f.delegate = context.coordinator
        context.coordinator.field = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != store.query { f.stringValue = store.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let store: ClipboardStore
        weak var field: NSTextField?
        private var observer: Any?

        init(store: ClipboardStore) {
            self.store = store
            super.init()
            // When the panel becomes key (⌃⌥V), put the cursor in the search field.
            observer = NotificationCenter.default.addObserver(forName: .nxtchFocusSearch, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let f = self?.field else { return }
                    f.window?.makeFirstResponder(f)
                }
            }
        }

        func controlTextDidChange(_ note: Notification) {
            store.query = field?.stringValue ?? ""
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): store.moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)): store.moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                let items = store.visible
                if store.selection < items.count { store.paste(items[store.selection]) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if store.query.isEmpty {
                    NotificationCenter.default.post(name: .nxtchRequestClose, object: nil)
                } else {
                    store.query = ""
                }
                return true
            default: return false
            }
        }
    }
}

extension Notification.Name {
    static let nxtchFocusSearch = Notification.Name("nxtchFocusSearch")
}
