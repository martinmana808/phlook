import Testing
import Foundation
@testable import PhlookCore

struct MediaIndexTests {
    func makeTempIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("phlook.db").path)
    }

    @Test func upsertAndFetch() throws {
        let index = try makeTempIndex()
        let item = MediaItem(path: "/a/b/2024-01-02_03-04-05_IMG.heic", hash: "abc",
                             dateTaken: Date(timeIntervalSince1970: 1_700_000_000),
                             fileType: "image", width: 100, height: 200, lastScanned: Date())
        try index.upsert(item)
        let count = try index.count()
        #expect(count == 1)
        let fetched = try index.item(forPath: item.path)
        #expect(fetched?.width == 100)
    }

    @Test func upsertIsIdempotentOnPath() throws {
        let index = try makeTempIndex()
        var item = MediaItem(path: "/x.heic", hash: "1", dateTaken: nil,
                             fileType: "image", width: 1, height: 1, lastScanned: Date())
        try index.upsert(item)
        item.width = 999
        try index.upsert(item)
        let count = try index.count()
        #expect(count == 1)
        let fetched = try index.item(forPath: "/x.heic")
        #expect(fetched?.width == 999)
    }

    @Test func duplicateCandidatePathsFindsSharedSizeAndHash() throws {
        let index = try makeTempIndex()
        let a = MediaItem(path: "/a.jpg", hash: "h1", dateTaken: nil, fileType: "image",
                           width: nil, height: nil, lastScanned: Date(), fileSize: 100)
        let b = MediaItem(path: "/b.jpg", hash: "h1", dateTaken: nil, fileType: "image",
                           width: nil, height: nil, lastScanned: Date(), fileSize: 100)
        let c = MediaItem(path: "/c.jpg", hash: "h2", dateTaken: nil, fileType: "image",
                           width: nil, height: nil, lastScanned: Date(), fileSize: 200)
        try index.upsert(a); try index.upsert(b); try index.upsert(c)
        let candidates = Set(try index.duplicateCandidatePaths())
        #expect(candidates == ["/a.jpg", "/b.jpg"])
    }

    @Test func duplicateCandidatePathsExcludesNilHashOrSize() throws {
        let index = try makeTempIndex()
        let a = MediaItem(path: "/a.jpg", hash: nil, dateTaken: nil, fileType: "image",
                           width: nil, height: nil, lastScanned: Date(), fileSize: 100)
        let b = MediaItem(path: "/b.jpg", hash: "h1", dateTaken: nil, fileType: "image",
                           width: nil, height: nil, lastScanned: Date(), fileSize: nil)
        try index.upsert(a); try index.upsert(b)
        #expect(try index.duplicateCandidatePaths().isEmpty)
    }
}
