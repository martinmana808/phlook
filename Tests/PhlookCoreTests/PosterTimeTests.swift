import Testing
import Foundation
import GRDB
@testable import PhlookCore

struct PosterTimeTests {
    func makeIndex() throws -> MediaIndex {
        try MediaIndex(dbPath: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path)
    }
    func mkItem(_ path: String, fileType: String = "image") -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: nil, fileType: fileType,
                  width: nil, height: nil, lastScanned: Date())
    }

    @Test func freshDatabaseDefaultsPosterTimeToNil() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.heic"))
        let item = try #require(try index.item(forPath: "/a.heic"))
        #expect(item.posterTime == nil)
    }

    @Test func preExistingDatabaseGainsPosterTimeColumn() throws {
        // Simulate a pre-v7 database (has scene_flags but not poster_time).
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT UNIQUE NOT NULL,
                    hash TEXT,
                    date_taken TEXT,
                    file_type TEXT,
                    width INTEGER,
                    height INTEGER,
                    last_scanned TEXT,
                    duration REAL,
                    file_size INTEGER,
                    modified_at TEXT,
                    hidden INTEGER NOT NULL DEFAULT 0,
                    kind_flags INTEGER NOT NULL DEFAULT 0,
                    scene_flags INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: """
                INSERT INTO files (path, hash, file_type, last_scanned)
                VALUES ('/old/photo.heic', 'h', 'image', '2026-01-01T00:00:00Z')
            """)
            try db.execute(sql: "PRAGMA user_version = 6")
        }
        try queue.close()

        let index = try MediaIndex(dbPath: path)   // migration must ALTER, not fail
        let old = try #require(try index.item(forPath: "/old/photo.heic"))
        #expect(old.posterTime == nil)
        try index.setPosterTime(path: "/old/photo.heic", time: 0.5)
        #expect(try #require(try index.item(forPath: "/old/photo.heic")).posterTime == 0.5)
    }

    @Test func setPosterTimeRoundTripAndClear() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.heic"))
        try index.setPosterTime(path: "/a.heic", time: 1.25)
        #expect(try #require(try index.item(forPath: "/a.heic")).posterTime == 1.25)
        try index.setPosterTime(path: "/a.heic", time: nil)
        #expect(try #require(try index.item(forPath: "/a.heic")).posterTime == nil)
    }

    @Test func rescanNeverClearsPosterTime() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.heic"))
        try index.setPosterTime(path: "/a.heic", time: 2.0)
        try index.upsert(mkItem("/a.heic"))          // same-hash scan pass
        #expect(try #require(try index.item(forPath: "/a.heic")).posterTime == 2.0)
        var changed = mkItem("/a.heic"); changed.hash = "different"
        try index.upsert(changed)                    // changed-hash pass
        #expect(try #require(try index.item(forPath: "/a.heic")).posterTime == 2.0)
    }
}
