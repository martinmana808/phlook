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

    /// Summary for an import run: with download failures, the deletion
    /// green-light is withheld no matter how clean the ingest itself was.
    func summaryText(downloadFailures: Int) -> String {
        guard downloadFailures > 0 else { return summaryText }
        let lines = summaryText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("CLEAN — safe to delete") }
        return lines.joined(separator: "\n")
            + "\n⚠️ NOT CLEAN — \(downloadFailures) download(s) failed. Do NOT delete anything from the phone yet."
    }
}
