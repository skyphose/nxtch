import AppKit
import XCTest
@testable import Nxtch

// The rules that can be checked without a notch, audio or a pasteboard.

final class FileNameTests: XCTestCase {
    func testNameCannotLeaveItsFolder() {
        XCTAssertFalse(AppFiles.safeName("../../etc/passwd").contains("/"))
        XCTAssertFalse(AppFiles.safeName("a/b:c").contains(where: { "/:".contains($0) }))
    }

    func testNameCannotHideOrDisguiseItself() {
        XCTAssertFalse(AppFiles.safeName(".hidden").hasPrefix("."))
        // U+202E flips the text after it: "photo<U+202E>gpj.exe" displays as "photoexe.jpg".
        XCTAssertFalse(AppFiles.safeName("photo\u{202E}gpj.exe").unicodeScalars.contains("\u{202E}"))
        XCTAssertFalse(AppFiles.safeName("a\u{0007}b\nc").unicodeScalars.contains(where: { $0.value < 32 }))
    }

    func testEmptyNameFallsBack() {
        XCTAssertEqual(AppFiles.safeName("..."), "item")
        XCTAssertEqual(AppFiles.safeName("", fallback: "text"), "text")
    }

    func testLongNameKeepsItsExtension() {
        let name = AppFiles.safeName(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertLessThanOrEqual(name.count, 120)
        XCTAssertTrue(name.hasSuffix(".pdf"))
    }

    func testContainsOnlyAcceptsDirectChildren() {
        let dir = URL(fileURLWithPath: "/tmp/nxtch-test/Shelf", isDirectory: true)
        XCTAssertTrue(AppFiles.contains(dir, dir.appendingPathComponent("a.txt")))
        XCTAssertFalse(AppFiles.contains(dir, dir.appendingPathComponent("../other/a.txt")))
        XCTAssertFalse(AppFiles.contains(dir, dir.appendingPathComponent("sub/a.txt")))
        XCTAssertFalse(AppFiles.contains(dir, URL(fileURLWithPath: "/etc/passwd")))
    }

    func testUniqueNeverReturnsAnExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxtch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try XCTUnwrap(AppFiles.unique("note.txt", in: dir))
        try Data("x".utf8).write(to: first)
        let second = try XCTUnwrap(AppFiles.unique("note.txt", in: dir))
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(second.pathExtension, "txt")
        XCTAssertTrue(AppFiles.contains(dir, second))
    }
}

final class ClipboardTrimTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(ageDays: Double, pinned: Bool = false) -> ClipItem {
        ClipItem(id: UUID(), kind: .text, text: "x", date: now.addingTimeInterval(-ageDays * 86_400), pinned: pinned)
    }

    func testOldUnpinnedItemsAreDropped() {
        let (kept, dropped) = ClipboardStore.trimmed([item(ageDays: 1), item(ageDays: 8)], now: now)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(dropped.count, 1)
    }

    func testPinnedItemsSurviveAgeAndTheLimit() {
        var items = (0..<150).map { _ in item(ageDays: 0) }
        items.append(item(ageDays: 400, pinned: true))
        let (kept, dropped) = ClipboardStore.trimmed(items, now: now)
        XCTAssertEqual(kept.filter(\.pinned).count, 1)
        XCTAssertEqual(kept.filter { !$0.pinned }.count, ClipboardStore.unpinnedLimit)
        XCTAssertEqual(dropped.count, 50)
    }

    func testTheNewestAreTheOnesKept() {
        let items = (0..<120).map { item(ageDays: Double($0) / 1000) }   // newest first, as stored
        let (kept, _) = ClipboardStore.trimmed(items, now: now)
        XCTAssertEqual(kept.map(\.id), items.prefix(100).map(\.id))
    }
}

final class NowPlayingTests: XCTestCase {
    func testNoTitleMeansNothingPlaying() {
        XCTAssertNil(NowPlayingInfo(json: ["playing": true]))
        XCTAssertNil(NowPlayingInfo(json: ["title": ""]))
    }

