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
        let known = (try? index.allStamps()) ?? [:]
        let (changed, allPaths) = try LibraryScanner(root: root).scan(known: known)
        for item in changed where FileManager.default.fileExists(atPath: item.path) {
            try index.upsert(item)
        }
        try index.deleteMissing(keepingPaths: allPaths)
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

    /// Backfill pass for rows predating kind detection (kind_flags == -1
    /// sentinel, see MediaIndex migration v5): computes screenshot/selfie
    /// flags via KindDetector and upserts. A missing file is marked 0 (tried,
    /// don't retry). Mirrors enrichVideos's shape/idempotency.
    @discardableResult
    public func detectKinds() async -> Int {
        let pending = (try? index.kindsNeedingDetection()) ?? []
        var processed = 0
        for var item in pending {
            let url = URL(fileURLWithPath: item.path)
            item.kindFlags = FileManager.default.fileExists(atPath: url.path)
                ? KindDetector.flags(forImageAt: url).rawValue
                : 0
            item.lastScanned = Date()
            try? index.upsert(item)
            processed += 1
        }
        return processed
    }

    /// Backfill pass for rows predating scene classification (scene_flags ==
    /// -1 sentinel, see MediaIndex migration v6): computes the scene-category
    /// bitmask via SceneClassifier and upserts. A missing file is marked 0
    /// (tried, don't retry). Mirrors detectKinds's shape/idempotency.
    @discardableResult
    public func classifyScenes() async -> Int {
        let pending = (try? index.scenesNeedingClassification()) ?? []
        var processed = 0
        for var item in pending {
            let url = URL(fileURLWithPath: item.path)
            item.sceneFlags = FileManager.default.fileExists(atPath: url.path)
                ? SceneClassifier.classify(imageAt: url)
                : 0
            item.lastScanned = Date()
            try? index.upsert(item)
            processed += 1
        }
        return processed
    }

    public func recordImport(device: String, identifier: String) throws {
        try index.recordImport(device: device, identifier: identifier)
    }

    public func importedIdentifiers(device: String) throws -> Set<String> {
        try index.importedIdentifiers(device: device)
    }
}
