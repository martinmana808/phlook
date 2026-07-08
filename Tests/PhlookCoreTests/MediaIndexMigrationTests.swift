import Testing
import Foundation
import GRDB
@testable import PhlookCore

struct MediaIndexMigrationTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
    }

    func makeItem(path: String = "/x/a.mov", duration: Double? = nil,
                  dateTaken: Date? = nil, width: Int? = nil, height: Int? = nil) -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: dateTaken, fileType: "video",
                  width: width, height: height, lastScanned: Date(), duration: duration)
    }

    @Test func freshDatabaseStoresDuration() throws {
        let index = try MediaIndex(dbPath: tempDBPath())
        try index.upsert(makeItem(duration: 12.5))
        let item = try #require(try index.item(forPath: "/x/a.mov"))
        #expect(item.duration == 12.5)
    }

    @Test func preExistingDatabaseGainsDurationColumn() throws {
        // Simulate a v1 database created before the duration column existed.
        let path = tempDBPath()
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
                    last_scanned TEXT
                );
            """)
            try db.execute(sql: """
                INSERT INTO files (path, hash, file_type, last_scanned)
                VALUES ('/old/row.jpg', 'h', 'image', '2026-01-01T00:00:00Z')
            """)
        }
        try queue.close()

        let index = try MediaIndex(dbPath: path)   // migration must ALTER, not fail
        let old = try #require(try index.item(forPath: "/old/row.jpg"))
        #expect(old.duration == nil)               // old row survives, duration nil
        try index.upsert(makeItem(duration: 3.0))  // new column is writable
        #expect(try #require(try index.item(forPath: "/x/a.mov")).duration == 3.0)
    }

    @Test func migrationIsIdempotent() throws {
        let path = tempDBPath()
        _ = try MediaIndex(dbPath: path)
        _ = try MediaIndex(dbPath: path)   // second open must not throw
    }

    @Test func freshDatabaseDefaultsSceneFlagsToZero() throws {
        let index = try MediaIndex(dbPath: tempDBPath())
        try index.upsert(makeItem())
        let item = try #require(try index.item(forPath: "/x/a.mov"))
        #expect(item.sceneFlags == 0)
    }

    @Test func preV6DatabaseGainsSceneFlagsColumnAndSentinel() throws {
        // Simulate a pre-v6 database (has kind_flags but not scene_flags).
        let path = tempDBPath()
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
                    kind_flags INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: """
                INSERT INTO files (path, hash, file_type, last_scanned)
                VALUES ('/old/photo.jpg', 'h', 'image', '2026-01-01T00:00:00Z')
            """)
            try db.execute(sql: """
                INSERT INTO files (path, hash, file_type, last_scanned)
                VALUES ('/old/movie.mov', 'h', 'video', '2026-01-01T00:00:00Z')
            """)
            try db.execute(sql: "PRAGMA user_version = 5")
        }
        try queue.close()

        let index = try MediaIndex(dbPath: path)   // migration must ALTER + backfill sentinel
        let photo = try #require(try index.item(forPath: "/old/photo.jpg"))
        #expect(photo.sceneFlags == -1)             // image: unknown, needs classification
        let movie = try #require(try index.item(forPath: "/old/movie.mov"))
        #expect(movie.sceneFlags == 0)               // video: never classified
        #expect(try index.scenesNeedingClassification().map(\.path) == ["/old/photo.jpg"])
    }

    @Test func upsertPreservesEnrichedFieldsAgainstNilScan() throws {
        let index = try MediaIndex(dbPath: tempDBPath())
        let enrichedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try index.upsert(makeItem(duration: 30.0, dateTaken: enrichedDate, width: 1920, height: 1080))
        // Next scan pass knows nothing about video metadata — all nil:
        try index.upsert(makeItem())
        let item = try #require(try index.item(forPath: "/x/a.mov"))
        #expect(item.duration == 30.0)
        #expect(item.dateTaken == enrichedDate)
        #expect(item.width == 1920)
        #expect(item.height == 1080)
    }
}
