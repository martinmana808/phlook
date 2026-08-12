import Testing
@testable import PhlookCore

struct ReclaimStatusTests {
    private func counts(_ needs: Int, small: Int, recl: Int, bytes: Int) -> MediaIndex.ArchiveCounts {
        .init(needsArchiving: needs, hasSmall: small, reclaimable: recl, reclaimableBytes: bytes)
    }

    @Test func disabledWhenSSDAbsent() {
        let s = ReclaimStatus(ssdConnected: false, counts: counts(10, small: 0, recl: 0, bytes: 0))
        #expect(s.canArchive == false)
        #expect(s.buttonSubtitle == "Connect PHLOOK_SSD to archive")
    }

    @Test func enabledWithWorkAndReports() {
        let gb = 3 * 1_073_741_824
        let s = ReclaimStatus(ssdConnected: true, counts: counts(5, small: 2, recl: 2, bytes: gb))
        #expect(s.canArchive == true)
        #expect(s.buttonSubtitle == "5 not yet archived · 3.0 GB reclaimable")
    }

    @Test func nothingToArchiveDisablesButtonEvenWithSSD() {
        let s = ReclaimStatus(ssdConnected: true, counts: counts(0, small: 9, recl: 9, bytes: 0))
        #expect(s.canArchive == false)
    }

    @Test func importLineOmittedWhenNothingPending() {
        #expect(ReclaimStatus.humanImportLine(newToImport: 4, needsArchiving: 0) == nil)
        #expect(ReclaimStatus.humanImportLine(newToImport: 4, needsArchiving: 312)
                == "…and 312 items still need archiving.")
    }
}
