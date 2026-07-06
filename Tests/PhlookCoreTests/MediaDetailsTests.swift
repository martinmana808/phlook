import Testing
import Foundation
@testable import PhlookCore

struct MediaDetailsTests {
    @Test func assemblesVideoDetailsFromRealFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("2026-03-08_13-56-58_CLIP.MOV")
        try Data(count: 2048).write(to: url)

        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let item = MediaItem(path: url.path, hash: nil, dateTaken: date, fileType: "video",
                             width: 1920, height: 1080, lastScanned: Date(), duration: 754)
        let d = MediaDetails.from(item: item)

        #expect(d.filename == "2026-03-08_13-56-58_CLIP.MOV")
        #expect(d.dimensions == "1920 × 1080")
        #expect(d.duration == "12:34")
        #expect(d.kind == "QuickTime movie")
        #expect(d.fileSize != nil)      // real 2KB file on disk
        #expect(d.path == url.path)
        #expect(d.dateTaken != "Unknown")
    }

    @Test func imageWithNoMetadataShowsUnknowns() {
        let item = MediaItem(path: "/nowhere/missing.heic", hash: nil, dateTaken: nil,
                             fileType: "image", width: nil, height: nil, lastScanned: Date())
        let d = MediaDetails.from(item: item)
        #expect(d.dateTaken == "Unknown")
        #expect(d.dimensions == nil)
        #expect(d.duration == nil)
        #expect(d.fileSize == nil)      // file doesn't exist
        #expect(d.kind == "HEIC image")
    }
}
