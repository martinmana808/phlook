import Foundation

public struct TimelineBucket: Equatable {
    public let monthStart: Date?
    public let label: String
    public let firstItemPath: String
    public let count: Int
    public let isYearStart: Bool
    /// Time-linear position on the rail: 0.0 = newest month, 1.0 = oldest month.
    public let yFraction: Double
    /// Volume of media in this bucket relative to the busiest dated bucket (0...1).
    public let densityFraction: Double
}

public enum TimelineIndex {
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func compute(items: [MediaItem]) -> [TimelineBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var buckets: [TimelineBucket] = []
        var currentKey: DateComponents?
        var currentStart: Date?
        var currentFirst: String?
        var currentCount = 0
        var undatedFirst: String?
        var undatedCount = 0

        func flush() {
            if let first = currentFirst, let start = currentStart, currentCount > 0 {
                buckets.append(TimelineBucket(
                    monthStart: start, label: monthFormatter.string(from: start),
                    firstItemPath: first, count: currentCount, isYearStart: false,
                    yFraction: 0, densityFraction: 0))
            }
            currentKey = nil; currentStart = nil; currentFirst = nil; currentCount = 0
        }

        for item in items {
            guard let date = item.dateTaken else {
                if undatedFirst == nil { undatedFirst = item.path }
                undatedCount += 1
                continue
            }
            let key = calendar.dateComponents([.year, .month], from: date)
            if key != currentKey {
                flush()
                currentKey = key
                currentStart = calendar.date(from: key)
                currentFirst = item.path
            }
            currentCount += 1
        }
        flush()
        if let first = undatedFirst {
            buckets.append(TimelineBucket(monthStart: nil, label: "Undated",
                                          firstItemPath: first, count: undatedCount,
                                          isYearStart: false, yFraction: 1.0, densityFraction: 0))
        }

        // Time-linear y-position: 0 = newest month, 1 = oldest month.
        let datedStarts = buckets.compactMap { $0.monthStart }
        let newestStart = datedStarts.max()
        let oldestStart = datedStarts.min()
        let span = max(newestStart.map { newest in
            oldestStart.map { newest.timeIntervalSince($0) } ?? 1
        } ?? 1, 1)
        let maxCount = buckets.filter { $0.monthStart != nil }.map(\.count).max() ?? 1

        // Year flags: first dated bucket of each distinct year.
        var seenYears: Set<Int> = []
        return buckets.map { bucket in
            guard let start = bucket.monthStart, let newest = newestStart else {
                // Undated bucket: fixed at the bottom of the rail.
                return TimelineBucket(monthStart: bucket.monthStart, label: bucket.label,
                                      firstItemPath: bucket.firstItemPath, count: bucket.count,
                                      isYearStart: false, yFraction: 1.0,
                                      densityFraction: Double(bucket.count) / Double(maxCount))
            }
            let year = calendar.component(.year, from: start)
            let isFirst = !seenYears.contains(year)
            seenYears.insert(year)
            let yFraction = newest.timeIntervalSince(start) / span
            let densityFraction = Double(bucket.count) / Double(maxCount)
            return TimelineBucket(monthStart: bucket.monthStart, label: bucket.label,
                                  firstItemPath: bucket.firstItemPath, count: bucket.count,
                                  isYearStart: isFirst, yFraction: yFraction,
                                  densityFraction: densityFraction)
        }
    }
}
