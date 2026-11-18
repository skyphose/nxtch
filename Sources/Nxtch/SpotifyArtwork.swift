import AppKit
import CryptoKit

/// Spotify's cover for the current song, read from Spotify's own cache on this Mac.
///
/// macOS has the cover too, but it only hands it over through a callback that the now-playing
/// helper (osascript) can't receive. Spotify, meanwhile, keeps every cover it has shown in a
/// Chromium disk cache: one file per image, named after a hash of the image's address, with the
/// JPEG stored as is. Spotify tells the helper the address, and nxtch reads the file. Nothing is
/// downloaded. A cover Spotify hasn't shown yet simply isn't there, and the card shows the app's
/// icon instead.
enum SpotifyArtwork {
    /// Spotify has kept its cache in both of these: Browser/ now, Default/ in older versions.
    private static let caches = ["Browser", "Default"].map {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.spotify.client/\($0)/Cache/Cache_Data")
    }
    /// Spotify fetches the same cover from more than one server, and the cache keys on the server.
    private static let hosts = ["i.scdn.co", "image-cdn-fa.spotifycdn.com", "image-cdn-ak.spotifycdn.com"]
    /// How Spotify's cache names a cover: the page it was shown in, then the image address.
    private static let keyPrefix = "1/0/_dk_https://spotify.com https://spotify.com "
    /// The same cover at different sizes, roughly largest first. 64 pixels comes last.
    private static let sizes = ["0000b273", "0000e1a3", "00001e02", "0000aa54", "00004851"]

    /// Only Spotify's own image addresses, so a stray string can't point nxtch at another file.
    static func validURL(_ s: String) -> String? {
        guard let prefix = hosts.map({ "https://\($0)/image/" }).first(where: s.hasPrefix), s.count <= prefix.count + 64 else { return nil }
        let id = s.dropFirst(prefix.count)
        return id.allSatisfy(\.isHexDigit) && id.count >= 16 ? s : nil
    }

    /// The cache file for an image address.
    static func cacheFileName(for url: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((keyPrefix + url).utf8))
        let hash = digest.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return String(format: "%016llx_0", hash)
    }

    /// The same cover at each size and from each server Spotify uses, the address it gave first.
    static func candidates(for url: String) -> [String] {
        guard let slash = url.range(of: "/image/ab67616d"), url.distance(from: slash.upperBound, to: url.endIndex) > 8 else { return [url] }
        let id = url[url.index(slash.upperBound, offsetBy: 8)...]
        var out = [url]
        for size in sizes { for host in hosts {
            let u = "https://\(host)/image/ab67616d\(size)\(id)"
            if !out.contains(u) { out.append(u) }
        } }
        return out
    }

    /// Seconds between looks. Spotify can take over a minute to write a new song's cover to its
    /// cache (measured: one first showed up after about 70 s), so nxtch keeps looking for ~90 s.
    /// Each look is 15 file names checked: next to nothing.
    private static let retryDelays: [Double] = [1, 2, 3, 5, 10, 10, 15, 20, 25]

    /// Reads the cover off the main thread, and looks again while `wanted` says the song is still on.
    static func load(_ url: String, attempt: Int = 0, wanted: @escaping @MainActor () -> Bool,
                     done: @escaping @MainActor (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let image = candidates(for: url).lazy.compactMap(read).first
            onMain {
                guard wanted() else { return }
                Log.audio.info("cover \(image == nil ? "not cached" : "found", privacy: .public) try=\(attempt, privacy: .public)")
                if image == nil, attempt < retryDelays.count {
                    _ = after(retryDelays[attempt]) { load(url, attempt: attempt + 1, wanted: wanted, done: done) }
                } else {
                    done(image)
                }
            }
        }
    }

    private static func read(_ url: String) -> NSImage? {
        let name = cacheFileName(for: url)
        guard let data = caches.lazy.compactMap({ try? Data(contentsOf: $0.appendingPathComponent(name), options: .mappedIfSafe) }).first,
              data.count < 4 << 20,
              data.range(of: Data(url.utf8)) != nil,   // the entry really is this image
              let start = data.range(of: Data([0xFF, 0xD8, 0xFF]))?.lowerBound else { return nil }
        // The JPEG runs from its start marker. What follows it in the file is ignored by the decoder.
        return NSImage(data: data[start...])
    }
}
