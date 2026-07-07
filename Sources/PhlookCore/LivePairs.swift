import Foundation

/// Index-level pairing of Live Photos: a still and its ~3s motion file share
/// a filename stem (ingest preserves it). Pure computation — no file or DB
/// changes; an unenriched video (nil duration) simply pairs after enrichment.
public struct LivePairs: Equatable {
    public static let maxMotionSeconds = 6.5
    public static let empty = LivePairs(hiddenVideoPaths: [], videoByImagePath: [:])

    public let hiddenVideoPaths: Set<String>
    private let videoByImagePath: [String: String]

    init(hiddenVideoPaths: Set<String>, videoByImagePath: [String: String]) {
        self.hiddenVideoPaths = hiddenVideoPaths
        self.videoByImagePath = videoByImagePath
    }

    public func videoPath(forImagePath path: String) -> String? {
        videoByImagePath[path]
    }

    /// Stem = full path minus the final extension, so pairing is per-directory
    /// and tolerates dots inside the name ("archive.2024.HEIC").
    private static func stem(_ path: String) -> String {
        (path as NSString).deletingPathExtension
    }

    public static func compute(items: [MediaItem]) -> LivePairs {
        var imageByStem: [String: String] = [:]
        for item in items where item.fileType == "image" {
            imageByStem[stem(item.path)] = item.path
        }
        var hidden: Set<String> = []
        var byImage: [String: String] = [:]
        for item in items where item.fileType == "video" {
            guard let d = item.duration, d > 0, d <= maxMotionSeconds,
                  let imagePath = imageByStem[stem(item.path)] else { continue }
            hidden.insert(item.path)
            byImage[imagePath] = item.path
        }
        return LivePairs(hiddenVideoPaths: hidden, videoByImagePath: byImage)
    }
}
