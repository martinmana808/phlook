import Foundation
import ImageIO
import CryptoKit

public struct LibraryScanner {
    public let root: URL
    public init(root: URL) { self.root = root }

    static let imageExts: Set<String> = ["jpg","jpeg","heic","heif","png","tiff","gif","webp","dng"]
    static let videoExts: Set<String> = ["mov","mp4","m4v","avi"]

    /// Compatibility wrapper: always full-rescan (no known stamps).
    public func scan() throws -> [MediaItem] {
        try scan(known: [:]).changed
    }

    public func scan(known: [String: FileStamp] = [:]) throws -> (changed: [MediaItem], allPaths: Set<String>) {
        var changed: [MediaItem] = []
        var allPaths: Set<String> = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return ([], []) }
        for case let rawURL as URL in e {
            // NSDirectoryEnumerator returns entries via the resolved-device
            // path (e.g. "/private/var/..."), while callers construct paths
            // from the nominal URL (e.g. "/var/..."). resolvingSymlinksInPath()
            // is documented to translate /private/{tmp,var,etc} back to the
            // canonical short form, keeping path strings consistent with
            // what callers (and this scanner's own `known` stamp keys) expect.
            let url = rawURL.resolvingSymlinksInPath()
            let ext = url.pathExtension.lowercased()
            let isImage = Self.imageExts.contains(ext)
            let isVideo = Self.videoExts.contains(ext)
            guard isImage || isVideo else { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            guard let values = try? rawURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            allPaths.insert(url.path)
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate ?? Date.distantPast
            if let stamp = known[url.path], stamp.matches(size: size, modifiedAt: mtime) {
                continue   // unchanged: row stays untouched
            }
            let (w, h, taken): (Int?, Int?, Date?) = isImage ? Self.imageMeta(rawURL) : (nil, nil, nil)
            changed.append(MediaItem(
                path: url.path, hash: Self.quickHash(rawURL),
                dateTaken: isImage ? (taken ?? values.creationDate) : nil,
                fileType: isImage ? "image" : "video",
                width: w, height: h, lastScanned: Date(),
                duration: nil, fileSize: size, modifiedAt: mtime))
        }
        return (changed, allPaths)
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
