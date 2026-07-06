import Foundation

public enum DateSource: String, Equatable {
    case exif, videoMetadata, fileCreation
}

/// A capture instant plus the timezone whose wall-clock time should appear
/// in the filename. EXIF dates are wall time already (parse and render in
/// the same zone); QuickTime dates carry an explicit offset we preserve.
public struct CaptureDate: Equatable {
    public let date: Date
    public let timeZone: TimeZone
    public let source: DateSource

    public init(date: Date, timeZone: TimeZone, source: DateSource) {
        self.date = date
        self.timeZone = timeZone
        self.source = source
    }

    public func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// Parses com.apple.quicktime.creationdate values, e.g.
    /// "2026-03-08T13:56:58-0300", "2026-03-08T13:56:58-03:00", "...58Z",
    /// with optional fractional seconds.
    public static func parseQuickTime(_ s: String) -> CaptureDate? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",      // -03:00 or Z
            "yyyy-MM-dd'T'HH:mm:ssZ",          // -0300
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        ]
        for fmt in formats {
            f.dateFormat = fmt
            if let date = f.date(from: s) {
                return CaptureDate(date: date, timeZone: offsetTimeZone(from: s), source: .videoMetadata)
            }
        }
        return nil
    }

    /// Extracts the trailing UTC offset from an already-validated date string.
    static func offsetTimeZone(from s: String) -> TimeZone {
        if s.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
        // Strip colons so both "-03:00" and "-0300" end in a 5-char "-0300" tail.
        let compact = s.replacingOccurrences(of: ":", with: "")
        let tail = compact.suffix(5)
        guard let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(tail.dropFirst().prefix(2)),
              let minutes = Int(tail.suffix(2)) else { return .current }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds) ?? .current
    }
}
