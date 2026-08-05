import Testing
import Foundation
@testable import PhlookCore

struct ArchiveIndexQueriesTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    private func add(_ index: MediaIndex, _ path: String, size: Int) throws {
        try index.upsert(MediaItem(path: path, hash: "h", dateTaken: nil, fileType: "image",
                                   width: nil, height: nil, lastScanned: Date(), fileSize: size))
    }

    @Test func markerRoundTrips() throws {
        let index = try newIndex()
        #expect(try index.markerID() == nil)
        try index.setMarkerID("uuid-123", label: "PHLOOK_SSD")
        #expect(try index.markerID() == "uuid-123")
        try index.setMarkerID("uuid-456", label: "PHLOOK_SSD2")   // single row, replaces
        #expect(try index.markerID() == "uuid-456")
    }

    @Test func archiveStateTransitionsAndCounts() throws {
        let index = try newIndex()
        try add(index, "/lib/a.heic", size: 1000)   // untouched
        try add(index, "/lib/b.mov",  size: 9000)   // will archive + shrink
        try add(index, "/lib/c.jpg",  size: 500)    // will archive only

        try index.markArchived(path: "/lib/b.mov", hash: "hb", at: Date())
        try index.setSmallPath(path: "/lib/b.mov", smallPath: "/proxy/b.mp4")
        try index.markArchived(path: "/lib/c.jpg", hash: "hc", at: Date())

        #expect(try index.itemsNeedingArchiving().map(\.path).sorted() == ["/lib/a.heic"])
        #expect(try index.reclaimableItems().map(\.path) == ["/lib/b.mov"])

        let counts = try index.archiveCounts()
        #expect(counts.needsArchiving == 1)     // a
        #expect(counts.hasSmall == 1)           // b
        #expect(counts.reclaimable == 1)        // b (archived + small)
        #expect(counts.reclaimableBytes == 9000)
    }

    // FIX 2: itemsPendingArchiveOrShrink() must resurface items where the
    // pipeline stalled between markArchived and setSmallPath (e.g. a crash
    // or shrink failure), not just brand-new items.
    @Test func itemsPendingArchiveOrShrinkIncludesStalledAndNewButNotDone() throws {
        let index = try newIndex()
        try add(index, "/lib/new.heic", size: 100)              // brand-new: both nil
        try add(index, "/lib/stalled.mov", size: 200)           // archived but not shrunk
        try add(index, "/lib/done.jpg", size: 300)               // fully done

        try index.markArchived(path: "/lib/stalled.mov", hash: "hs", at: Date())

        try index.markArchived(path: "/lib/done.jpg", hash: "hd", at: Date())
        try index.setSmallPath(path: "/lib/done.jpg", smallPath: "/proxy/done.jpg")

        let pending = try index.itemsPendingArchiveOrShrink().map(\.path).sorted()
        #expect(pending == ["/lib/new.heic", "/lib/stalled.mov"])
    }
}
