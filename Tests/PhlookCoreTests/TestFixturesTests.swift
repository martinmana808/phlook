import Testing
import Foundation
@testable import PhlookCore

struct TestFixturesTests {
    @Test func jpegFixtureEmbedsExifCaptureDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dated.jpg")

        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 8
        comps.hour = 13; comps.minute = 56; comps.second = 58
        let date = try #require(Calendar.current.date(from: comps))

        try TestFixtures.writeJPEG(at: url, width: 32, height: 32, captureDate: date)

        // LibraryScanner.imageMeta reads EXIF DateTimeOriginal — reuse it as the oracle.
        let (_, _, readBack, _) = LibraryScanner.imageMeta(url)
        #expect(readBack == date)
    }
}
