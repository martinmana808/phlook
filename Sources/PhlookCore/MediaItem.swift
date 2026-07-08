import Foundation
import GRDB

public struct MediaItem: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var path: String
    public var hash: String?
    public var dateTaken: Date?
    public var fileType: String   // "image" | "video"
    public var width: Int?
    public var height: Int?
    public var lastScanned: Date
    public var duration: Double?  // seconds; nil = unknown; -1 = unreadable sentinel
    public var fileSize: Int?
    public var modifiedAt: Date?
    public var hidden: Bool
    public var kindFlags: Int
    public var sceneFlags: Int

    public static let databaseTableName = "files"

    public enum Columns {
        public static let path = Column("path")
        public static let dateTaken = Column("date_taken")
    }

    enum CodingKeys: String, CodingKey {
        case id, path, hash
        case dateTaken = "date_taken"
        case fileType = "file_type"
        case width, height
        case lastScanned = "last_scanned"
        case duration
        case fileSize = "file_size"
        case modifiedAt = "modified_at"
        case hidden
        case kindFlags = "kind_flags"
        case sceneFlags = "scene_flags"
    }

    public init(id: Int64? = nil, path: String, hash: String?, dateTaken: Date?,
                fileType: String, width: Int?, height: Int?, lastScanned: Date,
                duration: Double? = nil, fileSize: Int? = nil, modifiedAt: Date? = nil,
                hidden: Bool = false, kindFlags: Int = 0, sceneFlags: Int = 0) {
        self.id = id; self.path = path; self.hash = hash; self.dateTaken = dateTaken
        self.fileType = fileType; self.width = width; self.height = height
        self.lastScanned = lastScanned; self.duration = duration
        self.fileSize = fileSize; self.modifiedAt = modifiedAt
        self.hidden = hidden; self.kindFlags = kindFlags; self.sceneFlags = sceneFlags
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension MediaItem: Identifiable {}   // id: Int64? (row id) — non-nil for fetched rows
