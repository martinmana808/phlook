// Note: XCTest is unavailable with Command Line Tools only (no full Xcode).
// Using swift-testing (import Testing), available in the Swift toolchain,
// which is functionally equivalent for this smoke test.
import Testing
@testable import PhlookCore

struct SmokeTests {
    @Test func testVersionExists() {
        #expect(PhlookCore.version == "0.1.0")
    }
}
