import Testing
import Foundation
@testable import PhlookCore

struct ThumbnailCacheTests {
    @Test func generatesAndCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jpeg = root.appendingPathComponent("pic.jpg")
        try TestFixtures.writeJPEG(at: jpeg, width: 200, height: 200)

        let cache = ThumbnailCache(cacheDir: root.appendingPathComponent("thumbs"))
        let item = MediaItem(path: jpeg.path, hash: "deadbeef", dateTaken: nil,
                             fileType: "image", width: 200, height: 200, lastScanned: Date())
        let url = await cache.thumbnailURL(for: item, size: 128)
        let unwrapped = try #require(url)
        #expect(FileManager.default.fileExists(atPath: unwrapped.path))
        let again = await cache.thumbnailURL(for: item, size: 128)
        #expect(unwrapped == again)  // cache hit → same path
    }

    @Test func nilHashReturnsNil() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = ThumbnailCache(cacheDir: root.appendingPathComponent("thumbs"))
        let item = MediaItem(path: "/nonexistent.jpg", hash: nil, dateTaken: nil,
                             fileType: "image", width: 1, height: 1, lastScanned: Date())
        let url = await cache.thumbnailURL(for: item, size: 128)
        #expect(url == nil)
    }
}
