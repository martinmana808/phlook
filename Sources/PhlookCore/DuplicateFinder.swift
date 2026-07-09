import Foundation

/// Naming-convention prefix used by the library's own scans/imports
/// (`YYYY-MM-DD_HH-MM-SS_...`) — a keeper candidate whose filename matches
/// this pattern is preferred over one that doesn't (e.g. an ad-hoc re-import
/// with a device-assigned name).
private let conventionNameRegex = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_"#

public enum DuplicateFinder {
    /// Groups of 2+ confirmed byte-identical items. `fullHash` computes a
    /// full-file digest for a path (injected for testability). Candidates are
    /// pre-grouped by (fileSize, quickHash stored in item.hash); a group is
    /// confirmed only when members share the SAME fullHash — a quickHash
    /// collision splits into separate confirmed groups. Each returned group is
    /// sorted keeper-first (keeper = name matches YYYY-MM-DD_HH-MM-SS_ convention,
    /// else earliest lastScanned, else shortest path).
    public static func groups(items: [MediaItem], fullHash: (String) -> String?) -> [[MediaItem]] {
        var candidates: [String: [MediaItem]] = [:]
        for item in items {
            guard let size = item.fileSize, let hash = item.hash, !hash.isEmpty else { continue }
            let key = "\(size)#\(hash)"
            candidates[key, default: []].append(item)
        }

        var result: [[MediaItem]] = []
        for (_, members) in candidates where members.count >= 2 {
            var byFullHash: [String: [MediaItem]] = [:]
            for member in members {
                guard let full = fullHash(member.path) else { continue }
                byFullHash[full, default: []].append(member)
            }
            for (_, confirmed) in byFullHash where confirmed.count >= 2 {
                result.append(sortKeeperFirst(confirmed))
            }
        }
        return result
    }

    private static func sortKeeperFirst(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { a, b in
            let aConv = matchesConvention(a.path)
            let bConv = matchesConvention(b.path)
            if aConv != bConv { return aConv }
            if a.lastScanned != b.lastScanned { return a.lastScanned < b.lastScanned }
            return a.path.count < b.path.count
        }
    }

    private static func matchesConvention(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.range(of: conventionNameRegex, options: .regularExpression) != nil
    }
}
