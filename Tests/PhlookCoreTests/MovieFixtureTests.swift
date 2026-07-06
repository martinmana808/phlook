import Testing
import Foundation
import AVFoundation
@testable import PhlookCore

struct MovieFixtureTests {
    @Test func fixtureMovieIsReadableWithDurationAndCreationDate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clip.mov")

        try await TestFixtures.writeQuickTimeMovie(
            at: url, duration: 1.0, width: 64, height: 48,
            creationDate: "2026-03-08T13:56:58-0300")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.35)

        // The embedded QuickTime creation date must round-trip through the
        // same extraction path the enricher uses.
        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .videoMetadata)
        #expect(cd.timestampString() == "2026-03-08_13-56-58")
    }
}
