import Testing
import Foundation
@testable import PhlookCore

struct CurationQueriesTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }
    private func add(_ i: MediaIndex, _ p: String) throws {
        try i.upsert(MediaItem(path: p, hash: "h", dateTaken: nil, fileType: "image",
                               width: nil, height: nil, lastScanned: Date()))
    }

    @Test func protectAndClaimMutate() throws {
        let i = try newIndex()
        try add(i, "/lib/a.heic")
        try i.markArchived(path: "/lib/a.heic", hash: "ha", at: Date())
        try i.setSmallPath(path: "/lib/a.heic", smallPath: "/proxy/a.jpg")

        try i.setClaimed(path: "/lib/a.heic", ssdRelPath: "PHLOOK/a.heic")
        let a = try i.item(forPath: "/lib/a.heic")
        #expect(a?.protected == true)
        #expect(a?.ssdRelPath == "PHLOOK/a.heic")
        #expect(a?.smallPath == nil)          // no longer compressed

        try i.setProtected(paths: ["/lib/a.heic"], protected: false)
        #expect(try i.item(forPath: "/lib/a.heic")?.protected == false)
    }

    @Test func shrinkWorkSetExcludesProtected() throws {
        let i = try newIndex()
        try add(i, "/lib/b.mov"); try i.markArchived(path: "/lib/b.mov", hash: "hb", at: Date()) // backed up, not shrunk
        try add(i, "/lib/c.mov"); try i.markArchived(path: "/lib/c.mov", hash: "hc", at: Date())
        try i.setProtected(paths: ["/lib/c.mov"], protected: true)
        #expect(try i.itemsToShrink().map(\.path) == ["/lib/b.mov"])  // c excluded (protected)
    }

    @Test func curationCountsClassify() throws {
        let i = try newIndex()
        try add(i, "/lib/nb.heic")                                    // not backed up
        try add(i, "/lib/cp.heic"); try i.markArchived(path: "/lib/cp.heic", hash: "h1", at: Date()); try i.setSmallPath(path: "/lib/cp.heic", smallPath: "/p/cp.jpg") // compressed
        try add(i, "/lib/fs.heic"); try i.setProtected(paths: ["/lib/fs.heic"], protected: true) // full size
        let c = try i.curationCounts()
        #expect(c.notBackedUp == 1)
        #expect(c.compressed == 1)
        #expect(c.fullSize == 1)
    }
}
