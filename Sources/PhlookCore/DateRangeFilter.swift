import Foundation

/// Date-taken bounds used by the sidebar date-range sliders. `lower` is
/// inclusive, `upper` is EXCLUSIVE — callers pass the start of the month
/// *after* the selected "To" month, so a date exactly at `upper` (midnight
/// of the following month) is excluded from the window it starts. Both
/// bounds nil = inactive (no filtering). An item with a nil `dateTaken`
/// (undated) only passes when both bounds are nil — an active range can
/// never include undated items.
public struct DateRangeFilter: Equatable {
    public var lower: Date?   // nil = unbounded below, inclusive
    public var upper: Date?   // nil = unbounded above, exclusive

    public init(lower: Date? = nil, upper: Date? = nil) {
        self.lower = lower
        self.upper = upper
    }

    public var isActive: Bool { lower != nil || upper != nil }

    public func matches(_ item: MediaItem) -> Bool {
        guard let date = item.dateTaken else { return !isActive }
        if let lower, date < lower { return false }
        if let upper, date >= upper { return false }
        return true
    }
}
