import Testing
import Foundation
@testable import PhlookCore

struct CurationColumnsTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    @Test func curationFieldsDefaultAndSurviveUpsert() throws {
        let index = try newIndex()
        var item = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                             fileType: "image", width: nil, height: nil, lastScanned: Date())
        // defaults on a fresh item
        #expect(item.curated == true)
        #expect(item.protected == false)
        item.protected = true
        item.ssdRelPath = "PHLOOK/a.heic"
        try index.upsert(item)

        // a plain rescan (no curation fields set) must NOT reset them
        let rescan = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                               fileType: "image", width: nil, height: nil, lastScanned: Date())
        try index.upsert(rescan)

        let got = try index.item(forPath: "/x/a.heic")
        #expect(got?.protected == true)
        #expect(got?.curated == true)
        #expect(got?.ssdRelPath == "PHLOOK/a.heic")
    }
}
