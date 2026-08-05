import Testing
import Foundation
@testable import PhlookCore

struct ArchiveReclaimLifecycleTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    private func add(_ index: MediaIndex, _ path: String) throws {
        try index.upsert(MediaItem(path: path, hash: "h", dateTaken: nil, fileType: "image",
                                   width: nil, height: nil, lastScanned: Date()))
    }

    // FIX 1: deleteMissing must never prune a row whose archived_hash is set,
    // even when its local original is gone from the scanned path set (reclaimed).
    @Test func deleteMissingKeepsArchivedRowsButPrunesPlainOnes() throws {
        let index = try newIndex()
        try add(index, "/lib/plain.heic")            // no local file, never archived
        try add(index, "/lib/archived.heic")          // reclaimed: local file gone, but archived
        try add(index, "/lib/present.heic")           // path present in keepingPaths

        try index.markArchived(path: "/lib/archived.heic", hash: "deadbeef", at: Date())
        try index.setSmallPath(path: "/lib/archived.heic", smallPath: "/proxy/archived.jpg")

        try index.deleteMissing(keepingPaths: ["/lib/present.heic"])

        #expect(try index.item(forPath: "/lib/plain.heic") == nil)       // pruned: not kept, never archived
        let archived = try index.item(forPath: "/lib/archived.heic")
        #expect(archived != nil)                                         // survives: archived row, even though missing locally
        #expect(archived?.archivedHash == "deadbeef")
        #expect(archived?.smallPath == "/proxy/archived.jpg")
        #expect(try index.item(forPath: "/lib/present.heic") != nil)     // survives: unchanged behavior
    }
}
