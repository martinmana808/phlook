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
}
