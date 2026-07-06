import Foundation

public enum DurationFormatter {
    /// "0:34", "12:05", "1:12:05". nil for nil or negative (incl. the -1 sentinel).
    public static func string(seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
