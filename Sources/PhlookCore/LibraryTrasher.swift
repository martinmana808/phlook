import Foundation

public struct TrashOutcome: Equatable {
    public let trashedPaths: [String]
    public let failures: [String]
}

/// Moves library files to the macOS Trash (recoverable) and prunes their
/// index rows. Per-file failures never abort the batch. A path whose file is
/// already missing is pruned as a success — the row was stale.
public enum LibraryTrasher {
    public static func trash(paths: [String], index: MediaIndex) -> TrashOutcome {
        let fm = FileManager.default
        var trashed: [String] = []
        var failures: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if !fm.fileExists(atPath: path) {
                trashed.append(path)                    // stale row: prune
                continue
            }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.append(path)
            } catch {
                failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        do {
            try index.delete(paths: trashed)
        } catch {
            // Files are already in the Trash; rows will self-heal on the next
            // rescan (deleteMissing), but the user should know the grid may
            // briefly show ghosts.
            failures.append("index update failed (\(error.localizedDescription)) — deleted items may linger in the grid until the next rescan")
        }
        return TrashOutcome(trashedPaths: trashed, failures: failures)
    }
}
