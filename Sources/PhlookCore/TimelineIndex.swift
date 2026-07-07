import Foundation

public struct TimelineBucket: Equatable {
    public let monthStart: Date?
    public let label: String
    public let firstItemPath: String
    public let count: Int
    public let isYearStart: Bool
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
                    firstItemPath: first, count: currentCount, isYearStart: false))
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
                                          isYearStart: false))
        }
        // Year flags: first dated bucket of each distinct year.
        var seenYears: Set<Int> = []
        return buckets.map { bucket in
            guard let start = bucket.monthStart else { return bucket }
            let year = calendar.component(.year, from: start)
            let isFirst = !seenYears.contains(year)
            seenYears.insert(year)
            return TimelineBucket(monthStart: bucket.monthStart, label: bucket.label,
                                  firstItemPath: bucket.firstItemPath, count: bucket.count,
                                  isYearStart: isFirst)
        }
    }
}
