import Testing
import Foundation
@testable import PhlookCore

struct LibraryScannerTests {
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
}
