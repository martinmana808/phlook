import Testing
import Foundation
@testable import PhlookCore

struct HiddenFlagTests {
    func makeIndex() throws -> MediaIndex {
        try MediaIndex(dbPath: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path)
    }
    func mkItem(_ path: String, kindFlags: Int = 0, sceneFlags: Int = 0) -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: nil, fileType: "image",
                  width: nil, height: nil, lastScanned: Date(), kindFlags: kindFlags, sceneFlags: sceneFlags)
    }

    @Test func setHiddenRoundTrip() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg")); try index.upsert(mkItem("/b.jpg"))
        try index.setHidden(paths: ["/a.jpg"], hidden: true)
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden)
        #expect(try #require(try index.item(forPath: "/b.jpg")).hidden == false)
        try index.setHidden(paths: ["/a.jpg"], hidden: false)
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden == false)
    }

    @Test func rescanNeverUnhides() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg"))
        try index.setHidden(paths: ["/a.jpg"], hidden: true)
        try index.upsert(mkItem("/a.jpg"))          // same-hash scan pass
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden)
        var changed = mkItem("/a.jpg"); changed.hash = "different"
        try index.upsert(changed)                    // changed-hash pass
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden)
    }

    @Test func kindFlagsPreservedAgainstZeroScan() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg", kindFlags: 1))   // detected screenshot
        try index.upsert(mkItem("/a.jpg", kindFlags: 0))   // later same-hash scan, no info
        #expect(try #require(try index.item(forPath: "/a.jpg")).kindFlags == 1)
    }

    @Test func preexistingRowsGetUnknownSentinel() throws {
        // Fresh index: insert, then simulate pre-v5 by forcing -1, verify query surfaces it.
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg"))
        try index.setKindFlagsForTesting(path: "/a.jpg", flags: -1)
        #expect(try index.kindsNeedingDetection().map(\.path) == ["/a.jpg"])
    }

    @Test func sceneFlagsPreservedAgainstZeroScan() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg", sceneFlags: 2))   // detected food
        try index.upsert(mkItem("/a.jpg", sceneFlags: 0))   // later same-hash scan, no info
        #expect(try #require(try index.item(forPath: "/a.jpg")).sceneFlags == 2)
    }

    @Test func sceneFlagsTakenVerbatimOnChangedHash() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg", sceneFlags: 2))
        var changed = mkItem("/a.jpg", sceneFlags: 0)
        changed.hash = "different"
        try index.upsert(changed)
        #expect(try #require(try index.item(forPath: "/a.jpg")).sceneFlags == 0)
    }

    @Test func preexistingRowsGetSceneUnknownSentinel() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg"))
        try index.setSceneFlagsForTesting(path: "/a.jpg", flags: -1)
        #expect(try index.scenesNeedingClassification().map(\.path) == ["/a.jpg"])
    }
}
