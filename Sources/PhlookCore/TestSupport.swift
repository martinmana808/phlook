import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import CoreVideo

public enum TestFixtures {
    public static func writeJPEG(at url: URL, width: Int, height: Int, captureDate: Date? = nil) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw NSError(domain: "TestFixtures", code: 1) }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "TestFixtures", code: 2)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "TestFixtures", code: 3)
        }
        var properties: CFDictionary?
        if let captureDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: captureDate)]
            properties = [kCGImagePropertyExifDictionary: exif] as CFDictionary
        }
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixtures", code: 4)
        }
    }

    /// Writes a real, playable QuickTime movie of solid frames (H.264, 10fps).
    /// `creationDate` (e.g. "2026-03-08T13:56:58-0300") is embedded as
    /// com.apple.quicktime.creationdate when provided.
    public static func writeQuickTimeMovie(
        at url: URL, duration: Double = 1.0, width: Int = 64, height: Int = 48,
        creationDate: String? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        if let creationDate {
            let md = AVMutableMetadataItem()
            md.identifier = .quickTimeMetadataCreationDate
            md.value = creationDate as NSString
            writer.metadata = [md]
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "TestFixtures", code: 10)
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "TestFixtures", code: 11) }

        let fps = 10
        let frames = max(1, Int((duration * Double(fps)).rounded()))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pixelBuffer,
                           withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "TestFixtures", code: 12)
        }
    }
}
