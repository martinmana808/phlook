import Foundation

public struct ReclaimStatus: Equatable {
    public let ssdConnected: Bool
    public let counts: MediaIndex.ArchiveCounts

    public init(ssdConnected: Bool, counts: MediaIndex.ArchiveCounts) {
        self.ssdConnected = ssdConnected
        self.counts = counts
    }

    public var canArchive: Bool { ssdConnected && counts.needsArchiving > 0 }
    public var reclaimableGB: Double { Double(counts.reclaimableBytes) / 1_073_741_824 }

    public var buttonSubtitle: String {
        guard ssdConnected else { return "Connect PHLOOK_SSD to archive" }
        return "\(counts.needsArchiving) not yet archived · \(String(format: "%.1f", reclaimableGB)) GB reclaimable"
    }

    public static func humanImportLine(newToImport: Int, needsArchiving: Int) -> String? {
        guard needsArchiving > 0 else { return nil }
        return "…and \(needsArchiving) items still need archiving."
    }
}
