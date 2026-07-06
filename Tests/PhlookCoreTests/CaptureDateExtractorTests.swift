import Testing
import Foundation
@testable import PhlookCore

struct CaptureDateExtractorTests {
    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func exifDateWinsForImages() async throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("photo.jpg")
        var comps = DateComponents()
        comps.year = 2025; comps.month = 12; comps.day = 20
        comps.hour = 0; comps.minute = 10; comps.second = 22
        let date = try #require(Calendar.current.date(from: comps))
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16, captureDate: date)

        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .exif)
        #expect(cd.timestampString() == "2025-12-20_00-10-22")
    }

    @Test func imageWithoutExifFallsBackToFileCreation() async throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("stripped.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16) // no captureDate

        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .fileCreation)
        let birth = try #require(
            (try url.resourceValues(forKeys: [.creationDateKey])).creationDate)
        #expect(abs(cd.date.timeIntervalSince(birth)) < 1)
    }

    @Test func unreadableVideoFallsBackToFileCreation() async throws {
        // A .mov that isn't a real movie: AVFoundation can't read it, so the
        // extractor must fall through to file-creation without throwing.
        let dir = try makeDir()
        let url = dir.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: url)

        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .fileCreation)
    }
}
