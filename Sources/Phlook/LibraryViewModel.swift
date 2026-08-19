import SwiftUI
import PhlookCore

/// Time-browser view mode (Part 4 of the zoom-views spec). Session-only —
/// deliberately not persisted to UserDefaults, unlike `GridDensity`.
enum TimeMode {
    case years, months, all
}

enum GridDensity: Int, CaseIterable, Identifiable {
    case micro = 80, medium = 160, large = 240
    var id: Int { rawValue }
    var symbol: String {
        switch self {
        case .micro: "square.grid.4x3.fill"
        case .medium: "square.grid.3x2"
        case .large: "square.grid.2x2"
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published private(set) var visibleItems: [MediaItem] = []
    @Published private(set) var timeline: [TimelineBucket] = []
    /// Timeline computed over the same scope/hidden-lock pipeline as
    /// `visibleItems` but WITHOUT the `dateRange` stage — this is the domain
    /// the date-range sliders drag over. If it were derived from the
    /// date-filtered `visibleItems` instead, the slider's own filtering would
    /// shrink its domain on every drag and it could never widen back out.
    @Published private(set) var fullTimeline: [TimelineBucket] = []
    @Published private(set) var yearBuckets: [YearBucket] = []
    /// Years / Months / All Photos time browser mode (Part 4). Session-only.
    @Published var timeMode: TimeMode = .all
    /// A path the All grid (or Months list) should scroll to on next
    /// appearance — set by Years/Months card taps, consumed (and cleared) by
    /// the destination view's onChange/onAppear.
    @Published var pendingScrollPath: String?
    @Published var isIndexing = false
    @Published var viewerIndex: Int?
    /// The tapped grid cell's frame (in the shared "phlookWindow" coordinate
    /// space), captured at `openViewer` time so ViewerView can animate its
    /// media layer expanding from that rect. Not touched on subsequent
    /// navigation (`step`) — only the initial open.
    @Published var viewerOpenOriginFrame: CGRect?
    /// Live-updated frame of every currently materialized grid cell, keyed by
    /// path, in the "phlookWindow" coordinate space. Deliberately NOT
    /// `@Published`: it's written on every scroll/layout pass by every
    /// visible `ThumbCell`, and turning that into a published mutation would
    /// re-render the whole view tree on every frame. Only read at
    /// open/close time to resolve the animation's target rect.
    var cellFrames: [String: CGRect] = [:]
    @Published var sidebarOpen = false
    @Published var detailsItem: MediaItem?   // grid "View Details" modal
    @Published var posterPickerItem: MediaItem?   // Live Photo poster-frame picker sheet
    @Published var scope: LibraryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            if oldValue == .hidden { hiddenUnlocked = false }
            closeViewer()
            clearSelection()
            // Picking a normal scope leaves album mode. Set the stored
            // properties directly (not via selectAlbum) to avoid re-entrant
            // didSet/rebuild churn.
            selectedAlbumID = nil
            albumMemberCache = []
            rebuildVisible()
            timeline = TimelineIndex.compute(items: visibleItems)
            yearBuckets = TimelineIndex.yearBuckets(items: visibleItems)
            fullTimeline = TimelineIndex.compute(items: scopedItems())
        }
    }
    /// Albums (Part of the Albums feature). `albumMemberCache` is the
    /// resolved member-path set for `selectedAlbumID`, kept in sync by
    /// `selectAlbum`/`addToAlbum`/`removeFromAlbum` so `scopedItems()` can do
    /// a cheap membership check without hitting the DB on every filter pass.
    @Published var albums: [Album] = []
    @Published private(set) var selectedAlbumID: Int64? = nil
    private var albumMemberCache: Set<String> = []
    /// Items to seed the "New Album" name prompt with; consumed by the UI
    /// (next task).
    @Published var newAlbumTarget: [MediaItem]? = nil

    /// Album whose name is being edited via a Rename… prompt; set by the
    /// sidebar's context menu, consumed by ContentView's rename alert.
    @Published var renameAlbumTarget: Album? = nil
    @Published var dateRange = DateRangeFilter() {
        didSet {
            guard dateRange != oldValue else { return }
            rebuildVisible()
            timeline = TimelineIndex.compute(items: visibleItems)
            yearBuckets = TimelineIndex.yearBuckets(items: visibleItems)
        }
    }
    /// Touch ID / password gate for `.hidden`; relocked whenever `scope`
    /// moves away from `.hidden` (see `scope`'s didSet above). Callers unlock
    /// via `unlockHidden()`, which keeps auth + scope switch + relock
    /// bookkeeping in one place instead of duplicated across call sites.
    @Published private(set) var hiddenUnlocked = false {
        didSet {
            guard hiddenUnlocked != oldValue else { return }
            rebuildVisible()
            yearBuckets = TimelineIndex.yearBuckets(items: visibleItems)
            fullTimeline = TimelineIndex.compute(items: scopedItems())
        }
    }

