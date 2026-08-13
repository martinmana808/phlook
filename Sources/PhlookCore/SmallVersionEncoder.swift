// Sources/PhlookCore/SmallVersionEncoder.swift
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics

public enum SmallVersionError: Error { case unreadable, encodeFailed }

public protocol SmallVersionEncoding {
    /// Writes a ~10% "small version" of `original` into `proxyDir`, keeping the
    /// base name. Returns the written URL. `fileType` is "image" or "video".
    func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL
}

public struct SmallVersionEncoder: SmallVersionEncoding {
    public init() {}

    // Tunables
    static let targetRatio = 0.10          // aim ~10% of source
    static let keepOriginalThreshold = 0.85 // if result >= 85% of source, it's already efficient → keep original
    // video
    static let videoLongEdge = 1280
    static let videoShortEdge = 720
    static let videoMinBitrate = 500_000
    static let videoMaxBitrate = 6_000_000
    static let audioBitrate = 96_000
    // photo — quality-first: photos are a tiny fraction of total library GB
    // (~7%), so keep them large and good-looking rather than squeezing to 10%.
    static let photoLongEdge = 2560
    static let photoQuality = 0.82

    static func ffmpegPath() -> String? {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // Pure, unit-tested helpers
    static func targetVideoBitrate(sourceBytes: Int, duration: Double) -> Int {
        guard duration > 0 else { return videoMinBitrate }
        let targetTotalBits = Double(sourceBytes) * 8.0 * targetRatio
        let videoBits = targetTotalBits / duration - Double(audioBitrate)
        return max(videoMinBitrate, min(videoMaxBitrate, Int(videoBits)))
    }
    static func shouldKeepOriginal(outBytes: Int, sourceBytes: Int) -> Bool {
        sourceBytes > 0 && Double(outBytes) >= Double(sourceBytes) * keepOriginalThreshold
    }

    public func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let base = original.deletingPathExtension().lastPathComponent
        return fileType == "video"
            ? try makeVideo(original, base: base, proxyDir: proxyDir)
            : try makePhoto(original, base: base, proxyDir: proxyDir)
    }

    private func bytes(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    private func keepOriginal(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension(original.pathExtension)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: original, to: out)
        return out
    }

    // MARK: Photo — ImageIO downscale to a generous long edge at high JPEG quality
    private func makePhoto(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(original as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { throw SmallVersionError.unreadable }
        let srcBytes = bytes(original)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.photoLongEdge
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw SmallVersionError.encodeFailed
        }
        guard let data = jpegData(thumb, quality: Self.photoQuality) else {
            throw SmallVersionError.encodeFailed
        }
        // Already-efficient small original (e.g. a tiny HEIC) the JPEG can't beat → keep it.
        if Self.shouldKeepOriginal(outBytes: data.count, sourceBytes: srcBytes) {
            return try keepOriginal(original, base: base, proxyDir: proxyDir)
        }
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension("jpg")
        try data.write(to: out)
        return out
    }

    private func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Video — ffmpeg, bitrate targeted for ~10%, downscaled to fit 1280x720
    private func makeVideo(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: out)
        let srcBytes = bytes(original)
        let asset = AVURLAsset(url: original)
        let duration = CMTimeGetSeconds(asset.duration)
        // Not a real video (audio-only / unreadable) → keep original bytes (legitimately can't shrink)
        guard asset.tracks(withMediaType: .video).first != nil, duration > 0 else {
            return try keepOriginal(original, base: base, proxyDir: proxyDir)
        }
        // No encoder available → FAIL (loud): don't silently keep full-size for every video.
        guard let ffmpeg = Self.ffmpegPath() else { throw SmallVersionError.encodeFailed }
        let bitrate = Self.targetVideoBitrate(sourceBytes: srcBytes, duration: duration)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-nostdin", "-y", "-i", original.path,
            "-vf", "scale=\(Self.videoLongEdge):\(Self.videoShortEdge):force_original_aspect_ratio=decrease:force_divisible_by=2",
            "-c:v", "libx264", "-b:v", "\(bitrate)", "-maxrate", "\(bitrate)", "-bufsize", "\(bitrate * 2)",
            "-preset", "veryfast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "\(Self.audioBitrate)",
            "-movflags", "+faststart",
            out.path
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw SmallVersionError.encodeFailed }
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            throw SmallVersionError.encodeFailed   // real failure → item stays unshrunk (original kept upstream), retryable
        }
        // Already-efficient clip the encode couldn't beat → keep original.
        if Self.shouldKeepOriginal(outBytes: bytes(out), sourceBytes: srcBytes) {
            try? FileManager.default.removeItem(at: out)
            return try keepOriginal(original, base: base, proxyDir: proxyDir)
        }
        return out
    }
}
