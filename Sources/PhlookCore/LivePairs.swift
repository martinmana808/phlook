import Foundation

/// Index-level pairing of Live Photos: a still and its ~3s motion file share
/// a filename core (ingest may shift timestamps and append a motion-resource
/// suffix). Pure computation — no file or DB changes; an unenriched video
/// (nil duration) simply pairs after enrichment.
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

    /// Core = filename minus extension, minus one leading ingest timestamp
    /// prefix, minus one trailing "_3" (osxphotos motion-resource suffix).
    static func core(_ path: String) -> (dir: String, core: String, fullStem: String) {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let fullStem = (ns.lastPathComponent as NSString).deletingPathExtension
        var core = fullStem
        if let range = core.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_"#,
                                  options: .regularExpression) {
            core.removeSubrange(range)
        }
        if core.hasSuffix("_3") { core.removeLast(2) }
        return (dir, core, fullStem)
    }

    static func isUUIDShaped(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                options: .regularExpression) != nil
    }

    public static func compute(items: [MediaItem]) -> LivePairs {
        struct Candidate { let path: String; let fullStem: String }
        struct Group { var images: [Candidate] = []; var shortVideos: [Candidate] = [] }
        var groups: [String: Group] = [:]
        for item in items {
            let (dir, itemCore, fullStem) = core(item.path)
            let key = dir + "/" + itemCore
            let candidate = Candidate(path: item.path, fullStem: fullStem)
            if item.fileType == "image" {
                groups[key, default: Group()].images.append(candidate)
            } else if item.fileType == "video",
                      let d = item.duration, d > 0, d <= maxMotionSeconds {
                groups[key, default: Group()].shortVideos.append(candidate)
            }
        }
        var hidden: Set<String> = []
        var byImage: [String: String] = [:]
        // Only an unambiguous group — exactly one still, exactly one short
        // motion file — forms a live pair, and only when the pairing is
        // corroborated: either identical full stems, or a UUID-shaped core
        // (osxphotos-style naming where timestamps may drift between the
        // still and its motion resource).
        for (key, group) in groups where group.images.count == 1 && group.shortVideos.count == 1 {
            let image = group.images[0]
            let video = group.shortVideos[0]
            let keyComponents = (key as NSString).lastPathComponent
            guard image.fullStem == video.fullStem || isUUIDShaped(keyComponents) else { continue }
            hidden.insert(video.path)
            byImage[image.path] = video.path
        }
        return LivePairs(hiddenVideoPaths: hidden, videoByImagePath: byImage)
    }
}
