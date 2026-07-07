import Foundation

public final class IndexingService {
    public let root: URL
    private let index: MediaIndex
    public let thumbnails: ThumbnailCache

    /// The backing index, for read/delete operations owned by the UI layer.
    public var mediaIndex: MediaIndex { index }

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.index = try! MediaIndex(dbPath: root.appendingPathComponent("phlook.db").path)
        self.thumbnails = ThumbnailCache(cacheDir: root.appendingPathComponent(".phlook/thumbnails"))
    }

    @discardableResult
    public func reindex() throws -> Int {
        let scanned = try LibraryScanner(root: root).scan()
        for item in scanned { try index.upsert(item) }
        try index.deleteMissing(keepingPaths: Set(scanned.map { $0.path }))
        return try index.count()
    }

    public func items() throws -> [MediaItem] {
        try index.allItems(sortedByDateDescending: true)
    }

    /// Post-scan pass: fill video duration/date/dimensions in the background.
    @discardableResult
    public func enrichVideos() async -> Int {
        await VideoMetadataEnricher().enrich(index: index)
    }

    public func recordImport(device: String, identifier: String) throws {
        try index.recordImport(device: device, identifier: identifier)
    }

    public func importedIdentifiers(device: String) throws -> Set<String> {
        try index.importedIdentifiers(device: device)
    }
}
