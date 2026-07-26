import Foundation

public struct ArchiveTarget: Equatable {
    public let volumeRoot: URL
    public let markerID: String
    public var phlookRoot: URL { volumeRoot.appendingPathComponent("PHLOOK") }
}

/// Identifies the archive SSD by a marker file at its root, not by volume name,
/// so a rename or a same-named impostor drive can't be mistaken for the archive.
public enum SSDArchiveTarget {
    static let markerFileName = ".phlook_archive"

    private struct Marker: Codable { let id: String; let created: String }

    public static func setUp(volumeRoot: URL, markerID: String) throws {
        let iso = ISO8601DateFormatter().string(from: Date())
        let data = try JSONEncoder().encode(Marker(id: markerID, created: iso))
        try data.write(to: volumeRoot.appendingPathComponent(markerFileName))
        try FileManager.default.createDirectory(
            at: volumeRoot.appendingPathComponent("PHLOOK"), withIntermediateDirectories: true)
    }

    public static func readMarkerID(at volumeRoot: URL) -> String? {
        let url = volumeRoot.appendingPathComponent(markerFileName)
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        return marker.id
    }

    public static func resolve(expectedMarkerID: String, candidateRoots: [URL]) -> ArchiveTarget? {
        for root in candidateRoots where readMarkerID(at: root) == expectedMarkerID {
            return ArchiveTarget(volumeRoot: root, markerID: expectedMarkerID)
        }
        return nil
    }

    /// Production helper: mounted, browsable volumes under /Volumes. Not unit-tested.
    public static func mountedVolumeRoots() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                     options: [.skipHiddenVolumes]) ?? []
    }
}
