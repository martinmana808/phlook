import Foundation

public extension IngestReport {
    var summaryText: String {
        if moved.isEmpty && leftInStaging.isEmpty {
            return "staging is empty — nothing to ingest"
        }
        var lines = ["✅ moved: \(moved.count)"]
        if !fallbackDated.isEmpty {
            lines.append("⚠️  dated by file-creation fallback (\(fallbackDated.count)) — capture time unknown, check names:")
            lines += fallbackDated.map { "     \($0)" }
        }
        if !skippedDuplicates.isEmpty {
            lines.append("⚠️  skipped duplicates, left in staging (\(skippedDuplicates.count)):")
            lines += skippedDuplicates.map { "     \($0)" }
        }
        if !unsupported.isEmpty {
            lines.append("⚠️  unsupported files, left in staging (\(unsupported.count)):")
            lines += unsupported.map { "     \($0)" }
        }
        lines.append(isClean
            ? "✅ CLEAN — safe to delete originals from the device"
            : "⚠️  NOT CLEAN — review the files left in staging")
        return lines.joined(separator: "\n")
    }
}
