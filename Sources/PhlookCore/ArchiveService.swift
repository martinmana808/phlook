// Sources/PhlookCore/ArchiveService.swift
import Foundation

public struct ArchiveReport: Equatable {
    public var archived = 0
    public var shrunk = 0
    public var reclaimed = 0
    public var skippedCollisions: [String] = []
    public var failures: [String] = []
    public init() {}
}

/// Orchestrates the per-file archive pipeline in strict order:
/// hash → copy → verify → mark archived → shrink → mark small → reclaim original.
/// Any stage failing aborts THAT file only and leaves its local original intact.
/// Serial by design (limited free disk); cancellable between files, never mid-file.
public final class ArchiveService {
    private let index: MediaIndex
    private let encoder: SmallVersionEncoding
    private let proxyDir: URL
    private let copyFile: (URL, URL) throws -> Void

    public init(index: MediaIndex, encoder: SmallVersionEncoding, proxyDir: URL,
                copyFile: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        self.index = index
        self.encoder = encoder
        self.proxyDir = proxyDir
        self.copyFile = copyFile
    }

    public func run(target: ArchiveTarget, items: [MediaItem], isCancelled: () -> Bool) -> ArchiveReport {
        let fm = FileManager.default
        var report = ArchiveReport()

        for item in items {
            if isCancelled() { break }
            let original = URL(fileURLWithPath: item.path)
            let name = original.lastPathComponent
            guard fm.fileExists(atPath: original.path) else { continue }   // already reclaimed elsewhere

            // 1. hash the master
            guard let h = FileHasher.sha256(of: original) else {
                report.failures.append("\(name) — could not read original"); continue
            }

            let dest = target.phlookRoot.appendingPathComponent(name)
            var archivedThisFile = item.archivedHash != nil

            if !archivedThisFile {
                do {
                    try fm.createDirectory(at: target.phlookRoot, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) {
                        // A file already occupies the FINAL destination name.
                        guard let destHash = FileHasher.sha256(of: dest) else {
                            report.failures.append("\(name) — could not read existing SSD file"); continue
                        }
                        if destHash == h {
                            // Identical bytes already archived (idempotent resume).
                        } else {
                            report.skippedCollisions.append(name); continue
                        }
                    } else {
                        // Copy to a temp partial, verify the read-back, then move atomically.
                        // A crash leaves the ".phlook-partial" file (not the real name), so it is
                        // never mistaken for a genuine collision and is cleared on the next run.
                        let tmp = target.phlookRoot.appendingPathComponent(name + ".phlook-partial")
                        try? fm.removeItem(at: tmp)               // clear any stale partial from a prior crash
                        try copyFile(original, tmp)
                        guard FileHasher.sha256(of: tmp) == h else {
                            try? fm.removeItem(at: tmp)
                            report.failures.append("\(name) — SSD copy failed verification"); continue
                        }
                        try fm.moveItem(at: tmp, to: dest)
                    }
                    // dest now holds verified-correct bytes. If markArchived throws here, dest is
                    // KEPT (archivedHash stays nil); the next run resumes via the identical-hash path.
                    try index.markArchived(path: item.path, hash: h, at: Date())
                    archivedThisFile = true
                    report.archived += 1
                } catch {
                    report.failures.append("\(name) — archive error: \(error.localizedDescription)"); continue
                }
            } else {
                report.archived += 1
            }

            // 6. shrink
            let smallURL: URL
            do {
                smallURL = try encoder.makeSmallVersion(from: original, fileType: item.fileType, into: proxyDir)
                try index.setSmallPath(path: item.path, smallPath: smallURL.path)
                report.shrunk += 1
            } catch {
                report.failures.append("\(name) — shrink failed: \(error.localizedDescription)")
                continue   // original KEPT — invariant holds
            }

            // 7. reclaim local original (row survives)
            let outcome = LibraryTrasher.trashFilesOnly(paths: [item.path])
            if outcome.failures.isEmpty {
                report.reclaimed += 1
            } else {
                report.failures.append(contentsOf: outcome.failures)
            }
        }
        return report
    }
}
