import Testing
@testable import PhlookCore

struct DurationFormatterTests {
    @Test func formatsSecondsOnly() { #expect(DurationFormatter.string(seconds: 34) == "0:34") }
    @Test func formatsMinutes() { #expect(DurationFormatter.string(seconds: 725) == "12:05") }
    @Test func formatsHours() { #expect(DurationFormatter.string(seconds: 4325) == "1:12:05") }
    @Test func roundsFractionalSeconds() { #expect(DurationFormatter.string(seconds: 29.6) == "0:30") }
    @Test func nilAndSentinelYieldNil() {
        #expect(DurationFormatter.string(seconds: nil) == nil)
        #expect(DurationFormatter.string(seconds: -1) == nil)
    }
}
