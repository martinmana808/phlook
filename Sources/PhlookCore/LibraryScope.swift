import Foundation

/// Top-level library scopes shown in the sidebar. Every scope except
/// `.hidden` implicitly excludes hidden items; `.hidden` shows only hidden
/// items. Live-photo stills count as `.photos` (their paired motion file is
/// never independently visible — see `LivePairs.hiddenVideoPaths`).
public enum LibraryScope: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case live = "Live Photos"
    case screenshots = "Screenshots"
    case selfies = "Selfies"
    case hidden = "Hidden"

    public var id: String { rawValue }

    /// `livePairs` is needed for `.live` (image must have a paired motion
    /// file); `.photos` counts live stills as photos with no extra lookup.
    public func matches(_ item: MediaItem, livePairs: LivePairs) -> Bool {
        if self == .hidden { return item.hidden }
        guard !item.hidden else { return false }
        switch self {
        case .all:
            return true
        case .photos:
            return item.fileType == "image"
        case .videos:
            return item.fileType == "video"
        case .live:
            return item.fileType == "image" && livePairs.videoPath(forImagePath: item.path) != nil
        case .screenshots:
            return item.fileType == "image" && KindFlags(rawValue: item.kindFlags).contains(.screenshot)
        case .selfies:
            return item.fileType == "image" && KindFlags(rawValue: item.kindFlags).contains(.selfie)
        case .hidden:
            return item.hidden   // unreachable (handled above); exhaustiveness
        }
    }
}