    /// Authenticates (if needed) and switches to `.hidden` on success. If
    /// already unlocked, just switches scope. On failure, leaves `scope`
    /// untouched but nudges SwiftUI to reassert the sidebar's current
    /// selection highlight (the List's selection binding already "set" the
    /// tapped row optimistically).
    @MainActor
    func unlockHidden() async -> Bool {
        guard !hiddenUnlocked else { scope = .hidden; return true }
        let ok = await HiddenGate.authenticate()
        if ok {
            hiddenUnlocked = true
            scope = .hidden
        } else {
            objectWillChange.send()   // reassert sidebar selection highlight
        }
        return ok
    }
    @Published private(set) var scopeCounts: [LibraryScope: Int] = [:]
    @Published private(set) var livePairs: LivePairs = .empty
    @Published var selectedPaths: Set<String> = []
    @Published var pendingTrash: [MediaItem]?     // confirmation dialog payload
    @Published var trashFailures: [String]?       // post-delete failure alert
    @Published var duplicateGroups: [[MediaItem]]?   // Duplicates sheet payload; nil = dismissed
    @Published var editedPairGroups: [[MediaItem]]?  // Original+edited (IMG_/IMG_E) pairs; nil = not yet run
    @Published var findingDuplicates = false
    @Published var reclaimStatus: ReclaimStatus?
    @Published var archiveRunning = false
    @Published var lastArchiveReport: ArchiveReport?
    @Published var archiveProgress: (done: Int, total: Int)? = nil
    @Published var showReclaim = false   // Reclaim space sheet presented flag (ContentView)
    /// Read from the detached archive-run task's `isCancelled` closure (off
    /// main); set on the main actor by `requestCancelArchive()`. A plain
    /// racy flag — `nonisolated(unsafe)` so the background read compiles —
    /// matching this app's existing lightweight-cancellation style (see
    /// `refreshEpoch`). Worst case is one extra file processed after Cancel;
    /// acceptable for a user-facing "stop soon" control.
    nonisolated(unsafe) private var cancelArchive = false
    @Published var density: GridDensity = GridDensity(
        rawValue: UserDefaults.standard.integer(forKey: "gridDensity")) ?? .micro {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "gridDensity") }
    }
    private var selectionAnchorPath: String?
    private var refreshEpoch = 0
    let service: IndexingService
    private let thumbCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/PHLOOK")
        service = IndexingService(root: root)
    }

    var currentItem: MediaItem? {
        guard let i = viewerIndex, visibleItems.indices.contains(i) else { return nil }
        return visibleItems[i]
    }

    /// Resolves a bucket's `firstItemPath` back to its `MediaItem` for card
    /// thumbnails in Months/Years mode.
    func item(forPath path: String) -> MediaItem? {
        visibleItems.first { $0.path == path }
    }

    /// Up to `limit` items from `visibleItems` that fall in the same
    /// calendar month as `bucket.monthStart` — used to auto-cycle a Months
    /// card's photo instead of showing only its single key photo. Undated
    /// buckets (`monthStart == nil`) yield no extra items.
    func items(forMonthBucket bucket: TimelineBucket, limit: Int = 10) -> [MediaItem] {
        guard let monthStart = bucket.monthStart else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let key = calendar.dateComponents([.year, .month], from: monthStart)
        var result: [MediaItem] = []
        for item in visibleItems {
            guard let date = item.dateTaken else { continue }
            if calendar.dateComponents([.year, .month], from: date) == key {
                result.append(item)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Up to `limit` items from `visibleItems` taken in the given calendar
    /// year — used to auto-cycle a Years card's photo.
    func items(forYear year: Int, limit: Int = 10) -> [MediaItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var result: [MediaItem] = []
        for item in visibleItems {
            guard let date = item.dateTaken else { continue }
            if calendar.component(.year, from: date) == year {
                result.append(item)
                if result.count >= limit { break }
            }
        }
        return result
    }

    func load() {
        refreshAlbums()
        let epoch = refreshEpoch
        let service = self.service
        isIndexing = true
        Task.detached {
            // 1. Show whatever is already indexed immediately — instant on relaunch.
            let cached = (try? service.items()) ?? []
            await MainActor.run {
                guard epoch == self.refreshEpoch else {
                    self.refreshItems((try? service.items()) ?? [])
                    return
                }
                self.refreshItems(cached)
            }

            // 2. Refresh the index in the background, then update the grid.
            _ = try? service.reindex()
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                guard epoch == self.refreshEpoch else {
                    self.refreshItems((try? service.items()) ?? [])
                    return
                }
                self.refreshItems(fresh)
            }

            // 3. Fill video duration/date/dimensions, then refresh once more.
            // Progressive refresh: every 200 processed items during the pass,
            // re-fetch and apply so the grid/sidebar counts don't sit empty
            // for minutes while a large one-time backfill runs.
            let onProgress: @Sendable (Int) -> Void = { _ in
                Task { @MainActor in
                    guard epoch == self.refreshEpoch else { return }
                    self.refreshItems((try? service.items()) ?? [])
                }
            }
            let enriched = await service.enrichVideos(onProgress: onProgress)
            if enriched > 0 {
                let final = (try? service.items()) ?? []
                await MainActor.run {
                    guard epoch == self.refreshEpoch else {
                        self.refreshItems((try? service.items()) ?? [])
                        return
                    }
                    self.refreshItems(final)
                }
            }

            // 4. Backfill screenshot/selfie kind flags, then refresh once more.
            let detected = await service.detectKinds(onProgress: onProgress)
            if detected > 0 {
                let final = (try? service.items()) ?? []
                await MainActor.run {
                    guard epoch == self.refreshEpoch else {
                        self.refreshItems((try? service.items()) ?? [])
                        return
                    }
                    self.refreshItems(final)
                }
            }

            // 5. Backfill Vision scene-category flags, then refresh once more.
            let classified = await service.classifyScenes(onProgress: onProgress)
            if classified > 0 {
                let final = (try? service.items()) ?? []
                await MainActor.run {
                    guard epoch == self.refreshEpoch else {
                        self.refreshItems((try? service.items()) ?? [])
                        return
                    }
                    self.refreshItems(final)
                }
            }
            await MainActor.run { self.isIndexing = false }
        }
    }

    /// Swap the items array while keeping the open viewer anchored to the same
    /// file (re-resolved by path in the filtered list). If the file vanished,
    /// the viewer closes.
    private func refreshItems(_ new: [MediaItem]) {
        let openPath = currentItem?.path
        items = new
        livePairs = LivePairs.compute(items: new)
        scopeCounts = Self.computeScopeCounts(items: new, livePairs: livePairs)
        rebuildVisible()
        timeline = TimelineIndex.compute(items: visibleItems)
        yearBuckets = TimelineIndex.yearBuckets(items: visibleItems)
        fullTimeline = TimelineIndex.compute(items: scopedItems())
        let visiblePaths = Set(visibleItems.map(\.path))
        selectedPaths = selectedPaths.filter(visiblePaths.contains)
        if let openPath {
            viewerIndex = ViewerMath.resolveIndex(path: openPath, in: visibleItems)
        }
    }

    /// Per-scope library counts — one pass over all items, ignoring
    /// `dateRange` (these are library totals, not "currently visible" counts)
    /// but still respecting `hiddenVideoPaths` (paired motion files never
    /// count toward any scope).
    private static func computeScopeCounts(items: [MediaItem], livePairs: LivePairs) -> [LibraryScope: Int] {
        let candidates = items.filter { !livePairs.hiddenVideoPaths.contains($0.path) }
        var counts: [LibraryScope: Int] = [:]
        for scope in LibraryScope.allCases {
            counts[scope] = candidates.reduce(0) { $0 + (scope.matches($1, livePairs: livePairs) ? 1 : 0) }
        }
        return counts
    }

    private func rebuildVisible() {
        visibleItems = scopedItems().filter { dateRange.matches($0) }
    }

    /// Items after dropping paired motion files and applying the current
    /// scope + hidden-lock rule, but BEFORE the `dateRange` stage. Shared by
    /// `visibleItems` (which adds the date filter) and `fullTimeline` (which
    /// doesn't) so the date-range sliders' domain never depends on the
    /// sliders' own current position.
    private func scopedItems() -> [MediaItem] {
        if selectedAlbumID != nil {
            return items.filter {
                !livePairs.hiddenVideoPaths.contains($0.path) && !$0.hidden && albumMemberCache.contains($0.path)
            }
        }
        guard !(scope == .hidden && !hiddenUnlocked) else { return [] }
        let unhidden = items.filter { !livePairs.hiddenVideoPaths.contains($0.path) }
        return unhidden.filter { scope.matches($0, livePairs: livePairs) }
    }

    func openViewer(_ item: MediaItem) {
        viewerOpenOriginFrame = cellFrames[item.path]
        viewerIndex = ViewerMath.resolveIndex(path: item.path, in: visibleItems)
    }

    func closeViewer() {
        viewerIndex = nil
        sidebarOpen = false   // sidebar always starts closed for the next open
    }

    func step(_ delta: Int) {
        guard let i = viewerIndex, !visibleItems.isEmpty else { return }
        viewerIndex = ViewerMath.clamp(i + delta, count: visibleItems.count)
    }

    /// Cache key includes the item's `posterTime` so choosing/resetting a
    /// Live Photo poster frame invalidates the previously cached thumbnail
    /// (a different key simply misses the cache) without needing to purge it.
    private func thumbnailCacheKey(for item: MediaItem, size: Int) -> NSString {
        guard let posterTime = item.posterTime else { return "\(item.path)#\(size)" as NSString }
        return "\(item.path)#\(size)#poster\(posterTime)" as NSString
    }

    func thumbnail(for item: MediaItem, size: Int = 160) async -> NSImage? {
        let key = thumbnailCacheKey(for: item, size: size)
        if let cached = thumbCache.object(forKey: key) { return cached }
        // Live Photo with a chosen poster frame: render it from the paired
        // motion file instead of decoding the HEIC. Non-destructive — reads
        // the MOV, never writes it or the original still.
        if isLive(item), let posterTime = item.posterTime,
           let motionPath = livePairs.videoPath(forImagePath: item.path) {
            guard let image = await PosterRenderer.posterImage(
                motionPath: motionPath, time: posterTime, maxPixel: CGFloat(size * 2)
            ) else { return nil }
            let cost = Int(image.size.width * image.size.height * 4)
            thumbCache.setObject(image, forKey: key, cost: cost)
            return image
        }
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: size) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        thumbCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Synchronous cache-only lookup — used to seed the viewer's open/close
    /// zoom animation with content immediately, without waiting on the async
    /// disk/QuickLook path `thumbnail(for:size:)` uses.
    func cachedThumbnail(for item: MediaItem, size: Int) -> NSImage? {
        thumbCache.object(forKey: thumbnailCacheKey(for: item, size: size))
    }

    func isLive(_ item: MediaItem) -> Bool {
        item.fileType == "image" && livePairs.videoPath(forImagePath: item.path) != nil
    }

    func select(_ item: MediaItem, commandKey: Bool, shiftKey: Bool) {
        if shiftKey, let anchor = selectionAnchorPath,
           let a = visibleItems.firstIndex(where: { $0.path == anchor }),
           let b = visibleItems.firstIndex(where: { $0.path == item.path }) {
            let range = min(a, b)...max(a, b)
            selectedPaths.formUnion(visibleItems[range].map(\.path))
        } else if commandKey {
            if selectedPaths.contains(item.path) { selectedPaths.remove(item.path) }
            else { selectedPaths.insert(item.path) }
            selectionAnchorPath = item.path
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
    }

    func selectAllVisible() { selectedPaths = Set(visibleItems.map(\.path)) }
    func clearSelection() { selectedPaths = []; selectionAnchorPath = nil }

    func stepDensity(_ delta: Int) {
        let all = GridDensity.allCases
        if let i = all.firstIndex(of: density) {
            density = all[ViewerMath.clamp(i + delta, count: all.count)]
        }
    }

    /// Right-click delete: if the clicked item isn't in the selection, the
    /// selection becomes just that item (Photos behavior) before confirming.
    func requestTrash(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        pendingTrash = items
    }

    func confirmTrash() {
        guard let targets = pendingTrash else { return }
        pendingTrash = nil
        // Expand live pairs: trashing the still takes the motion file with it.
        var paths: [String] = []
        for item in targets {
            paths.append(item.path)
            if let motion = livePairs.videoPath(forImagePath: item.path) {
                paths.append(motion)
            }
        }
        let service = self.service
        Task.detached {
            let index = service.mediaIndex
            let outcome = LibraryTrasher.trash(paths: paths, index: index)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshEpoch += 1
                self.refreshItems(fresh)
                self.clearSelection()
                if !outcome.failures.isEmpty { self.trashFailures = outcome.failures }
            }
        }
    }

    /// Runs exact-content duplicate detection over the whole library
    /// (candidate pre-filter + full-hash confirmation happen in the service,
    /// off-main). `duplicateGroups` drives the Duplicates sheet; nil means
    /// dismissed, an empty array means the scan ran and found nothing.
    func findDuplicates() async {
        findingDuplicates = true
        let raw = await service.duplicateGroups()
        let hiddenVideoPaths = livePairs.hiddenVideoPaths
        duplicateGroups = raw
            .map { group in group.filter { !hiddenVideoPaths.contains($0.path) } }
            .filter { $0.count >= 2 }
        editedPairGroups = EditedPairFinder.pairs(items: items)
            .map { group in group.filter { !hiddenVideoPaths.contains($0.path) } }
            .filter { $0.count >= 2 }
        findingDuplicates = false
    }

    /// Refreshes the Reclaim-space panel's status (SSD connectivity + archive
    /// counts). Cheap DB read — safe to call on appear/after every run.
    func refreshReclaimStatus() {
        reclaimStatus = try? service.reclaimStatus()
    }

    /// Marks `volumeRoot` as the PHLOOK archive drive (writes the marker file
    /// + records its ID in the DB) and refreshes status.
    func setUpArchiveDrive(volumeRoot: URL) {
        _ = try? service.setUpArchiveDrive(volumeRoot: volumeRoot)
        refreshReclaimStatus()
    }

    /// Runs the archive/shrink/reclaim pipeline for every item not yet
    /// archived. `runArchive` is a synchronous, throwing, potentially
    /// long-running (hashing/copying/encoding GBs) call — it MUST stay off
    /// the main actor, so it runs inside `Task.detached` (mirrors
    /// `confirmTrash`/`findDuplicates`'s off-main pattern) and only publishes
    /// results back via `MainActor.run`.
    func startArchive() {
        guard !archiveRunning else { return }
        archiveRunning = true
        cancelArchive = false
        archiveProgress = nil
        let service = self.service
        Task.detached {
            let report = try? service.runArchive(isCancelled: { self.cancelArchive }, onProgress: { done, total in
                Task { @MainActor in self.archiveProgress = (done, total) }
            })
            await MainActor.run {
                self.lastArchiveReport = report
                self.archiveRunning = false
                self.archiveProgress = nil
                self.refreshReclaimStatus()
            }
        }
    }

    func requestCancelArchive() {
        cancelArchive = true
    }

    /// Reveal a small-version item's master on the archive SSD in Finder
    /// (no-op if no SSD is resolvable or the master isn't actually there —
    /// this only reveals, it never copies anything back).
    func revealOriginalOnSSD(for item: MediaItem) {
        guard let target = try? service.resolveArchiveTarget() else { return }
        let master = target.phlookRoot.appendingPathComponent(URL(fileURLWithPath: item.path).lastPathComponent)
        guard FileManager.default.fileExists(atPath: master.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([master])
    }

    /// Trash arbitrary paths (e.g. duplicate-review selections), expanding
    /// live pairs so a still's paired motion file moves with it. Mirrors
    /// `confirmTrash`'s shape/epoch-refresh but takes raw paths instead of a
    /// `pendingTrash` confirmation payload.
    func trashPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var expanded: [String] = []
        for path in paths {
            expanded.append(path)
            if let motion = livePairs.videoPath(forImagePath: path) {
                expanded.append(motion)
            }
        }
        let service = self.service
        Task.detached {
            let index = service.mediaIndex
            let outcome = LibraryTrasher.trash(paths: expanded, index: index)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshEpoch += 1
                self.refreshItems(fresh)
                if !outcome.failures.isEmpty { self.trashFailures = outcome.failures }
            }
        }
    }

    /// Hide/unhide the given items. Expands live pairs so a still and its
    /// paired motion file move together (mirrors `confirmTrash`'s shape),
    /// so `.videos` can never leak a hidden-item's motion file.
    func setHidden(_ items: [MediaItem], hidden: Bool) {
        guard !items.isEmpty else { return }
        var paths: [String] = []
        for item in items {
            paths.append(item.path)
            if let motion = livePairs.videoPath(forImagePath: item.path) {
                paths.append(motion)
            }
        }
        let service = self.service
        Task.detached {
            let index = service.mediaIndex
            try? index.setHidden(paths: paths, hidden: hidden)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshEpoch += 1
                self.refreshItems(fresh)
                self.clearSelection()
            }
        }
    }

    /// Protect/unprotect the given items (keep-full-size flag honored by the
    /// shrink pipeline — protected items are archived but never shrunk).
    /// Mirrors `setHidden`'s shape/off-main pattern.
    func setProtected(_ items: [MediaItem], _ protectedFlag: Bool) {
        guard !items.isEmpty else { return }
        let paths = items.map(\.path)
        let service = self.service
        Task.detached {
            let index = service.mediaIndex
            try? index.setProtected(paths: paths, protected: protectedFlag)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshEpoch += 1
                self.refreshItems(fresh)
            }
        }
    }

    /// Claims back the full-size master from the SSD for a compressed (10%)
    /// item, protecting it so it never gets re-shrunk. `claimFullSize` is a
    /// synchronous, throwing, potentially long-running (copying GBs) call —
    /// mirrors `confirmTrash`/`setHidden`'s off-main pattern.
    func claimFullSize(_ item: MediaItem) {
        let service = self.service
        Task.detached {
            _ = try? service.claimFullSize(item)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshEpoch += 1
                self.refreshItems(fresh)
            }
        }
    }

    /// True when this item's local copy is the 10% version (compressed) —
    /// archived, shrunk, and not protected. Protected items always keep
    /// their full-size local copy even after archiving.
    func isCompressed(_ item: MediaItem) -> Bool {
        item.archivedHash != nil && item.smallPath != nil && !item.protected
    }

    /// Set (or clear, when `time` is nil) a Live Photo's chosen poster frame
    /// — a time offset into the paired motion file, stored in the DB only.
    /// Never touches the original HEIC/MOV on disk (see `PosterRenderer`).
    // MARK: - Albums

    func refreshAlbums() {
        albums = (try? service.mediaIndex.albums()) ?? []
    }

    func selectAlbum(_ id: Int64?) {
        selectedAlbumID = id
        albumMemberCache = id.flatMap { try? service.mediaIndex.albumMemberPaths($0) } ?? []
        closeViewer()
        clearSelection()
        rebuildVisible()
    }

    func createAlbum(named name: String, andAdd items: [MediaItem]) {
        guard let id = try? service.mediaIndex.createAlbum(name: name) else { return }
        try? service.mediaIndex.addToAlbum(id, paths: items.map(\.path))
        refreshAlbums()
    }

    func addToAlbum(_ id: Int64, _ items: [MediaItem]) {
        try? service.mediaIndex.addToAlbum(id, paths: items.map(\.path))
        refreshAlbums()
        if selectedAlbumID == id { selectAlbum(id) }
    }

    func removeFromAlbum(_ id: Int64, _ items: [MediaItem]) {
        try? service.mediaIndex.removeFromAlbum(id, paths: items.map(\.path))
        refreshAlbums()
        if selectedAlbumID == id { selectAlbum(id) }
    }

    func renameAlbum(_ id: Int64, to name: String) {
        try? service.mediaIndex.renameAlbum(id: id, to: name)
        refreshAlbums()
    }

    func deleteAlbum(_ id: Int64) {
        if selectedAlbumID == id { selectAlbum(nil) }
        try? service.mediaIndex.deleteAlbum(id: id)
        refreshAlbums()
    }

    func albumIDs(for item: MediaItem) -> [Int64] {
        (try? service.mediaIndex.albumIDs(forPath: item.path)) ?? []
    }

    func beginNewAlbum(for items: [MediaItem]) {
        newAlbumTarget = items
    }

    func setPosterTime(_ item: MediaItem, time: Double?) {
        let path = item.path
        let service = self.service
        thumbCache.removeObject(forKey: thumbnailCacheKey(for: item, size: density.rawValue))
        Task.detached {
            let index = service.mediaIndex
            try? index.setPosterTime(path: path, time: time)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshEpoch += 1
                self.refreshItems(fresh)
            }
        }
    }
}
