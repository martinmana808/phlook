import SwiftUI
import PhlookCore

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
    @Published var isIndexing = false
    @Published var viewerIndex: Int?
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
        }
    }
    @Published var dateRange = DateRangeFilter() {
        didSet {
            guard dateRange != oldValue else { return }
            rebuildVisible()
            timeline = TimelineIndex.compute(items: visibleItems)
        }
    }
    /// Touch ID / password gate for `.hidden`; relocked whenever `scope`
    /// moves away from `.hidden` (see `scope`'s didSet above).
    @Published var hiddenUnlocked = false {
        didSet {
            guard hiddenUnlocked != oldValue else { return }
            rebuildVisible()
        }
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
        guard !(scope == .hidden && !hiddenUnlocked) else {
            visibleItems = []
            return
        }
        let unhidden = items.filter { !livePairs.hiddenVideoPaths.contains($0.path) }
        visibleItems = unhidden
            .filter { scope.matches($0, livePairs: livePairs) }
            .filter { dateRange.matches($0) }
    }

    func openViewer(_ item: MediaItem) {
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
