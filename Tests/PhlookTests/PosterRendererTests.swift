import Testing
import Foundation
import AppKit
@testable import Phlook
@testable import PhlookCore

struct PosterRendererTests {
    @Test func extractsFrameFromMotionFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        try await TestFixtures.writeQuickTimeMovie(at: url, duration: 1.0, width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = await PosterRenderer.posterImage(motionPath: url.path, time: 0.5, maxPixel: 256)
        let unwrapped = try #require(image)
        #expect(unwrapped.size.width > 0)
        #expect(unwrapped.size.height > 0)
        #expect(max(unwrapped.size.width, unwrapped.size.height) <= 256 + 1)
    }

    @Test func returnsNilForMissingFile() async throws {
        let image = await PosterRenderer.posterImage(
            motionPath: "/nonexistent/path.mov", time: 0.5, maxPixel: 256)
        #expect(image == nil)
    }
}
