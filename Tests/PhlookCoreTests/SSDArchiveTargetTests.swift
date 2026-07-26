import Testing
import Foundation
@testable import PhlookCore

struct SSDArchiveTargetTests {
    private func tmpVolume() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func setUpWritesMarkerAndPhlookRoot() throws {
        let vol = try tmpVolume()
        try SSDArchiveTarget.setUp(volumeRoot: vol, markerID: "uuid-abc")
        #expect(SSDArchiveTarget.readMarkerID(at: vol) == "uuid-abc")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: vol.appendingPathComponent("PHLOOK").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func resolvePicksMatchingMarkerOnly() throws {
        let match = try tmpVolume(); try SSDArchiveTarget.setUp(volumeRoot: match, markerID: "want")
        let other = try tmpVolume(); try SSDArchiveTarget.setUp(volumeRoot: other, markerID: "different")
        let bare  = try tmpVolume()   // no marker at all

        let target = SSDArchiveTarget.resolve(expectedMarkerID: "want", candidateRoots: [bare, other, match])
        #expect(target?.volumeRoot == match)
        #expect(target?.phlookRoot == match.appendingPathComponent("PHLOOK"))

        #expect(SSDArchiveTarget.resolve(expectedMarkerID: "want", candidateRoots: [bare, other]) == nil)
        #expect(SSDArchiveTarget.readMarkerID(at: bare) == nil)
    }

    @Test func renamedVolumeStillResolvesByMarker() throws {
        let vol = try tmpVolume(); try SSDArchiveTarget.setUp(volumeRoot: vol, markerID: "stable")
        let renamed = vol.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: vol, to: renamed)   // simulate a volume rename
        #expect(SSDArchiveTarget.resolve(expectedMarkerID: "stable", candidateRoots: [renamed])?.volumeRoot == renamed)
    }
}
