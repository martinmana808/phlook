import Foundation

/// Ingest timestamp prefix (`YYYY-MM-DD_HH-MM-SS_`) stripped before parsing
/// the iOS-assigned basename remainder. Mirrors the prefix used elsewhere
/// (see `DuplicateFinder`'s convention-name regex and `LivePairs`).
private let timestampPrefixRegex = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_"#

public enum EditedPairFinder {
    private struct ParsedName {
        let timestamp: String
        let normalizedKey: String
        let ext: String
        let isEdited: Bool
    }

    /// Groups of an iOS original + its edited copy: same ingest timestamp
    /// prefix, same extension, basenames `IMG_<n>` vs `IMG_E<n>` (same
    /// digits). Pure, name-based, no file I/O. Each returned group is
    /// [edited, ...originals] (edited-first = keeper), and requires >= 1
    /// edited AND >= 1 original member.
    public static func pairs(items: [MediaItem]) -> [[MediaItem]] {
        var groups: [String: [MediaItem]] = [:]
        var hasEdited: [String: Bool] = [:]
        var hasOriginal: [String: Bool] = [:]

        for item in items {
            guard let parsed = parseName(item.path) else { continue }
            let key = "\(parsed.timestamp)#\(parsed.normalizedKey)#\(parsed.ext)"
            groups[key, default: []].append(item)
            if parsed.isEdited {
                hasEdited[key] = true
            } else {
                hasOriginal[key] = true
            }
        }

        var result: [[MediaItem]] = []
        for (key, members) in groups where members.count >= 2 {
            guard hasEdited[key] == true, hasOriginal[key] == true else { continue }
            result.append(sortEditedFirst(members))
        }
        return result
    }

    private static func sortEditedFirst(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { a, b in
            let aEdited = parseName(a.path)?.isEdited ?? false
            let bEdited = parseName(b.path)?.isEdited ?? false
            if aEdited != bEdited { return aEdited }
            return a.path < b.path
        }
    }

    /// Parses a basename into (timestamp, normalized IMG_<digits> key, ext,
    /// isEdited). Returns nil for names that don't match the ingest
    /// timestamp convention or the `IMG_(E?)<digits>` pattern (e.g.
    /// UUID-cored live-motion resource names like `..._3.mov`).
    private static func parseName(_ path: String) -> ParsedName? {
        let filename = (path as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        let nameNoExt = (filename as NSString).deletingPathExtension

        guard let tsRange = nameNoExt.range(of: timestampPrefixRegex, options: .regularExpression) else {
            return nil
        }
        let timestamp = String(nameNoExt[tsRange])
        let remainder = String(nameNoExt[tsRange.upperBound...])

        if remainder.hasPrefix("IMG_E") {
            let rest = remainder.dropFirst("IMG_E".count)
            guard let first = rest.first, first.isNumber else { return nil }
            return ParsedName(timestamp: timestamp, normalizedKey: "IMG_\(rest)", ext: ext, isEdited: true)
        } else if remainder.hasPrefix("IMG_") {
            let rest = remainder.dropFirst("IMG_".count)
            guard let first = rest.first, first.isNumber else { return nil }
            return ParsedName(timestamp: timestamp, normalizedKey: remainder, ext: ext, isEdited: false)
        }
        return nil
    }
}
