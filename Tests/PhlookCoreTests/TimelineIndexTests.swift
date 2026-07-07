import Testing
import Foundation
@testable import PhlookCore

struct TimelineIndexTests {
    func item(_ path: String, _ iso: String?) -> MediaItem {
        let date = iso.flatMap { ISO8601DateFormatter().date(from: $0) }
        return MediaItem(path: path, hash: nil, dateTaken: date, fileType: "image",
                         width: nil, height: nil, lastScanned: Date())
    }

    @Test func bucketsByMonthInInputOrderWithCounts() {
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/b", "2026-03-01T10:00:00Z"),
            item("/c", "2026-01-05T10:00:00Z"),
            item("/d", "2025-12-31T10:00:00Z"),
        ])
        #expect(buckets.count == 3)
        #expect(buckets[0].count == 2)
        #expect(buckets[0].firstItemPath == "/a")
        #expect(buckets[1].firstItemPath == "/c")
        #expect(buckets[2].firstItemPath == "/d")
    }

    @Test func yearStartsAreFlagged() {
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/b", "2026-01-05T10:00:00Z"),
            item("/c", "2025-12-31T10:00:00Z"),
        ])
        #expect(buckets[0].isYearStart)          // first 2026 bucket
        #expect(!buckets[1].isYearStart)
        #expect(buckets[2].isYearStart)          // first 2025 bucket
    }

    @Test func undatedItemsFormTrailingBucket() {
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/x", nil),
            item("/y", nil),
        ])
        #expect(buckets.last?.monthStart == nil)
        #expect(buckets.last?.label == "Undated")
        #expect(buckets.last?.count == 2)
        #expect(buckets.last?.firstItemPath == "/x")
    }

    @Test func emptyInputYieldsNoBuckets() {
        #expect(TimelineIndex.compute(items: []).isEmpty)
    }
}
