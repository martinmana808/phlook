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
    @Published var scope: LibraryScope = .all {
        didSet {
            guard scope != oldValue else { return }
            if oldValue == .hidden { hiddenUnlocked = false }
            closeViewer()
            clearSelection()
            rebuildVisible()
            timeline = TimelineIndex.compute(items: visibleItems)
            yearBuckets = TimelineIndex.yearBuckets(items: visibleItems)
            fullTimeline = TimelineIndex.compute(items: scopedItems())
        }
    }
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
            let enriched = await service.enrichVideos()
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
            let detected = await service.detectKinds()
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

    func thumbnail(for item: MediaItem, size: Int = 160) async -> NSImage? {
        let key = "\(item.path)#\(size)" as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
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
        thumbCache.object(forKey: "\(item.path)#\(size)" as NSString)
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
}
