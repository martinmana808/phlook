import Foundation

/// Display-ready metadata for the viewer sidebar. Pure assembly — no UI.
public struct MediaDetails: Equatable {
    public let filename: String
    public let dateTaken: String    // formatted, or "Unknown"
    public let dimensions: String?  // "4032 × 3024"
    public let duration: String?    // formatted, videos only
    public let fileSize: String?    // "2.4 MB"; nil when the file is missing
    public let kind: String         // "HEIC image", "QuickTime movie", …
    public let path: String

    static let kindByExtension: [String: String] = [
        "jpg": "JPEG image", "jpeg": "JPEG image", "heic": "HEIC image",
        "heif": "HEIF image", "png": "PNG image", "tiff": "TIFF image",
        "gif": "GIF image", "webp": "WebP image", "dng": "RAW (DNG) image",
        "mov": "QuickTime movie", "mp4": "MPEG-4 movie", "m4v": "MPEG-4 movie",
        "avi": "AVI movie",
    ]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func from(item: MediaItem) -> MediaDetails {
        let url = URL(fileURLWithPath: item.path)
        let ext = url.pathExtension.lowercased()
        let kind = kindByExtension[ext]
            ?? "\(ext.uppercased()) \(item.fileType == "video" ? "movie" : "image")"

        var sizeText: String?
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.size] as? Int64 {
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        var dims: String?
        if let w = item.width, let h = item.height { dims = "\(w) × \(h)" }

        return MediaDetails(
            filename: url.lastPathComponent,
            dateTaken: item.dateTaken.map { dateFormatter.string(from: $0) } ?? "Unknown",
            dimensions: dims,
            duration: item.fileType == "video" ? DurationFormatter.string(seconds: item.duration) : nil,
            fileSize: sizeText,
            kind: kind,
            path: item.path
        )
    }
}
