import SwiftUI
import PhlookCore

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"

    var id: String { rawValue }

    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .all: return true
        case .photos: return item.fileType == "image"
        case .videos: return item.fileType == "video"
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published private(set) var visibleItems: [MediaItem] = []
    @Published var isIndexing = false
    @Published var viewerIndex: Int?
    @Published var sidebarOpen = false
    @Published var detailsItem: MediaItem?   // grid "View Details" modal
    @Published var filter: MediaFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            closeViewer()
            rebuildVisible()
        }
    }
    let service: IndexingService

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
        let service = self.service
        isIndexing = true
        Task.detached {
            // 1. Show whatever is already indexed immediately — instant on relaunch.
            let cached = (try? service.items()) ?? []
            await MainActor.run { self.refreshItems(cached) }

            // 2. Refresh the index in the background, then update the grid.
            _ = try? service.reindex()
            let fresh = (try? service.items()) ?? []
            await MainActor.run { self.refreshItems(fresh) }

            // 3. Fill video duration/date/dimensions, then refresh once more.
            let enriched = await service.enrichVideos()
            if enriched > 0 {
                let final = (try? service.items()) ?? []
                await MainActor.run { self.refreshItems(final) }
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
        rebuildVisible()
        if let openPath {
            viewerIndex = ViewerMath.resolveIndex(path: openPath, in: visibleItems)
        }
    }

    private func rebuildVisible() {
        visibleItems = filter == .all ? items : items.filter { filter.matches($0) }
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

    func thumbnail(for item: MediaItem) async -> NSImage? {
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: 160) else { return nil }
        return NSImage(contentsOf: url)
    }
}
