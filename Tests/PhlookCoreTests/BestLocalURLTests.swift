import Testing
import Foundation
@testable import PhlookCore

struct BestLocalURLTests {
    private func makeTempFile(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func returnsOriginalWhenItExists() throws {
        let original = try makeTempFile(name: "orig.jpg")
        let item = MediaItem(path: original.path, hash: nil, dateTaken: nil,
                              fileType: "image", width: nil, height: nil, lastScanned: Date(),
                              smallPath: nil)
        #expect(item.bestLocalURL() == original)
    }

    @Test func fallsBackToSmallWhenOriginalMissing() throws {
        let small = try makeTempFile(name: "small.jpg")
        let missingOriginal = "/nonexistent/path/\(UUID().uuidString)/orig.jpg"
        let item = MediaItem(path: missingOriginal, hash: nil, dateTaken: nil,
                              fileType: "image", width: nil, height: nil, lastScanned: Date(),
                              smallPath: small.path)
        #expect(item.bestLocalURL() == small)
    }

    @Test func fallsBackToOriginalWhenBothMissing() throws {
        let missingOriginal = "/nonexistent/path/\(UUID().uuidString)/orig.jpg"
        let missingSmall = "/nonexistent/path/\(UUID().uuidString)/small.jpg"
        let item = MediaItem(path: missingOriginal, hash: nil, dateTaken: nil,
                              fileType: "image", width: nil, height: nil, lastScanned: Date(),
                              smallPath: missingSmall)
        #expect(item.bestLocalURL() == URL(fileURLWithPath: missingOriginal))
    }
}
