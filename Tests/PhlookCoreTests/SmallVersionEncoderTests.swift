import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics
@testable import PhlookCore

struct SmallVersionEncoderTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Pure helpers

    @Test func targetVideoBitrateTypicalCase() {
        // 100MB over 100s @10% => 80Mbit/100s = 800kbps minus 96k audio = 704kbps
        let bitrate = SmallVersionEncoder.targetVideoBitrate(sourceBytes: 100_000_000, duration: 100)
        #expect(bitrate == 704_000)
    }

    @Test func targetVideoBitrateClampsToMinimum() {
        // Tiny source, long duration → below floor
        let bitrate = SmallVersionEncoder.targetVideoBitrate(sourceBytes: 1_000_000, duration: 600)
        #expect(bitrate == 500_000)
    }

    @Test func targetVideoBitrateClampsToMaximum() {
        // Huge source, short duration → above ceiling
        let bitrate = SmallVersionEncoder.targetVideoBitrate(sourceBytes: 5_000_000_000, duration: 5)
        #expect(bitrate == 6_000_000)
    }

    @Test func targetVideoBitrateZeroDurationReturnsMinimum() {
        let bitrate = SmallVersionEncoder.targetVideoBitrate(sourceBytes: 100_000_000, duration: 0)
        #expect(bitrate == 500_000)
    }

    @Test func shouldKeepOriginalWhenOutputIsAtLeast85Percent() {
        #expect(SmallVersionEncoder.shouldKeepOriginal(outBytes: 90, sourceBytes: 100) == true)
    }

    @Test func shouldNotKeepOriginalWhenOutputIsMeaningfullySmaller() {
        #expect(SmallVersionEncoder.shouldKeepOriginal(outBytes: 50, sourceBytes: 100) == false)
    }

    @Test func shouldKeepOriginalFalseWhenSourceIsZero() {
        #expect(SmallVersionEncoder.shouldKeepOriginal(outBytes: 10, sourceBytes: 0) == false)
    }

    // MARK: - Photo (real)

    /// Write a real PNG filled with true random noise so it is large and
    /// incompressible — guaranteeing the encoder takes the downscale+JPEG path
    /// (not the keep-original passthrough that a smooth image would trigger).
    private func writeNoisyPNG(_ url: URL, w: Int, h: Int) throws {
        let bytesPerRow = w * 4
        var raw = Data(count: bytesPerRow * h)
        raw.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: raw as CFData)!
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: bytesPerRow, space: cs,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }

    private func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    @Test func photoIsDownscaledAndEncodedAsJpeg() throws {
        let dir = try tmp()
        let src = dir.appendingPathComponent("big.png")
        try writeNoisyPNG(src, w: 4000, h: 3000)
        let proxyDir = dir.appendingPathComponent("proxy")

        let out = try SmallVersionEncoder().makeSmallVersion(from: src, fileType: "image", into: proxyDir)

        #expect(out.pathExtension == "jpg")
        #expect(out.deletingPathExtension().lastPathComponent == "big")
        let (w, h) = try #require(pixelSize(out))
        #expect(max(w, h) <= 2560)                     // long edge clamped
        let outSize = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        let inSize  = try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int
        #expect(outSize < inSize)                      // smaller than source
    }

    @Test func unreadableSourceThrows() throws {
        let dir = try tmp()
        #expect(throws: (any Error).self) {
            try SmallVersionEncoder().makeSmallVersion(
                from: dir.appendingPathComponent("nope.png"), fileType: "image",
                into: dir.appendingPathComponent("proxy"))
        }
    }

    // MARK: - Video (real, requires ffmpeg)

    /// Write a ~3s 1920x1080 H.264 video with per-frame varying noisy content so it can't
    /// trivially compress away, using AVAssetWriter.
    private func writeTestVideo(_ url: URL, width: Int, height: Int, fps: Int32, frameCount: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "video-writer")
        let sem = DispatchSemaphore(value: 0)
        var frame = 0
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData && frame < frameCount {
                var pxBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pxBuffer)
                guard let buffer = pxBuffer else { break }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                    var rng = SplitMix64(seed: UInt64(frame) &* 2654435761)
                    let ptr = base.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<height {
                        let rowStart = y * rowBytes
                        for x in stride(from: 0, to: width * 4, by: 4) {
                            let v = rng.next()
                            ptr[rowStart + x] = UInt8(truncatingIfNeeded: v)
                            ptr[rowStart + x + 1] = UInt8(truncatingIfNeeded: v >> 8)
                            ptr[rowStart + x + 2] = UInt8(truncatingIfNeeded: v >> 16)
                            ptr[rowStart + x + 3] = 255
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let time = CMTime(value: CMTimeValue(frame), timescale: fps)
                adaptor.append(buffer, withPresentationTime: time)
                frame += 1
            }
            if frame >= frameCount {
                input.markAsFinished()
                writer.finishWriting { sem.signal() }
            }
        }
        sem.wait()
    }

    /// Minimal fast PRNG for per-pixel noise generation.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func videoTrackSize(_ url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let size = try? await track.load(.naturalSize) else { return nil }
        return size
    }

    @Test func videoIsShrunkAndDownscaled() async throws {
        guard SmallVersionEncoder.ffmpegPath() != nil else { return } // skip gracefully without ffmpeg

        let dir = try tmp()
        let src = dir.appendingPathComponent("big.mp4")
        try writeTestVideo(src, width: 1920, height: 1080, fps: 30, frameCount: 90)
        let proxyDir = dir.appendingPathComponent("proxy")

        let out = try SmallVersionEncoder().makeSmallVersion(from: src, fileType: "video", into: proxyDir)

        #expect(FileManager.default.fileExists(atPath: out.path))
        let outSize = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        let inSize  = try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int
        #expect(inSize > 0)
        #expect(outSize < Int(Double(inSize) * 0.6))

        let size = try #require(await videoTrackSize(out))
        let w = Int(abs(size.width)), h = Int(abs(size.height))
        #expect(max(w, h) <= 1280 && min(w, h) <= 720)
    }
}
