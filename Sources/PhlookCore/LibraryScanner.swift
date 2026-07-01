import Foundation
import ImageIO
import CryptoKit

public struct LibraryScanner {
    public let root: URL
    public init(root: URL) { self.root = root }

    static let imageExts: Set<String> = ["jpg","jpeg","heic","heif","png","tiff","gif","webp","dng"]
    static let videoExts: Set<String> = ["mov","mp4","m4v","avi"]

    public func scan() throws -> [MediaItem] {
        var results: [MediaItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            let isImage = Self.imageExts.contains(ext)
            let isVideo = Self.videoExts.contains(ext)
            guard isImage || isVideo else { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let (w, h, taken): (Int?, Int?, Date?) = isImage ? Self.imageMeta(url) : (nil, nil, nil)
            let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            results.append(MediaItem(
                path: url.path, hash: Self.quickHash(url),
                dateTaken: taken ?? fileDate,
                fileType: isImage ? "image" : "video",
                width: w, height: h, lastScanned: Date()))
        }
        return results
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func imageMeta(_ url: URL) -> (Int?, Int?, Date?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil) }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = Self.exifDateFormatter.date(from: s)
        }
        return (w, h, date)
    }

    static func quickHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1_048_576)) ?? Data()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var hasher = SHA256()
        hasher.update(data: data)
        withUnsafeBytes(of: size) { hasher.update(data: Data($0)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
