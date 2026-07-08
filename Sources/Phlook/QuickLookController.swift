import AppKit
import Quartz

/// Owns the native Quick Look panel for the grid's "space bar" preview
/// (design spec #12). A single shared instance because `QLPreviewPanel` is
/// itself a system-wide singleton (`QLPreviewPanel.shared()`); we just supply
/// its data source and toggle visibility.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()

    private var urls: [NSURL] = []

    /// Toggles the panel for the given URLs: closes it if already open,
    /// otherwise loads `urls` and opens it. No-op if `urls` is empty.
    func toggle(urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls.map { $0 as NSURL }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index]
    }
}
