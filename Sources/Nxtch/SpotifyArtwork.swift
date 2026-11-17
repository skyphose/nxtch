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
    private static let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.spotify.client/Default/Cache/Cache_Data")
    /// How Spotify's cache names a cover: the page it was shown in, then the image address.
    private static let keyPrefix = "1/0/_dk_https://spotify.com https://spotify.com "
    /// The same cover at different sizes: 640, 300, an in-between one, then 64 pixels.
    private static let sizes = ["0000b273", "00001e02", "0000e1a3", "00004851"]

    /// Only Spotify's own image addresses, so a stray string can't point nxtch at another file.
    static func validURL(_ s: String) -> String? {
        let prefix = "https://i.scdn.co/image/"
        guard s.hasPrefix(prefix), s.count <= prefix.count + 64 else { return nil }
        let id = s.dropFirst(prefix.count)
        return id.allSatisfy(\.isHexDigit) && id.count >= 16 ? s : nil
    }

    /// The cache file for an image address.
    static func cacheFileName(for url: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((keyPrefix + url).utf8))
        let hash = digest.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return String(format: "%016llx_0", hash)
    }

    /// The same cover at each size Spotify uses, largest first.
    static func candidates(for url: String) -> [String] {
        let prefix = "https://i.scdn.co/image/ab67616d"
        guard url.hasPrefix(prefix), url.count >= prefix.count + 8 else { return [url] }
        let id = url.dropFirst(prefix.count + 8)
        return [url] + sizes.map { prefix + $0 + id }.filter { $0 != url }
    }

    /// Reads the cover off the main thread. Tries again a moment later, since Spotify may still be
    /// fetching the cover when the song changes.
    static func load(_ url: String, attempt: Int = 0, done: @escaping @MainActor (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let image = candidates(for: url).lazy.compactMap(read).first
            onMain {
                if image == nil, attempt < 3 {
                    _ = after(Double(attempt + 1)) { load(url, attempt: attempt + 1, done: done) }
                } else {
                    done(image)
                }
            }
        }
    }

    private static func read(_ url: String) -> NSImage? {
        let file = cache.appendingPathComponent(cacheFileName(for: url))
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 4 << 20,
              data.range(of: Data(url.utf8)) != nil,   // the entry really is this image
              let start = data.range(of: Data([0xFF, 0xD8, 0xFF]))?.lowerBound else { return nil }
        // The JPEG runs from its start marker. What follows it in the file is ignored by the decoder.
        return NSImage(data: data[start...])
    }
}