    func testHostileValuesAreClamped() throws {
        let info = try XCTUnwrap(NowPlayingInfo(json: [
            "title": String(repeating: "t", count: 5000), "artist": "", "elapsed": -5.0,
            "duration": Double.infinity, "rate": 1e9, "timestamp": Double.nan,
        ]))
        XCTAssertEqual(info.title.count, 300)
        XCTAssertNil(info.artist)
        XCTAssertNil(info.elapsed)
        XCTAssertNil(info.duration)
        XCTAssertNil(info.timestamp)
        XCTAssertEqual(info.rate, 8)
    }

    func testPositionRunsForwardOnlyWhilePlaying() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var info = try XCTUnwrap(NowPlayingInfo(json: [
            "title": "song", "playing": true, "elapsed": 10.0, "duration": 60.0, "rate": 1.0, "timestamp": 1000.0,
        ]))
        XCTAssertEqual(try XCTUnwrap(info.position(at: start.addingTimeInterval(5))), 15, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.position(at: start.addingTimeInterval(500))), 60, accuracy: 0.001)   // never past the end
        info.isPlaying = false
        XCTAssertEqual(try XCTUnwrap(info.position(at: start.addingTimeInterval(5))), 10, accuracy: 0.001)
    }

    func testOwnership() throws {
        let info = try XCTUnwrap(NowPlayingInfo(json: ["title": "t", "bundle": "com.apple.WebKit.GPU", "parent": "com.apple.Safari"]))
        XCTAssertTrue(info.belongs(to: "com.apple.Safari"))
        XCTAssertFalse(info.belongs(to: "org.mozilla.firefox"))
    }
}

final class MixerLevelTests: XCTestCase {
    func testSnapsTo100WithinTwoPercent() {
        XCTAssertEqual(MixerModel.level(0.99, snap: true), 1)
        XCTAssertEqual(MixerModel.level(1.015, snap: true), 1)
        XCTAssertEqual(MixerModel.level(0.97, snap: true), 0.97)
    }

    func testShiftTurnsSnappingOff() {
        XCTAssertEqual(MixerModel.level(0.99, snap: false), 0.99)
    }

    func testStaysInRange() {
        XCTAssertEqual(MixerModel.level(-1, snap: true), 0)
        XCTAssertEqual(MixerModel.level(9, snap: false), MixerModel.maxVolume)
    }
}

final class MeterColourTests: XCTestCase {
    private func square(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        return image
    }

    func testPicksTheIconsHue() {
        let green = square(NSColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1)).vividColor
        XCTAssertEqual(green.hueComponent * 360, 137, accuracy: 12)
        let orange = square(NSColor(srgbRed: 0.95, green: 0.5, blue: 0.1, alpha: 1)).vividColor
        XCTAssertEqual(orange.hueComponent * 360, 28, accuracy: 12)
    }

    func testColourlessIconGivesWhite() {
        let grey = square(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)).vividColor
        XCTAssertEqual(grey.saturationComponent, 0, accuracy: 0.01)
        XCTAssertEqual(grey.brightnessComponent, 1, accuracy: 0.01)
    }
}

@MainActor
final class LayoutTests: XCTestCase {
    func testLeftEarGrowsWithPlayingAppsUpToFour() {
        let one = NotchViewModel.leftEarWidth(icons: 1)
        XCTAssertEqual(one, NotchViewModel.earWidth)
        XCTAssertGreaterThan(NotchViewModel.leftEarWidth(icons: 3), one)
        XCTAssertEqual(NotchViewModel.leftEarWidth(icons: 9), NotchViewModel.leftEarWidth(icons: 4))
        XCTAssertEqual(NotchViewModel.leftEarWidth(icons: 0), one)
    }

    func testShelfGrowsARowAtATimeUpToThree() {
        let h = NotchViewModel.shelfHeight
        XCTAssertEqual(h(0), h(4))            // empty and one full row are the same height
        XCTAssertGreaterThan(h(5), h(4))      // a fifth item starts row two
        XCTAssertGreaterThan(h(9), h(8))
        XCTAssertEqual(h(13), h(12))          // three rows is the most, then it scrolls
        XCTAssertEqual(h(200), h(12))
        // four tiles and the Delete zone fit across the open notch
        let n = CGFloat(NotchViewModel.shelfColumns)
        let row = n * NotchViewModel.shelfTileSize.width + (n - 1) * NotchViewModel.shelfSpacing
        XCTAssertLessThanOrEqual(row + 8 + 110, NotchViewModel.openWidth - 2 * (19 + 12))
    }
}
