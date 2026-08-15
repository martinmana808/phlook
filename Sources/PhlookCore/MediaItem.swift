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
    public var posterTime: Double?
    public var archivedHash: String?   // sha256 of the master, set only after SSD read-back verify
    public var archivedAt: Date?       // when the SSD copy was verified
    public var smallPath: String?      // path to the local 10% version (nil = not made yet)
    public var curated: Bool
    public var protected: Bool
    public var ssdRelPath: String?

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
        case posterTime = "poster_time"
        case archivedHash = "archived_hash"
        case archivedAt = "archived_at"
        case smallPath = "small_path"
        case curated
        case protected
        case ssdRelPath = "ssd_rel_path"
    }

    public init(id: Int64? = nil, path: String, hash: String?, dateTaken: Date?,
                fileType: String, width: Int?, height: Int?, lastScanned: Date,
                duration: Double? = nil, fileSize: Int? = nil, modifiedAt: Date? = nil,
                hidden: Bool = false, kindFlags: Int = 0, sceneFlags: Int = 0,
                posterTime: Double? = nil,
                archivedHash: String? = nil, archivedAt: Date? = nil, smallPath: String? = nil,
                curated: Bool = true, protected: Bool = false, ssdRelPath: String? = nil) {
        self.id = id; self.path = path; self.hash = hash; self.dateTaken = dateTaken
        self.fileType = fileType; self.width = width; self.height = height
        self.lastScanned = lastScanned; self.duration = duration
        self.fileSize = fileSize; self.modifiedAt = modifiedAt
        self.hidden = hidden; self.kindFlags = kindFlags; self.sceneFlags = sceneFlags
        self.posterTime = posterTime
        self.archivedHash = archivedHash; self.archivedAt = archivedAt; self.smallPath = smallPath
        self.curated = curated; self.protected = protected; self.ssdRelPath = ssdRelPath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension MediaItem: Identifiable {}   // id: Int64? (row id) — non-nil for fetched rows

public extension MediaItem {
    /// The best LOCAL file to DISPLAY: the original if it still exists on disk,
    /// otherwise the 10% small version. Lets reclaimed items (original trashed,
    /// smallPath present) still render. Falls back to the original path if
    /// neither exists (caller handles a missing file as it already does).
    func bestLocalURL(fileManager: FileManager = .default) -> URL {
        if fileManager.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        if let sp = smallPath, fileManager.fileExists(atPath: sp) { return URL(fileURLWithPath: sp) }
        return URL(fileURLWithPath: path)
    }
}
