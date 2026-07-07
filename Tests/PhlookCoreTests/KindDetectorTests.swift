import Testing
import Foundation
@testable import PhlookCore

struct KindDetectorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func pngWithoutMakeOrModelIsScreenshot() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("shot.png")
        try TestFixtures.writePNG(at: url, width: 16, height: 16)

        #expect(KindDetector.flags(forImageAt: url) == .screenshot)
    }

    @Test func pngWithTiffMakeIsNotScreenshot() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("camera.png")
        try TestFixtures.writePNG(at: url, width: 16, height: 16, tiffMake: "Apple")

        #expect(KindDetector.flags(forImageAt: url) == [])
    }

    @Test func jpegWithScreenshotUserCommentIsScreenshot() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("screenshot.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16, userComment: "Screenshot")

        #expect(KindDetector.flags(forImageAt: url) == .screenshot)
    }

    @Test func jpegWithFrontLensIsSelfie() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("selfie.jpg")
        try TestFixtures.writeJPEG(
            at: url, width: 16, height: 16,
            lensModel: "iPhone 15 Pro front TrueDepth camera")

        #expect(KindDetector.flags(forImageAt: url) == .selfie)
    }

    @Test func frontLensPngWithoutMakeIsScreenshotAndSelfie() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("front.png")
        try TestFixtures.writePNG(
            at: url, width: 16, height: 16,
            lensModel: "iPhone 15 Pro front TrueDepth camera")

        #expect(KindDetector.flags(forImageAt: url) == [.screenshot, .selfie])
    }

    @Test func plainJpegHasNoFlags() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("plain.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)

        #expect(KindDetector.flags(forImageAt: url) == [])
    }

    // MARK: - IndexingService integration

    @Test func scanSetsKindFlagsAtExtraction() throws {
        let dir = try tempDir()
        let mediaURL = dir.appendingPathComponent("shot.png")
        try TestFixtures.writePNG(at: mediaURL, width: 16, height: 16)

        let service = IndexingService(root: dir)
        _ = try service.reindex()

        let item = try #require(try service.mediaIndex.item(forPath: mediaURL.path))
        #expect(item.kindFlags == KindFlags.screenshot.rawValue)
    }

    @Test func detectKindsBackfillsSentinelRowsAndIsIdempotent() async throws {
        let dir = try tempDir()
        let mediaURL = dir.appendingPathComponent("shot.png")
        try TestFixtures.writePNG(at: mediaURL, width: 16, height: 16)

        let service = IndexingService(root: dir)
        _ = try service.reindex()
        // reindex already set the real flags; force the pre-v5 sentinel to
        // exercise the backfill path explicitly.
        try service.mediaIndex.setKindFlagsForTesting(path: mediaURL.path, flags: -1)

        let processed = await service.detectKinds()
        #expect(processed == 1)

        let item = try #require(try service.mediaIndex.item(forPath: mediaURL.path))
        #expect(item.kindFlags == KindFlags.screenshot.rawValue)

        let secondRun = await service.detectKinds()
        #expect(secondRun == 0)
    }
}
