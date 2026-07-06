import Testing
import Foundation
import GRDB
@testable import PhlookCore

struct EnrichmentIntegrationTests {
    @Test func scannedVideoGetsCaptureDateFromEnricherAndSurvivesRescan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await TestFixtures.writeQuickTimeMovie(
            at: root.appendingPathComponent("clip.mov"), duration: 1.0,
            creationDate: "2026-03-08T13:56:58-0300")
        let service = IndexingService(root: root)

        _ = try service.reindex()                 // scanner: video date must be nil
        _ = await service.enrichVideos()          // enricher: date from QT metadata
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let afterEnrich = try #require(try service.items().first)
        let taken = try #require(afterEnrich.dateTaken)
        #expect(abs(taken.timeIntervalSince(expected)) < 1)

        _ = try service.reindex()                 // rescan must NOT stomp the date
        let afterRescan = try #require(try service.items().first)
        #expect(afterRescan.dateTaken == taken)
    }

    @Test func userVersion2BackfillNullsPoisonedVideoDates() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT UNIQUE NOT NULL,
                    hash TEXT, date_taken TEXT, file_type TEXT, width INTEGER,
                    height INTEGER, last_scanned TEXT, duration REAL
                );
            """)
            try db.execute(sql: """
                INSERT INTO files (path, hash, date_taken, file_type, last_scanned, duration)
                VALUES ('/v.mov', 'h', '2026-01-01T00:00:00Z', 'video', '2026-01-01T00:00:00Z', 5.0),
                       ('/p.jpg', 'h', '2026-01-01T00:00:00Z', 'image', '2026-01-01T00:00:00Z', NULL)
            """)
        }
        try queue.close()

        let index = try MediaIndex(dbPath: path)  // migration runs the backfill
        #expect(try #require(try index.item(forPath: "/v.mov")).dateTaken == nil)   // video nulled
        #expect(try #require(try index.item(forPath: "/p.jpg")).dateTaken != nil)   // image untouched
        #expect(try index.videosNeedingEnrichment().count == 1)                     // re-pending
        _ = try MediaIndex(dbPath: path)          // second open: no re-null (user_version guard)
    }

    @Test func changedHashResetsEnrichmentAtSamePath() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
        let index = try MediaIndex(dbPath: path)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try index.upsert(MediaItem(path: "/v.mov", hash: "old", dateTaken: date,
                                   fileType: "video", width: 100, height: 100,
                                   lastScanned: Date(), duration: 9.0))
        // Same path, NEW content (different hash), scan-style nils:
        try index.upsert(MediaItem(path: "/v.mov", hash: "new", dateTaken: nil,
                                   fileType: "video", width: nil, height: nil,
                                   lastScanned: Date()))
        let item = try #require(try index.item(forPath: "/v.mov"))
        #expect(item.duration == nil)
        #expect(item.dateTaken == nil)
        #expect(try index.videosNeedingEnrichment().count == 1)
    }
}
