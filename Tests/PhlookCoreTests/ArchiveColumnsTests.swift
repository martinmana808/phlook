import Testing
import Foundation
@testable import PhlookCore

struct ArchiveColumnsTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    @Test func archiveFieldsRoundTripAndSurviveUpsert() throws {
        let index = try newIndex()
        var item = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                             fileType: "image", width: nil, height: nil, lastScanned: Date())
        item.archivedHash = "deadbeef"
        item.archivedAt = Date(timeIntervalSince1970: 1_000_000)
        item.smallPath = "/proxy/a.jpg"
        try index.upsert(item)

        // A later plain rescan (no archive fields) must NOT wipe them.
        let rescan = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                               fileType: "image", width: nil, height: nil, lastScanned: Date())
        try index.upsert(rescan)

        let got = try index.item(forPath: "/x/a.heic")
        #expect(got?.archivedHash == "deadbeef")
        #expect(got?.smallPath == "/proxy/a.jpg")
        #expect(got?.archivedAt == Date(timeIntervalSince1970: 1_000_000))
    }
}
