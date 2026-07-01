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
                    last_scanned TEXT
                );
            """)
        }
    }

    public func upsert(_ item: MediaItem) throws {
        try dbQueue.write { db in
            if var existing = try MediaItem.filter(MediaItem.Columns.path == item.path).fetchOne(db) {
                existing.hash = item.hash
                existing.dateTaken = item.dateTaken
                existing.fileType = item.fileType
                existing.width = item.width
                existing.height = item.height
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
}
