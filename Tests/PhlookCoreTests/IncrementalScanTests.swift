import Testing
import Foundation
@testable import PhlookCore

struct IncrementalScanTests {
    func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func unchangedFileIsNotReExtracted() async throws {
        let root = try makeRoot()
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("a.jpg"), width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        // Corrupt the stored hash as a sentinel: a re-extract would overwrite it.
        let index = service.mediaIndex
        var row = try #require(try index.item(forPath: root.appendingPathComponent("a.jpg").path))
        let sentinel = "SENTINEL"
        row.hash = sentinel
        // Carry the row's stamps: a stamp-less upsert would take the
        // changed-hash branch and null them, forcing a re-extract for the
        // wrong reason.
        try index.upsert(MediaItem(path: row.path, hash: sentinel, dateTaken: row.dateTaken,
                                   fileType: row.fileType, width: row.width, height: row.height,
                                   lastScanned: row.lastScanned, duration: row.duration,
                                   fileSize: row.fileSize, modifiedAt: row.modifiedAt))

        _ = try service.reindex()   // size+mtime unchanged → must skip extraction
        let after = try #require(try index.item(forPath: row.path))
        #expect(after.hash == sentinel)
    }

    @Test func touchedFileIsReExtracted() async throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        // Rewrite with different content AND a different mtime.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try TestFixtures.writeJPEG(at: url, width: 32, height: 32)

        _ = try service.reindex()
        let after = try #require(try service.mediaIndex.item(forPath: url.path))
        #expect(after.width == 32)   // fresh extraction picked up the new dimensions
    }

    @Test func newAndRemovedFilesStillWork() throws {
        let root = try makeRoot()
        let a = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: a, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        try FileManager.default.removeItem(at: a)
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("b.jpg"), width: 16, height: 16)
        _ = try service.reindex()

        #expect(try service.mediaIndex.item(forPath: a.path) == nil)
        #expect(try service.mediaIndex.item(forPath: root.appendingPathComponent("b.jpg").path) != nil)
    }

    @Test func rowsWithoutStampsReExtractOnceThenStabilize() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        // Simulate a pre-v4 row: null the stamps directly.
        try service.mediaIndex.nullStampsForTesting(path: url.path)
        #expect(try service.mediaIndex.allStamps()[url.path] == nil)   // omitted when nil

        _ = try service.reindex()   // backfills stamps via full extract
        #expect(try service.mediaIndex.allStamps()[url.path] != nil)
    }

    @Test func stampsSurviveEnrichmentStyleUpsert() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()
        let index = service.mediaIndex

        var row = try #require(try index.item(forPath: url.path))
        row.duration = 5   // enrichment-style write-back keeps same hash
        try index.upsert(row)
        #expect(try index.allStamps()[url.path] != nil)
    }
}
