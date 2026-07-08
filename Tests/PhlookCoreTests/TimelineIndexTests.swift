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

    @Test func yFractionIsTimeLinearWithGaps() {
        // Jan 2026 (newest), Dec 2025, Jan 2025 (oldest): Dec sits ~1/12 down, not 1/2.
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-01-15T10:00:00Z"),
            item("/b", "2025-12-15T10:00:00Z"),
            item("/c", "2025-01-15T10:00:00Z"),
        ])
        #expect(buckets[0].yFraction == 0.0)
        #expect(buckets[2].yFraction == 1.0)
        #expect(buckets[1].yFraction > 0.05 && buckets[1].yFraction < 0.15)   // ~1 month of 12
    }

    @Test func densityFractionScalesToBusiestMonth() {
        let items = [item("/a", "2026-03-01T10:00:00Z"), item("/b", "2026-03-02T10:00:00Z"),
                     item("/c", "2026-03-03T10:00:00Z"), item("/d", "2026-01-05T10:00:00Z")]
        let buckets = TimelineIndex.compute(items: items)
        #expect(buckets[0].densityFraction == 1.0)     // 3 of max 3
        #expect(abs(buckets[1].densityFraction - 1.0/3.0) < 0.001)
    }

    @Test func yearBucketsGroupByYearInInputOrderWithCounts() {
        let buckets = TimelineIndex.yearBuckets(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/b", "2026-01-01T10:00:00Z"),
            item("/c", "2025-12-31T10:00:00Z"),
            item("/d", "2025-01-05T10:00:00Z"),
            item("/e", "2024-06-01T10:00:00Z"),
        ])
        #expect(buckets.count == 3)
        #expect(buckets[0].year == 2026)
        #expect(buckets[0].label == "2026")
        #expect(buckets[0].firstItemPath == "/a")
        #expect(buckets[0].count == 2)
        #expect(buckets[1].year == 2025)
        #expect(buckets[1].firstItemPath == "/c")
        #expect(buckets[1].count == 2)
        #expect(buckets[2].year == 2024)
        #expect(buckets[2].firstItemPath == "/e")
        #expect(buckets[2].count == 1)
    }

    @Test func yearBucketsExcludeNilDates() {
        let buckets = TimelineIndex.yearBuckets(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/x", nil),
            item("/y", nil),
        ])
        #expect(buckets.count == 1)
        #expect(buckets[0].year == 2026)
        #expect(buckets[0].count == 1)
    }

    @Test func yearBucketsEmptyInputYieldsNoBuckets() {
        #expect(TimelineIndex.yearBuckets(items: []).isEmpty)
    }

    @Test func yearBucketsAllNilDatesYieldsNoBuckets() {
        #expect(TimelineIndex.yearBuckets(items: [item("/x", nil), item("/y", nil)]).isEmpty)
    }
}
