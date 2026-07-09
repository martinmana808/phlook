import Testing
import Foundation
@testable import PhlookCore

struct LibraryScannerTests {
    @Test func underscorePrefixedFoldersAreNotIndexed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A real library file at the root…
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("keep.jpg"), width: 16, height: 16)
        // …and an excluded archive folder with media inside (+ a nested subdir).
        let archive = root.appendingPathComponent("_Todas las fotos de mi vida")
        let nested = archive.appendingPathComponent("2017")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: archive.appendingPathComponent("old.jpg"), width: 16, height: 16)
        try TestFixtures.writeJPEG(at: nested.appendingPathComponent("older.jpg"), width: 16, height: 16)
        // A normal (non-underscore) subfolder IS still indexed.
        let normal = root.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: normal.appendingPathComponent("trip.jpg"), width: 16, height: 16)

        let items = try LibraryScanner(root: root).scan()
        let names = Set(items.map { ($0.path as NSString).lastPathComponent })
        #expect(names.contains("keep.jpg"))
        #expect(names.contains("trip.jpg"))
        #expect(!names.contains("old.jpg"))
        #expect(!names.contains("older.jpg"))
    }

    func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: dir.appendingPathComponent("sample.jpg"), width: 64, height: 48)
        try "hello".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func scanFindsImageWithDimensions() throws {
        let items = try LibraryScanner(root: makeRoot()).scan()
        let image = try #require(items.first { $0.path.hasSuffix("sample.jpg") })
        #expect(image.fileType == "image")
        #expect(image.width == 64)
        #expect(image.height == 48)
        #expect(image.hash != nil)
        #expect(image.dateTaken != nil) // falls back to file creation date
    }

    @Test func scanIgnoresNonMedia() throws {
        let items = try LibraryScanner(root: makeRoot()).scan()
        #expect(!items.contains { $0.path.hasSuffix(".txt") })
    }

    @Test func scanSkipsHiddenPhlookCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: dir.appendingPathComponent("real.jpg"), width: 10, height: 10)
        let cache = dir.appendingPathComponent(".phlook/thumbnails")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: cache.appendingPathComponent("abc_160.png"), width: 8, height: 8)
        let items = try LibraryScanner(root: dir).scan()
        #expect(items.contains { $0.path.hasSuffix("real.jpg") })
        #expect(!items.contains { $0.path.contains(".phlook") })
    }

    @Test func scanClassifiesVideoByExtension() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Non-encoded .mov: assert classification + that a non-media video file doesn't crash scan.
        try Data([0x00, 0x00, 0x00, 0x18]).write(to: dir.appendingPathComponent("clip.mov"))
        let items = try LibraryScanner(root: dir).scan()
        let video = try #require(items.first { $0.path.hasSuffix("clip.mov") })
        #expect(video.fileType == "video")
        #expect(video.hash != nil)
    }

    @Test func fullHashIsDeterministicAndSizeSensitive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        let c = dir.appendingPathComponent("c.bin")
        let payload = Data(repeating: 0x42, count: 5 * 1_048_576) // > one read-chunk
        try payload.write(to: a)
        try payload.write(to: b)
        try Data(repeating: 0x43, count: 5 * 1_048_576).write(to: c)
        let hashA = LibraryScanner.fullHash(a)
        let hashB = LibraryScanner.fullHash(b)
        let hashC = LibraryScanner.fullHash(c)
        #expect(hashA != nil)
        #expect(hashA == hashB)
        #expect(hashA != hashC)
    }
}
