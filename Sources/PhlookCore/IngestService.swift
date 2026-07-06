import Foundation

public struct IngestReport: Equatable {
    public var moved: [String] = []             // final filenames now in the library
    public var skippedDuplicates: [String] = [] // original names, left in staging
    public var fallbackDated: [String] = []     // subset of moved: dated by file creation
    public var unsupported: [String] = []       // original names, left in staging

    public init() {}

    public var leftInStaging: [String] { skippedDuplicates + unsupported }
    public var isClean: Bool { skippedDuplicates.isEmpty && unsupported.isEmpty }
}

public enum IngestError: Error, Equatable {
    case stagingMissing(String)
    /// A move failed mid-batch: which file, why, and everything that had
    /// already succeeded (already-moved files STAY moved; re-running is safe).
    case moveFailed(file: String, reason: String, partial: IngestReport)
    /// Staging and library live on different volumes; a same-volume rename
    /// cannot be guaranteed and FileManager would silently degrade to
    /// copy+delete, risking a partial file under a valid final name.
    case differentVolumes(staging: String, library: String)
}

/// Moves supported media from a staging folder into the library, renaming to
/// YYYY-MM-DD_HH-MM-SS_OriginalName.ext. Invariant: every enumerated file is
/// either moved into the library or still in staging and named in the report.
/// Never overwrites. Content is never rewritten — same-volume rename only.
public struct IngestService {
    public let staging: URL
    public let library: URL
    private let extractor = CaptureDateExtractor()

    public init(staging: URL, library: URL) {
        self.staging = staging
        self.library = library
    }

    /// Whether `a` and `b` reside on the same volume. If either resource
    /// lookup fails, returns true (does not block ingest on an unreadable key).
    static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let aID = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let bID = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return true }
        return (aID as AnyObject).isEqual(bID as AnyObject)
    }

    static func targetName(originalName: String, timestamp: String) -> String {
        let conventionPrefix = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_"#
        if originalName.range(of: conventionPrefix, options: .regularExpression) != nil {
            return originalName
        }
        return "\(timestamp)_\(originalName)"
    }

    public func ingest() async throws -> IngestReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: staging.path, isDirectory: &isDir), isDir.boolValue else {
            throw IngestError.stagingMissing(staging.path)
        }
        try fm.createDirectory(at: library, withIntermediateDirectories: true)

        guard Self.onSameVolume(staging, library) else {
            throw IngestError.differentVolumes(staging: staging.path, library: library.path)
        }

        // Shallow, hidden-skipping, sorted for deterministic first-wins.
        let entries = try fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var report = IngestReport()
        var claimed = Set<String>()

        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                report.unsupported.append(url.lastPathComponent)
                continue
            }
            let original = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard LibraryScanner.imageExts.contains(ext) || LibraryScanner.videoExts.contains(ext) else {
                report.unsupported.append(original)
                continue
            }
            let capture = await extractor.captureDate(for: url)
            let name = Self.targetName(originalName: original, timestamp: capture.timestampString())
            let dest = library.appendingPathComponent(name)
            if claimed.contains(name) || fm.fileExists(atPath: dest.path) {
                report.skippedDuplicates.append(original)
                continue
            }
            do {
                try fm.moveItem(at: url, to: dest)
            } catch {
                throw IngestError.moveFailed(
                    file: original, reason: "\(error)", partial: report)
            }
            claimed.insert(name)
            report.moved.append(name)
            if capture.source == .fileCreation {
                report.fallbackDated.append(name)
            }
        }
        return report
    }
}
