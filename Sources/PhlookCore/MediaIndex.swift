import Foundation
import GRDB

public final class MediaIndex {
    private let dbQueue: DatabaseQueue

    public init(dbPath: String) throws {
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT UNIQUE NOT NULL,
                    hash TEXT,
                    date_taken TEXT,
                    file_type TEXT,
                    width INTEGER,
                    height INTEGER,
                    last_scanned TEXT,
                    duration REAL
                );
            """)
            // Databases created before the duration column existed:
            let columns = try db.columns(in: "files").map(\.name)
            if !columns.contains("duration") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN duration REAL")
            }
        }
    }

    public func upsert(_ item: MediaItem) throws {
        try dbQueue.write { db in
            if var existing = try MediaItem.filter(MediaItem.Columns.path == item.path).fetchOne(db) {
                existing.hash = item.hash
                // Enrichment-preserving: a scan pass carries nil for fields only
                // the video enricher knows; never wipe an enriched value with nil.
                existing.dateTaken = item.dateTaken ?? existing.dateTaken
                existing.width = item.width ?? existing.width
                existing.height = item.height ?? existing.height
                existing.duration = item.duration ?? existing.duration
                existing.fileType = item.fileType
                existing.lastScanned = item.lastScanned
                try existing.update(db)
            } else {
                try item.insert(db)
            }
        }
    }

    public func item(forPath path: String) throws -> MediaItem? {
        try dbQueue.read { db in
            try MediaItem.filter(MediaItem.Columns.path == path).fetchOne(db)
        }
    }

    public func allItems(sortedByDateDescending desc: Bool = true) throws -> [MediaItem] {
        try dbQueue.read { db in
            let order = desc ? MediaItem.Columns.dateTaken.desc : MediaItem.Columns.dateTaken.asc
            return try MediaItem.order(order).fetchAll(db)
        }
    }

    public func deleteMissing(keepingPaths paths: Set<String>) throws {
        try dbQueue.write { db in
            for item in try MediaItem.fetchAll(db) where !paths.contains(item.path) {
                try item.delete(db)
            }
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in try MediaItem.fetchCount(db) }
    }

    /// Video rows the enricher still needs: never tried (duration NULL), or
    /// date missing on a readable video. The -1 unreadable sentinel is excluded.
    public func videosNeedingEnrichment() throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.fetchAll(db, sql: """
                SELECT * FROM files
                WHERE file_type = 'video'
                  AND (duration IS NULL OR (date_taken IS NULL AND duration >= 0))
            """)
        }
    }
}
