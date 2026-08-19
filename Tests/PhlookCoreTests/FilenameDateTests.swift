import Testing
import Foundation
@testable import PhlookCore

struct FilenameDateTests {
    @Test func parsesConventionFilenamePrefix() throws {
        let cd = try #require(CaptureDate.parseFilename("2024-06-30_23-05-40_test.jpg"))
        #expect(cd.source == .filename)
        #expect(cd.timestampString() == "2024-06-30_23-05-40")
    }

    @Test func rejectsNonConventionFilename() {
        #expect(CaptureDate.parseFilename("IMG_1234.jpg") == nil)
    }

    @Test func roundTripsThroughTimestampString() throws {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 14
        comps.hour = 9; comps.minute = 26; comps.second = 53
        let date = try #require(Calendar.current.date(from: comps))
        let original = CaptureDate(date: date, timeZone: .current, source: .exif)

        let parsed = try #require(CaptureDate.parseFilename(original.timestampString() + "_x.jpg"))

        // Expected date truncated to second precision via the same formatter.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let expected = try #require(f.date(from: original.timestampString()))

        #expect(parsed.date == expected)
        #expect(parsed.source == .filename)
    }
}
