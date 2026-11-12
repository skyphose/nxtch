import AppKit
import SwiftUI

/// The About window: the icon, the installed version, the way to updates, and who made it.
/// nxtch has no network code, so updates are a reminder and a link to the releases page, opened
/// in your browser.
@MainActor
enum About {
    static let repo = URL(string: "https://github.com/skyphose/nxtch")!
    static let releases = URL(string: "https://github.com/skyphose/nxtch/releases/latest")!
    static let author = URL(string: "https://skyphose.com")!

    /// "0.6.2 (10)" from the app's Info.plist.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "About nxtch"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: AboutView())
            w.setContentSize(w.contentView?.fittingSize ?? NSSize(width: 300, height: 360))
            window = w
        }
        window?.center()
        // nxtch has no Dock icon and is never the active app, so bring the window forward by hand.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.top, 34)
            Text("nxtch").font(.system(size: 22, weight: .semibold)).padding(.top, 10)
            Text("Version \(About.version)")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text("Per-app volume, now playing, a file shelf and clipboard history, in the notch.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            // A reminder and a link, nothing more: the app never looks for a newer version.
            VStack(spacing: 4) {
                Text("nxtch doesn't check for updates. Look for a newer version now and then:")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Latest release on GitHub") { NSWorkspace.shared.open(About.releases) }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            .padding(.top, 18)

            Divider().padding(.vertical, 16)

            HStack(spacing: 4) {
                Text("Made by")
                Button("skyphose") { NSWorkspace.shared.open(About.author) }
                    .buttonStyle(.link)
                Text("·")
                Button("Source") { NSWorkspace.shared.open(About.repo) }
                    .buttonStyle(.link)
                Text("·  MIT license")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .frame(width: 300)
    }
}
