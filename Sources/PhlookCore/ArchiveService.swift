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

    public init(index: MediaIndex, encoder: SmallVersionEncoding, proxyDir: URL) {
        self.index = index
        self.encoder = encoder
        self.proxyDir = proxyDir
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
                    // 2. collision handling
                    if fm.fileExists(atPath: dest.path) {
                        if FileHasher.sha256(of: dest) == h {
                            // already there, identical — treat as archived
                        } else {
                            report.skippedCollisions.append(name); continue
                        }
                    } else {
                        // 3. copy
                        try fm.copyItem(at: original, to: dest)
                    }
                    // 4. verify read-back
                    guard FileHasher.sha256(of: dest) == h else {
                        try? fm.removeItem(at: dest)
                        report.failures.append("\(name) — SSD copy failed verification"); continue
                    }
                    // 5. commit archived
                    try index.markArchived(path: item.path, hash: h, at: Date())
                    archivedThisFile = true
                    report.archived += 1
                } catch {
                    try? fm.removeItem(at: dest)
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
