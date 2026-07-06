import SwiftUI
import PhlookCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isIndexing = false
    @Published var viewerIndex: Int?
    @Published var sidebarOpen = false
    let service: IndexingService

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/PHLOOK")
        service = IndexingService(root: root)
    }

    var currentItem: MediaItem? {
        guard let i = viewerIndex, items.indices.contains(i) else { return nil }
        return items[i]
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
    /// file (re-resolved by path). If the file vanished, the viewer closes.
    private func refreshItems(_ new: [MediaItem]) {
        let openPath = currentItem?.path
        items = new
        if let openPath {
            viewerIndex = ViewerMath.resolveIndex(path: openPath, in: new)
        }
    }

    func openViewer(_ item: MediaItem, withSidebar: Bool = false) {
        viewerIndex = ViewerMath.resolveIndex(path: item.path, in: items)
        if withSidebar { sidebarOpen = true }
    }

    func closeViewer() { viewerIndex = nil }

    func step(_ delta: Int) {
        guard let i = viewerIndex, !items.isEmpty else { return }
        viewerIndex = ViewerMath.clamp(i + delta, count: items.count)
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: 160) else { return nil }
        return NSImage(contentsOf: url)
    }
}
