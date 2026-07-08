import Testing
import Foundation
@testable import PhlookCore

/// Tests the pure identifier→category mapping layer — the same "no Vision
/// call, thoroughly tested" split KindDetector uses for its own mapping.
struct SceneClassifierTests {
    @Test func foodIdentifierMapsToFoodBit() {
        let mask = SceneClassifier.categories(forIdentifiers: [("Fruit", 0.9)], threshold: 0.35)
        #expect(mask == SceneCategory.food.rawValue)
    }

    @Test func belowThresholdIdentifierIsIgnored() {
        let mask = SceneClassifier.categories(forIdentifiers: [("Dog", 0.10)], threshold: 0.35)
        #expect(mask == 0)
    }

    @Test func atThresholdIdentifierCounts() {
        let mask = SceneClassifier.categories(forIdentifiers: [("Dog", 0.35)], threshold: 0.35)
        #expect(mask == SceneCategory.animal.rawValue)
    }

    @Test func multipleIdentifiersOrTogether() {
        let mask = SceneClassifier.categories(
            forIdentifiers: [("Dog", 0.9), ("Tree", 0.5), ("Sky", 0.6)],
            threshold: 0.35)
        let expected = SceneCategory.animal.rawValue | SceneCategory.plant.rawValue
            | SceneCategory.nature.rawValue | SceneCategory.sky.rawValue
        #expect(mask == expected)
    }

    @Test func beachIdentifierImpliesWaterToo() {
        let mask = SceneClassifier.categories(forIdentifiers: [("Beach", 0.9)], threshold: 0.35)
        #expect(mask == (SceneCategory.beach.rawValue | SceneCategory.water.rawValue))
    }

    @Test func emptyIdentifiersYieldsZero() {
        let mask = SceneClassifier.categories(forIdentifiers: [], threshold: 0.35)
        #expect(mask == 0)
    }

    @Test func unrecognizedIdentifierYieldsZero() {
        let mask = SceneClassifier.categories(forIdentifiers: [("Zzyzx Widget", 0.9)], threshold: 0.35)
        #expect(mask == 0)
    }

    @Test func matchIsCaseInsensitive() {
        let mask = SceneClassifier.categories(forIdentifiers: [("DOCUMENT")].map { ($0, 0.9) }, threshold: 0.35)
        #expect(mask == (SceneCategory.document.rawValue | SceneCategory.text.rawValue))
    }

    @Test func duplicateCategoryBitsDoNotDoubleUp() {
        // "dog" and "cat" both map to .animal — OR-ing twice must still be a single bit.
        let mask = SceneClassifier.categories(forIdentifiers: [("Dog", 0.9), ("Cat", 0.9)], threshold: 0.35)
        #expect(mask == SceneCategory.animal.rawValue)
    }

    // MARK: - Real Vision integration (light smoke test, non-deterministic results)

    @Test func classifyImageAtDoesNotCrashOnRealImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("solid.png")
        try TestFixtures.writePNG(at: url, width: 64, height: 64)

        // A solid color swatch won't reliably map to any category, but the
        // pipeline (decode → Vision → mapping) must run without crashing and
        // return a valid (possibly zero) bitmask.
        let mask = SceneClassifier.classify(imageAt: url)
        #expect(mask >= 0)
    }

    @Test func classifyImageAtMissingFileReturnsZero() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.png")
        #expect(SceneClassifier.classify(imageAt: url) == 0)
    }

    // MARK: - IndexingService integration (mirrors detectKindsBackfillsSentinelRowsAndIsIdempotent)

    @Test func classifyScenesBackfillsSentinelRowsAndIsIdempotent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mediaURL = dir.appendingPathComponent("photo.png")
        try TestFixtures.writePNG(at: mediaURL, width: 16, height: 16)

        let service = IndexingService(root: dir)
        _ = try service.reindex()
        // Fresh scan rows start at scene_flags == -1 (migration v6 default
        // path for new rows is via scan, which doesn't set scenes) — force
        // the sentinel explicitly to exercise the backfill path.
        try service.mediaIndex.setSceneFlagsForTesting(path: mediaURL.path, flags: -1)

        let processed = await service.classifyScenes()
        #expect(processed == 1)

        let item = try #require(try service.mediaIndex.item(forPath: mediaURL.path))
        #expect(item.sceneFlags != -1)   // classified: no longer the sentinel

        let secondRun = await service.classifyScenes()
        #expect(secondRun == 0)
    }

    @Test func classifyScenesMarksMissingFileAsZeroNotRetried() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mediaURL = dir.appendingPathComponent("gone.png")
        try TestFixtures.writePNG(at: mediaURL, width: 16, height: 16)

        let service = IndexingService(root: dir)
        _ = try service.reindex()
        try FileManager.default.removeItem(at: mediaURL)
        try service.mediaIndex.setSceneFlagsForTesting(path: mediaURL.path, flags: -1)

        let processed = await service.classifyScenes()
        #expect(processed == 1)
        let item = try #require(try service.mediaIndex.item(forPath: mediaURL.path))
        #expect(item.sceneFlags == 0)

        let secondRun = await service.classifyScenes()
        #expect(secondRun == 0)
    }
}
