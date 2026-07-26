// Sources/PhlookCore/SmallVersionEncoder.swift
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public enum SmallVersionError: Error { case unreadable, encodeFailed }

public protocol SmallVersionEncoding {
    /// Writes a ~10% "small version" of `original` into `proxyDir`, keeping the
    /// base name. Returns the written URL. `fileType` is "image" or "video".
    func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL
}

public struct SmallVersionEncoder: SmallVersionEncoding {
    public init() {}

    private static let longEdge = 2048
    private static let jpegQuality = 0.55
    private static let videoKeepThreshold = 0.15   // export ≥15% of source ⇒ keep original bytes

    public func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let base = original.deletingPathExtension().lastPathComponent
        if fileType == "video" {
            return try makeVideo(original, base: base, proxyDir: proxyDir)
        } else {
            return try makePhoto(original, base: base, proxyDir: proxyDir)
        }
    }

    // MARK: Photo (ImageIO, synchronous)

    private func makePhoto(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(original as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { throw SmallVersionError.unreadable }
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension("jpg")
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: Self.longEdge
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw SmallVersionError.encodeFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SmallVersionError.encodeFailed
        }
        CGImageDestinationAddImage(dest, thumb,
            [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SmallVersionError.encodeFailed }
        return out
    }

    // MARK: Video (AVFoundation, 720p H.264; size-guard passthrough)

    private func makeVideo(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: original)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw SmallVersionError.encodeFailed
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()
        guard export.status == .completed else { throw SmallVersionError.encodeFailed }

        // Size guard: if the "small" version isn't meaningfully smaller, keep the original bytes.
        let inSize = (try? FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int) ?? nil
        let outSize = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? nil
        if let i = inSize, let o = outSize, Double(o) >= Double(i) * Self.videoKeepThreshold {
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.copyItem(at: original, to: out)
        }
        return out
    }
}
