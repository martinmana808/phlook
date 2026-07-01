import SwiftUI
import PhlookCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isIndexing = false
    let service: IndexingService

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/PHLOOK")
        service = IndexingService(root: root)
    }

    func load() {
        let service = self.service
        isIndexing = true
        Task.detached {
            // 1. Show whatever is already indexed immediately — instant on relaunch.
            let cached = (try? service.items()) ?? []
            await MainActor.run { self.items = cached }

            // 2. Refresh the index in the background, then update the grid.
            _ = try? service.reindex()
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.items = fresh
                self.isIndexing = false
            }
        }
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: 160) else { return nil }
        return NSImage(contentsOf: url)
    }
}
