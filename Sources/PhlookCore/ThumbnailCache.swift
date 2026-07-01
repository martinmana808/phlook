import Foundation
import QuickLookThumbnailing
import AppKit

public final class ThumbnailCache {
    private let cacheDir: URL
    public init(cacheDir: URL) {
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func thumbnailURL(for item: MediaItem, size: Int) async -> URL? {
        let key = "\(item.hash ?? UUID().uuidString)_\(size).png"
        let dest = cacheDir.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path),
            size: CGSize(width: size, height: size),
            scale: 2.0,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              let tiff = rep.nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        try? png.write(to: dest)
        return dest
    }
}
