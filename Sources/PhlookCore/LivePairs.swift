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
        struct Group { var images: [String] = []; var shortVideos: [String] = [] }
        var groups: [String: Group] = [:]
        for item in items {
            let key = stem(item.path)
            if item.fileType == "image" {
                groups[key, default: Group()].images.append(item.path)
            } else if item.fileType == "video",
                      let d = item.duration, d > 0, d <= maxMotionSeconds {
                groups[key, default: Group()].shortVideos.append(item.path)
            }
        }
        var hidden: Set<String> = []
        var byImage: [String: String] = [:]
        // Only an unambiguous group — exactly one still, exactly one short
        // motion file — forms a live pair. Anything else stays fully visible.
        for group in groups.values where group.images.count == 1 && group.shortVideos.count == 1 {
            hidden.insert(group.shortVideos[0])
            byImage[group.images[0]] = group.shortVideos[0]
        }
        return LivePairs(hiddenVideoPaths: hidden, videoByImagePath: byImage)
    }
}
