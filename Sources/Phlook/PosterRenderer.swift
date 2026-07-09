import AppKit
import AVFoundation
import CoreGraphics

/// Renders a still frame from a Live Photo's paired motion file (MOV) at a
/// chosen time offset — the non-destructive poster mechanism (#10). Never
/// writes to the motion file or the original HEIC; this only reads frames on
/// demand for display.
enum PosterRenderer {
    /// Extracts the frame at `time` seconds into the movie at `motionPath`,
    /// downsampled to fit within `maxPixel` on the longest side. Returns nil
    /// on any failure (missing file, unreadable asset, out-of-range time).
    static func posterImage(motionPath: String, time: Double, maxPixel: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: motionPath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        // macOS 13+ async image(at:) — used directly rather than the older
        // completion-handler `generateCGImagesAsynchronously` API.
        guard let cgImage = try? await generator.image(at: cmTime).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
