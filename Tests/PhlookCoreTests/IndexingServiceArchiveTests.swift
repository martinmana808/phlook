import Testing
import Foundation
@testable import PhlookCore

struct IndexingServiceArchiveTests {
    private func makeService() throws -> IndexingService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return IndexingService(root: root)
    }

    @Test func setUpAndResolveArchiveTargetRoundTrips() throws {
        let svc = try makeService()
        let vol = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vol, withIntermediateDirectories: true)

        let target = try svc.setUpArchiveDrive(volumeRoot: vol)
        #expect(target.volumeRoot == vol)
        // Marker id persisted:
        #expect(try svc.mediaIndex.markerID() == target.markerID)
        // Resolve finds it among explicit candidates:
        #expect(SSDArchiveTarget.resolve(expectedMarkerID: target.markerID, candidateRoots: [vol]) != nil)
    }

    @Test func reclaimStatusReflectsCountsAndNoSSD() throws {
        let svc = try makeService()
        // No marker set ⇒ ssd not connected.
        let status = try svc.reclaimStatus()
        #expect(status.ssdConnected == false)
        #expect(status.canArchive == false)
    }

    @Test func runArchiveThrowsWithoutSSD() throws {
        let svc = try makeService()
        #expect(throws: IndexingService.ArchiveError.noSSD) {
            _ = try svc.runArchive(isCancelled: { false })
        }
    }
}
