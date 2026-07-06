import Testing
import Foundation
@testable import PhlookCore

struct CaptureDateTests {
    @Test func timestampStringRendersWallClockInGivenTimeZone() throws {
        // 2026-03-08T13:56:58-0300 == 16:56:58 UTC
        let utc = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let tz = try #require(TimeZone(secondsFromGMT: -3 * 3600))
        let cd = CaptureDate(date: utc, timeZone: tz, source: .videoMetadata)
        #expect(cd.timestampString() == "2026-03-08_13-56-58")
    }

    @Test func parsesQuickTimeDateWithCompactOffset() throws {
        let cd = try #require(CaptureDate.parseQuickTime("2026-03-08T13:56:58-0300"))
        #expect(cd.timestampString() == "2026-03-08_13-56-58")
        #expect(cd.source == .videoMetadata)
    }

    @Test func parsesQuickTimeDateWithColonOffsetAndZulu() throws {
        let colon = try #require(CaptureDate.parseQuickTime("2026-03-08T13:56:58-03:00"))
        #expect(colon.timestampString() == "2026-03-08_13-56-58")
        let zulu = try #require(CaptureDate.parseQuickTime("2026-03-08T16:56:58Z"))
        #expect(zulu.timestampString() == "2026-03-08_16-56-58")
    }

    @Test func rejectsGarbageQuickTimeDate() {
        #expect(CaptureDate.parseQuickTime("not a date") == nil)
        #expect(CaptureDate.parseQuickTime("") == nil)
    }
}
