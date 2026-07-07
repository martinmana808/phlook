import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import CoreVideo

public enum TestFixtures {
    /// Renders a plain solid-color bitmap shared by the JPEG/PNG fixture writers.
    private static func solidImage(width: Int, height: Int) throws -> CGImage {
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
        return cgImage
    }

    /// Builds the TIFF/Exif property dictionaries used by both fixture
    /// writers. `tiffMake` round-trips under `kCGImagePropertyTIFFDictionary`
    /// for both JPEG and PNG destinations; `lensModel`/`userComment` live
    /// under the Exif dictionary (verified via CGImageSourceCopyProperties
    /// round-trip — plain top-level Exif keys, no ExifAux needed).
    private static func imageProperties(
        captureDate: Date?, tiffMake: String?, lensModel: String?, userComment: String?
    ) -> CFDictionary? {
        var tiffDict: [CFString: Any] = [:]
        if let tiffMake { tiffDict[kCGImagePropertyTIFFMake] = tiffMake }

        var exifDict: [CFString: Any] = [:]
        if let captureDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            exifDict[kCGImagePropertyExifDateTimeOriginal] = f.string(from: captureDate)
        }
        if let lensModel { exifDict[kCGImagePropertyExifLensModel] = lensModel }
        if let userComment { exifDict[kCGImagePropertyExifUserComment] = userComment }

        var properties: [CFString: Any] = [:]
        if !tiffDict.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiffDict }
        if !exifDict.isEmpty { properties[kCGImagePropertyExifDictionary] = exifDict }
        return properties.isEmpty ? nil : properties as CFDictionary
    }

    public static func writeJPEG(
        at url: URL, width: Int, height: Int, captureDate: Date? = nil,
        tiffMake: String? = nil, lensModel: String? = nil, userComment: String? = nil
    ) throws {
        let cgImage = try solidImage(width: width, height: height)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "TestFixtures", code: 3)
        }
        let properties = imageProperties(
            captureDate: captureDate, tiffMake: tiffMake, lensModel: lensModel, userComment: userComment)
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixtures", code: 4)
        }
    }

    /// Writes a PNG fixture, optionally embedding a TIFF Make (to opt OUT of
    /// the screenshot rule, which is "PNG with no camera EXIF") and/or a
    /// LensModel (for combined screenshot+selfie fixtures).
    public static func writePNG(
        at url: URL, width: Int, height: Int, tiffMake: String? = nil, lensModel: String? = nil
    ) throws {
        let cgImage = try solidImage(width: width, height: height)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "TestFixtures", code: 5)
        }
        let properties = imageProperties(
            captureDate: nil, tiffMake: tiffMake, lensModel: lensModel, userComment: nil)
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixtures", code: 6)
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
                guard writer.status == .writing else {
                    throw writer.error ?? NSError(domain: "TestFixtures", code: 13)
                }
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
