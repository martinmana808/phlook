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
    public func enrichVideos(onProgress: (@Sendable (Int) -> Void)? = nil) async -> Int {
        await VideoMetadataEnricher().enrich(index: index, onProgress: onProgress)
    }

    /// Backfill pass for rows predating kind detection (kind_flags == -1
    /// sentinel, see MediaIndex migration v5): computes screenshot/selfie
    /// flags via KindDetector and upserts. A missing file is marked 0 (tried,
    /// don't retry). Mirrors enrichVideos's shape/idempotency.
    @discardableResult
    public func detectKinds(onProgress: (@Sendable (Int) -> Void)? = nil) async -> Int {
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
            if processed % 200 == 0 { onProgress?(processed) }
        }
        return processed
    }

    /// Backfill pass for rows predating scene classification (scene_flags ==
    /// -1 sentinel, see MediaIndex migration v6): computes the scene-category
    /// bitmask via SceneClassifier and upserts. A missing file is marked 0
    /// (tried, don't retry). Mirrors detectKinds's shape/idempotency.
    @discardableResult
    public func classifyScenes(onProgress: (@Sendable (Int) -> Void)? = nil) async -> Int {
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
            if processed % 200 == 0 { onProgress?(processed) }
        }
        return processed
    }

    /// Finds exact-content duplicate groups: pulls candidates sharing
    /// (file_size, quickHash) from the index (cheap SQL), then confirms them
    /// with a full-file SHA256 computed off-main — each candidate file is
    /// hashed at most once via `cache`.
    public func duplicateGroups() async -> [[MediaItem]] {
        let index = self.index
        return await Task.detached {
            let candidatePaths = (try? index.duplicateCandidatePaths()) ?? []
            var items: [MediaItem] = []
            for path in candidatePaths {
                if let item = try? index.item(forPath: path) {
                    items.append(item)
                }
            }
            guard !items.isEmpty else { return [] }
            var cache: [String: String?] = [:]
            func fullHash(_ path: String) -> String? {
                if let cached = cache[path] { return cached }
                let value = LibraryScanner.fullHash(URL(fileURLWithPath: path))
                cache[path] = value
                return value
            }
            return DuplicateFinder.groups(items: items, fullHash: fullHash)
        }.value
    }

    public func recordImport(device: String, identifier: String) throws {
        try index.recordImport(device: device, identifier: identifier)
    }

    public func importedIdentifiers(device: String) throws -> Set<String> {
        try index.importedIdentifiers(device: device)
    }

    public enum ArchiveError: Error { case noSSD }

    public var proxyRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent("PHLOOK_proxy")
    }

    public func setUpArchiveDrive(volumeRoot: URL) throws -> ArchiveTarget {
        let id = UUID().uuidString
        try SSDArchiveTarget.setUp(volumeRoot: volumeRoot, markerID: id)
        try index.setMarkerID(id, label: volumeRoot.lastPathComponent)
        return ArchiveTarget(volumeRoot: volumeRoot, markerID: id)
    }

    public func resolveArchiveTarget() throws -> ArchiveTarget? {
        guard let id = try index.markerID() else { return nil }
        return SSDArchiveTarget.resolve(expectedMarkerID: id,
                                        candidateRoots: SSDArchiveTarget.mountedVolumeRoots())
    }

    public func reclaimStatus() throws -> ReclaimStatus {
        ReclaimStatus(ssdConnected: (try resolveArchiveTarget()) != nil,
                      counts: try index.archiveCounts())
    }

    /// Restore an archived item's full-resolution master from the SSD to its
    /// local path and mark it protected (kept full-res, never re-shrunk).
    /// `resolvedTarget` is for tests; production passes nil and it resolves.
    @discardableResult
    public func claimFullSize(_ item: MediaItem, resolvedTarget: ArchiveTarget? = nil) throws -> Bool {
        guard let target = try (resolvedTarget ?? resolveArchiveTarget()) else { throw ArchiveError.noSSD }
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let master = item.ssdRelPath.map { target.volumeRoot.appendingPathComponent($0) }
            ?? target.phlookRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: master.path) else { return false }
        let dest = URL(fileURLWithPath: item.path)
        let tempURL = URL(fileURLWithPath: dest.path + ".claim-partial")
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.copyItem(at: master, to: tempURL)

        let verified: Bool
        if let expected = item.archivedHash {
            verified = FileHasher.sha256(of: tempURL) == expected
        } else {
            verified = true
        }
        guard verified else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        let rel = item.ssdRelPath ?? "PHLOOK/\(name)"
        try index.setClaimed(path: item.path, ssdRelPath: rel)
        if let sp = item.smallPath { try? FileManager.default.removeItem(at: URL(fileURLWithPath: sp)) }
        return true
    }

    public func runArchive(isCancelled: @escaping () -> Bool,
                            onProgress: ((Int, Int) -> Void)? = nil) throws -> ArchiveReport {
        guard let target = try resolveArchiveTarget() else { throw ArchiveError.noSSD }
        let pending = try index.itemsPendingArchiveOrShrink()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let service = ArchiveService(index: index, encoder: SmallVersionEncoder(), proxyDir: proxyRoot)
        return service.run(target: target, items: pending, isCancelled: isCancelled, onProgress: onProgress)
    }
}
