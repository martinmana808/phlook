import Foundation

/// Curated scene/object categories surfaced from Vision's ~1000-label
/// taxonomy (see `SceneClassifier`). Stored as a bitmask in `scene_flags`
/// (see MediaIndex migration v6) — mirrors `KindFlags`'s shape.
public enum SceneCategory: Int, CaseIterable {
    case nature = 1        // 1 << 0
    case food = 2           // 1 << 1
    case document = 4        // 1 << 2
    case animal = 8          // 1 << 3
    case vehicle = 16         // 1 << 4
    case plant = 32          // 1 << 5
    case water = 64          // 1 << 6
    case building = 128       // 1 << 7
    case sky = 256           // 1 << 8
    case art = 512           // 1 << 9
    case text = 1024          // 1 << 10
    case beach = 2048         // 1 << 11

    public var displayName: String {
        switch self {
        case .nature: return "Nature"
        case .food: return "Food"
        case .document: return "Documents"
        case .animal: return "Animals"
        case .vehicle: return "Vehicles"
        case .plant: return "Plants"
        case .water: return "Water"
        case .building: return "Buildings"
        case .sky: return "Sky"
        case .art: return "Art"
        case .text: return "Text"
        case .beach: return "Beach"
        }
    }

    public var symbol: String {
        switch self {
        case .nature: return "leaf"
        case .food: return "fork.knife"
        case .document: return "doc.text"
        case .animal: return "pawprint"
        case .vehicle: return "car"
        case .plant: return "leaf.fill"
        case .water: return "drop"
        case .building: return "building.2"
        case .sky: return "cloud.sun"
        case .art: return "paintpalette"
        case .text: return "textformat"
        case .beach: return "beach.umbrella"
        }
    }
}

/// Bitmask helpers over `SceneCategory`, mirroring `KindFlags`'s OptionSet
/// shape. Kept as raw `Int` at the storage layer (see `MediaItem.sceneFlags`)
/// since the value also carries the -1 "not yet classified" sentinel, which
/// an OptionSet can't represent directly.
public struct SceneFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let nature = SceneFlags(rawValue: SceneCategory.nature.rawValue)
    public static let food = SceneFlags(rawValue: SceneCategory.food.rawValue)
    public static let document = SceneFlags(rawValue: SceneCategory.document.rawValue)
    public static let animal = SceneFlags(rawValue: SceneCategory.animal.rawValue)
    public static let vehicle = SceneFlags(rawValue: SceneCategory.vehicle.rawValue)
    public static let plant = SceneFlags(rawValue: SceneCategory.plant.rawValue)
    public static let water = SceneFlags(rawValue: SceneCategory.water.rawValue)
    public static let building = SceneFlags(rawValue: SceneCategory.building.rawValue)
    public static let sky = SceneFlags(rawValue: SceneCategory.sky.rawValue)
    public static let art = SceneFlags(rawValue: SceneCategory.art.rawValue)
    public static let text = SceneFlags(rawValue: SceneCategory.text.rawValue)
    public static let beach = SceneFlags(rawValue: SceneCategory.beach.rawValue)

    /// True if the raw `scene_flags` bitmask has the given category's bit set.
    public static func contains(_ rawFlags: Int, _ category: SceneCategory) -> Bool {
        rawFlags & category.rawValue != 0
    }
}
