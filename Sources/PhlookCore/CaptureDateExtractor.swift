import Foundation
import ImageIO
import AVFoundation

/// Resolves the capture date for a media file:
/// images: EXIF DateTimeOriginal → DateTimeDigitized → TIFF DateTime;
/// videos: com.apple.quicktime.creationdate (offset-preserving) → container creationDate;
/// both:   file creation date, flagged as .fileCreation.
public struct CaptureDateExtractor {
    public init() {}

    public func captureDate(for url: URL) async -> CaptureDate {
        let ext = url.pathExtension.lowercased()
        if LibraryScanner.imageExts.contains(ext), let cd = Self.exifDate(url) {
            return cd
        }
        if LibraryScanner.videoExts.contains(ext), let cd = await Self.videoDate(url) {
            return cd
        }
        let birth = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        return CaptureDate(date: birth, timeZone: .current, source: .fileCreation)
    }

    // EXIF dates are local wall time with no zone; parse and render in the
    // same zone (.current) so the filename reproduces the wall time exactly.
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func exifDate(_ url: URL) -> CaptureDate? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
        ]
        for case let s? in candidates {
            if let date = exifFormatter.date(from: s) {
                return CaptureDate(date: date, timeZone: .current, source: .exif)
            }
        }
        return nil
    }

    static func videoDate(_ url: URL) async -> CaptureDate? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let items = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .quickTimeMetadataCreationDate)
        if let item = items.first,
           let s = try? await item.load(.stringValue),
           let cd = CaptureDate.parseQuickTime(s) {
            return cd
        }
        if let item = try? await asset.load(.creationDate),
           let d = try? await item.load(.dateValue) {
            return CaptureDate(date: d, timeZone: .current, source: .videoMetadata)
        }
        return nil
    }
}
