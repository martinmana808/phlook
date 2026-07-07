import Foundation
import ImageIO

/// Bitmask of detectable "kinds" for an image — screenshot, selfie, etc.
/// Stored verbatim as `kind_flags` in the index (see MediaIndex migration v5).
public struct KindFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let screenshot = KindFlags(rawValue: 1)
    public static let selfie = KindFlags(rawValue: 2)
}

/// Pure, ImageIO-backed detection of screenshot/selfie kinds from embedded
/// metadata — no ML, no network. Rules (see design spec "Detection rules"):
///   - screenshot: PNG with no TIFF Make/Model (no camera EXIF), OR EXIF
///     UserComment == "Screenshot".
///   - selfie: EXIF LensModel contains "front" (case-insensitive).
/// Flags OR-combine. Never called for non-image files.
public enum KindDetector {
    /// Opens the file once via ImageIO and derives flags. Used by the
    /// background backfill pass, where no properties dict is already at hand.
    public static func flags(forImageAt url: URL) -> KindFlags {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [] }
        return flags(fromProperties: props, ext: url.pathExtension.lowercased())
    }

    /// Derives flags from an already-loaded properties dictionary (e.g. the
    /// one `LibraryScanner.imageMeta` already opened for width/height/date),
    /// so full-extract never opens the image source twice.
    public static func flags(fromProperties props: [CFString: Any], ext: String) -> KindFlags {
        var result: KindFlags = []
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        if ext == "png", tiff?[kCGImagePropertyTIFFMake] == nil, tiff?[kCGImagePropertyTIFFModel] == nil {
            result.insert(.screenshot)
        }
        if let comment = exif?[kCGImagePropertyExifUserComment] as? String, comment == "Screenshot" {
            result.insert(.screenshot)
        }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String,
           lens.lowercased().contains("front") {
            result.insert(.selfie)
        }
        return result
    }
}
