import Foundation
import AVFoundation

/// Fills duration, capture date, and pixel dimensions for video rows the
/// scanner could not populate. Sequential by design — it runs behind the
/// indexing chip and must not saturate I/O. A per-file failure marks the row
/// with the -1 sentinel and never aborts the batch.
public struct VideoMetadataEnricher {
    public init() {}

    @discardableResult
    public func enrich(index: MediaIndex, onProgress: (@Sendable (Int) -> Void)? = nil) async -> Int {
        let pending = (try? index.videosNeedingEnrichment()) ?? []
        var processed = 0
        for var item in pending {
            let url = URL(fileURLWithPath: item.path)
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.isNumeric {
                item.duration = max(0, CMTimeGetSeconds(duration))
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    item.width = Int(abs(rect.width).rounded())
                    item.height = Int(abs(rect.height).rounded())
                }
                if item.dateTaken == nil {
                    item.dateTaken = await CaptureDateExtractor().captureDate(for: url).date
                }
            } else {
                item.duration = -1   // unreadable: tried, don't retry
            }
            item.lastScanned = Date()
            try? index.upsert(item)
            processed += 1
            if processed % 200 == 0 { onProgress?(processed) }
        }
        return processed
    }
}
