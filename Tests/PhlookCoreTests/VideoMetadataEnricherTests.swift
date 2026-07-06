import Testing
import Foundation
@testable import PhlookCore

struct VideoMetadataEnricherTests {
    func makeWorld() throws -> (dir: URL, index: MediaIndex) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try MediaIndex(dbPath: dir.appendingPathComponent("test.db").path)
        return (dir, index)
    }

    func upsertVideoRow(_ index: MediaIndex, path: String) throws {
        try index.upsert(MediaItem(path: path, hash: "h", dateTaken: nil,
                                   fileType: "video", width: nil, height: nil,
                                   lastScanned: Date()))
    }

    @Test func enrichesRealVideoWithDurationDateAndDimensions() async throws {
        let (dir, index) = try makeWorld()
        let movie = dir.appendingPathComponent("clip.mov")
        try await TestFixtures.writeQuickTimeMovie(
            at: movie, duration: 1.0, width: 64, height: 48,
            creationDate: "2026-03-08T13:56:58-0300")
        try upsertVideoRow(index, path: movie.path)

        let count = await VideoMetadataEnricher().enrich(index: index)

        #expect(count == 1)
        let item = try #require(try index.item(forPath: movie.path))
        let duration = try #require(item.duration)
        #expect(abs(duration - 1.0) < 0.35)
        #expect(item.width == 64)
        #expect(item.height == 48)
        // 13:56:58 at -0300 == 16:56:58 UTC
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let taken = try #require(item.dateTaken)
        #expect(abs(taken.timeIntervalSince(expected)) < 1)
    }

    @Test func corruptVideoGetsSentinelAndIsNotRetried() async throws {
        let (dir, index) = try makeWorld()
        let bad = dir.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: bad)
        try upsertVideoRow(index, path: bad.path)

        let first = await VideoMetadataEnricher().enrich(index: index)
        #expect(first == 1)
        #expect(try #require(try index.item(forPath: bad.path)).duration == -1)

        let second = await VideoMetadataEnricher().enrich(index: index)
        #expect(second == 0)   // sentinel excludes it from the pending query
    }

    @Test func enrichedVideoIsNotReprocessed() async throws {
        let (dir, index) = try makeWorld()
        let movie = dir.appendingPathComponent("clip.mov")
        try await TestFixtures.writeQuickTimeMovie(at: movie, duration: 1.0,
                                                   creationDate: "2026-03-08T13:56:58-0300")
        try upsertVideoRow(index, path: movie.path)
        _ = await VideoMetadataEnricher().enrich(index: index)
        let second = await VideoMetadataEnricher().enrich(index: index)
        #expect(second == 0)
    }

    @Test func imagesAreNeverPending() throws {
        let (_, index) = try makeWorld()
        try index.upsert(MediaItem(path: "/x/photo.jpg", hash: "h", dateTaken: nil,
                                   fileType: "image", width: 10, height: 10,
                                   lastScanned: Date()))
        #expect(try index.videosNeedingEnrichment().isEmpty)
    }
}
