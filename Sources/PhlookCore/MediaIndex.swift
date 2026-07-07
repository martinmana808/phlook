import Foundation
import GRDB

public struct FileStamp: Equatable {
    public let size: Int
    public let modifiedAt: Date
    public init(size: Int, modifiedAt: Date) { self.size = size; self.modifiedAt = modifiedAt }

    public func matches(size: Int, modifiedAt: Date) -> Bool {
        self.size == size && abs(self.modifiedAt.timeIntervalSince(modifiedAt)) < 1.0
    }
}

public final class MediaIndex {
    private static let importTimestampFormatter = ISO8601DateFormatter()

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
                    duration REAL,
                    file_size INTEGER,
                    modified_at TEXT
                );
            """)
            // Databases created before the duration column existed:
            let columns = try db.columns(in: "files").map(\.name)
            if !columns.contains("duration") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN duration REAL")
            }

            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version < 2 {
                // v1 scanner stamped videos with file-creation dates; null them so
                // the enricher re-dates every video from real capture metadata.
                try db.execute(sql: "UPDATE files SET date_taken = NULL WHERE file_type = 'video'")
                try db.execute(sql: "PRAGMA user_version = 2")
            }
            if version < 3 {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS imports (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        device_name TEXT NOT NULL,
                        item_identifier TEXT NOT NULL,
                        imported_at TEXT NOT NULL,
                        UNIQUE(device_name, item_identifier)
                    );
                """)
                try db.execute(sql: "PRAGMA user_version = 3")
            }
            if version < 4 {
                let cols = try db.columns(in: "files").map(\.name)
                if !cols.contains("file_size") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN file_size INTEGER")
                }
                if !cols.contains("modified_at") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN modified_at TEXT")
                }
                try db.execute(sql: "PRAGMA user_version = 4")
            }
        }
    }

    public func upsert(_ item: MediaItem) throws {
        try dbQueue.write { db in
            if var existing = try MediaItem.filter(MediaItem.Columns.path == item.path).fetchOne(db) {
                if existing.hash != item.hash {
                    // Content changed: take the scan's values verbatim so the row
                    // re-enters the enrichment pending set (duration nil).
                    existing.dateTaken = item.dateTaken
                    existing.width = item.width
                    existing.height = item.height
                    existing.duration = item.duration
                } else {
                    // Same content: never wipe enriched values with a scan's nils.
                    existing.dateTaken = item.dateTaken ?? existing.dateTaken
                    existing.width = item.width ?? existing.width
                    existing.height = item.height ?? existing.height
                    existing.duration = item.duration ?? existing.duration
                }
                // Scan-authoritative in both branches: nil-coalescing is safe
                // because scan items always carry stamps, and enrichment
                // write-backs carry the row's own non-nil values.
                existing.fileSize = item.fileSize ?? existing.fileSize
                existing.modifiedAt = item.modifiedAt ?? existing.modifiedAt
                existing.hash = item.hash
                existing.fileType = item.fileType
                existing.lastScanned = item.lastScanned
                try existing.update(db)
            } else {
                try item.insert(db)
            }
        }
    }

    /// path → stamp for rows that have both fields (pre-v4 rows are omitted
    /// so they take the full-extract path once, which backfills them).
    public func allStamps() throws -> [String: FileStamp] {
        try dbQueue.read { db in
            var result: [String: FileStamp] = [:]
            let rows = try Row.fetchAll(db, sql:
                "SELECT path, file_size, modified_at FROM files WHERE file_size IS NOT NULL AND modified_at IS NOT NULL")
            for row in rows {
                let path: String = row["path"]
                let size: Int = row["file_size"]
                if let date = row["modified_at"] as Date? {
                    result[path] = FileStamp(size: size, modifiedAt: date)
                }
            }
            return result
        }
    }

    /// Test support: simulate a pre-v4 row.
    func nullStampsForTesting(path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE files SET file_size = NULL, modified_at = NULL WHERE path = ?",
                           arguments: [path])
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

    /// Remove rows for the given paths. Chunked to stay under SQLite's
    /// parameter limit on large selections.
    public func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            for chunk in stride(from: 0, to: paths.count, by: 500).map({
                Array(paths[$0..<min($0 + 500, paths.count)])
            }) {
                let placeholders = repeatElement("?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM files WHERE path IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
        }
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

    /// Idempotent: re-recording the same (device, identifier) is a no-op.
    public func recordImport(device: String, identifier: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO imports (device_name, item_identifier, imported_at) VALUES (?, ?, ?)",
                arguments: [device, identifier, Self.importTimestampFormatter.string(from: Date())])
        }
    }

    public func importedIdentifiers(device: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT item_identifier FROM imports WHERE device_name = ?",
                arguments: [device]))
        }
    }
}
