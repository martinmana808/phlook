import SwiftUI
import PhlookCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    let service: IndexingService

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/PHLOOK")
        service = IndexingService(root: root)
    }

    func load() {
        let service = self.service
        Task.detached {
            _ = try? service.reindex()
            let items = (try? service.items()) ?? []
            await MainActor.run { self.items = items }
        }
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: 160) else { return nil }
        return NSImage(contentsOf: url)
    }
}
