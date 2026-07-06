import Testing
import Foundation
@testable import PhlookCore

struct ViewerMathTests {
    func item(_ path: String) -> MediaItem {
        MediaItem(path: path, hash: nil, dateTaken: nil, fileType: "image",
                  width: nil, height: nil, lastScanned: Date())
    }

    @Test func clampStaysInsideBounds() {
        #expect(ViewerMath.clamp(-1, count: 10) == 0)
        #expect(ViewerMath.clamp(0, count: 10) == 0)
        #expect(ViewerMath.clamp(5, count: 10) == 5)
        #expect(ViewerMath.clamp(10, count: 10) == 9)
    }

    @Test func positionStringIsOneBased() {
        #expect(ViewerMath.positionString(index: 2, count: 10) == "3 of 10")
    }

    @Test func resolveIndexFindsByPathOrNil() {
        let items = [item("/a"), item("/b"), item("/c")]
        #expect(ViewerMath.resolveIndex(path: "/b", in: items) == 1)
        #expect(ViewerMath.resolveIndex(path: "/gone", in: items) == nil)
    }
}
