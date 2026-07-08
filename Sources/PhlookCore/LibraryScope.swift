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
    // Vision scene categories (#11) — one scope per curated `SceneCategory`
    // bit, mirroring the screenshots/selfies kind scopes above.
    case categoryNature = "Nature"
    case categoryFood = "Food"
    case categoryDocument = "Documents"
    case categoryAnimal = "Animals"
    case categoryVehicle = "Vehicles"
    case categoryPlant = "Plants"
    case categoryWater = "Water"
    case categoryBuilding = "Buildings"
    case categorySky = "Sky"
    case categoryArt = "Art"
    case categoryText = "Text"
    case categoryBeach = "Beach"

    public var id: String { rawValue }

    /// The `SceneCategory` this scope filters on, for the Categories scopes
    /// only (nil for every other scope).
    public var sceneCategory: SceneCategory? {
        switch self {
        case .categoryNature: return .nature
        case .categoryFood: return .food
        case .categoryDocument: return .document
        case .categoryAnimal: return .animal
        case .categoryVehicle: return .vehicle
        case .categoryPlant: return .plant
        case .categoryWater: return .water
        case .categoryBuilding: return .building
        case .categorySky: return .sky
        case .categoryArt: return .art
        case .categoryText: return .text
        case .categoryBeach: return .beach
        default: return nil
        }
    }

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
        case .categoryNature, .categoryFood, .categoryDocument, .categoryAnimal,
             .categoryVehicle, .categoryPlant, .categoryWater, .categoryBuilding,
             .categorySky, .categoryArt, .categoryText, .categoryBeach:
            guard let category = sceneCategory else { return false }
            // -1 is the "not yet classified" sentinel (see MediaIndex
            // migration v6) — its all-ones bit pattern must never appear to
            // match every category.
            guard item.sceneFlags >= 0 else { return false }
            return item.fileType == "image" && SceneFlags.contains(item.sceneFlags, category)
        }
    }
}
