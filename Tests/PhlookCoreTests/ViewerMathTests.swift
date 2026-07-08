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

    @Test func clampZoomStaysWithinOneToFour() {
        #expect(ViewerMath.clampZoom(0.2) == 1)
        #expect(ViewerMath.clampZoom(1) == 1)
        #expect(ViewerMath.clampZoom(2.5) == 2.5)
        #expect(ViewerMath.clampZoom(4) == 4)
        #expect(ViewerMath.clampZoom(9) == 4)
    }

    @Test func fitSizeScalesToContainerPreservingAspect() {
        // Wide image, square container: width-bound.
        let wide = ViewerMath.fitSize(image: CGSize(width: 4000, height: 2000),
                                       in: CGSize(width: 1000, height: 1000))
        #expect(wide == CGSize(width: 1000, height: 500))

        // Tall image, square container: height-bound.
        let tall = ViewerMath.fitSize(image: CGSize(width: 2000, height: 4000),
                                       in: CGSize(width: 1000, height: 1000))
        #expect(tall == CGSize(width: 500, height: 1000))
    }

    @Test func fitSizeFallsBackToContainerForDegenerateImageSize() {
        let result = ViewerMath.fitSize(image: .zero, in: CGSize(width: 800, height: 600))
        #expect(result == CGSize(width: 800, height: 600))
    }
}
