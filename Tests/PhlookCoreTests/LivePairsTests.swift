import Testing
import Foundation
@testable import PhlookCore

struct LivePairsTests {
    func item(_ path: String, type: String, duration: Double? = nil) -> MediaItem {
        MediaItem(path: path, hash: nil, dateTaken: nil, fileType: type,
                  width: nil, height: nil, lastScanned: Date(), duration: duration)
    }

    @Test func pairsStemMatchedShortVideoWithImage() {
        let pairs = LivePairs.compute(items: [
            item("/lib/2026-07-06_12-00-00_IMG_1234.HEIC", type: "image"),
            item("/lib/2026-07-06_12-00-00_IMG_1234.MOV", type: "video", duration: 2.9),
        ])
        #expect(pairs.hiddenVideoPaths == ["/lib/2026-07-06_12-00-00_IMG_1234.MOV"])
        #expect(pairs.videoPath(forImagePath: "/lib/2026-07-06_12-00-00_IMG_1234.HEIC")
                == "/lib/2026-07-06_12-00-00_IMG_1234.MOV")
    }

    @Test func rejectsLongNilAndSentinelDurations() {
        let pairs = LivePairs.compute(items: [
            item("/a/X.HEIC", type: "image"),
            item("/a/X.MOV", type: "video", duration: 42),      // long: real video
            item("/a/Y.JPG", type: "image"),
            item("/a/Y.MOV", type: "video"),                    // nil: not yet enriched
            item("/a/Z.HEIC", type: "image"),
            item("/a/Z.MOV", type: "video", duration: -1),      // unreadable sentinel
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
        #expect(pairs.videoPath(forImagePath: "/a/X.HEIC") == nil)
    }

    @Test func requiresOneImageOneVideo() {
        let pairs = LivePairs.compute(items: [
            item("/a/A.HEIC", type: "image"),
            item("/a/A.PNG", type: "image"),                    // image+image: no pair
            item("/b/B.MOV", type: "video", duration: 2),       // lone short video: no pair
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
    }

    @Test func multiplePairsAndDottedStems() {
        let pairs = LivePairs.compute(items: [
            item("/l/one.HEIC", type: "image"),
            item("/l/one.MOV", type: "video", duration: 3),
            item("/l/archive.2024.HEIC", type: "image"),        // dot in stem
            item("/l/archive.2024.MOV", type: "video", duration: 1.5),
        ])
        #expect(pairs.hiddenVideoPaths.count == 2)
        #expect(pairs.videoPath(forImagePath: "/l/archive.2024.HEIC") == "/l/archive.2024.MOV")
    }

    @Test func differentDirectoriesDoNotPair() {
        let pairs = LivePairs.compute(items: [
            item("/one/A.HEIC", type: "image"),
            item("/two/A.MOV", type: "video", duration: 2),
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
    }

    @Test func ambiguousTwoImagesOneVideoPairsNothing() {
        let pairs = LivePairs.compute(items: [
            item("/a/X.HEIC", type: "image"),
            item("/a/X.PNG", type: "image"),
            item("/a/X.MOV", type: "video", duration: 2),
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
        #expect(pairs.videoPath(forImagePath: "/a/X.HEIC") == nil)
    }

    @Test func ambiguousOneImageTwoShortVideosPairsNothing() {
        let pairs = LivePairs.compute(items: [
            item("/a/X.HEIC", type: "image"),
            item("/a/X.MOV", type: "video", duration: 2),
            item("/a/X.M4V", type: "video", duration: 3),
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)   // never hide an unreachable file
    }

    @Test func pairsRealLibraryNamingWithDifferentTimestampsAndSuffix() {
        let pairs = LivePairs.compute(items: [
            item("/l/2023-12-28_10-35-59_3EFFF3E9-8CBA-4A2B-9D6E-123456789ABC.jpeg", type: "image"),
            item("/l/2023-12-27_21-35-59_3EFFF3E9-8CBA-4A2B-9D6E-123456789ABC_3.mov", type: "video", duration: 2.8),
        ])
        #expect(pairs.hiddenVideoPaths.count == 1)
        #expect(pairs.videoPath(forImagePath: "/l/2023-12-28_10-35-59_3EFFF3E9-8CBA-4A2B-9D6E-123456789ABC.jpeg")
                == "/l/2023-12-27_21-35-59_3EFFF3E9-8CBA-4A2B-9D6E-123456789ABC_3.mov")
    }

    @Test func nonUUIDCoresNeverPairAcrossDifferentTimestamps() {
        let pairs = LivePairs.compute(items: [
            item("/l/2026-05-01_10-00-00_IMG_7156.PNG", type: "image"),
            item("/l/2026-06-09_20-00-00_IMG_7156.MOV", type: "video", duration: 3),
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)   // unrelated same-number files must not pair
    }

    @Test func uuidPairWithIdenticalTimestampsAlsoPairs() {
        let pairs = LivePairs.compute(items: [
            item("/l/2026-07-06_12-00-00_ABCDEF01-1111-2222-3333-444455556666.HEIC", type: "image"),
            item("/l/2026-07-06_12-00-00_ABCDEF01-1111-2222-3333-444455556666_3.MOV", type: "video", duration: 1.9),
        ])
        #expect(pairs.hiddenVideoPaths.count == 1)
    }
}
