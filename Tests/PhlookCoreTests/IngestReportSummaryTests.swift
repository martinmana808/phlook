import Testing
@testable import PhlookCore

struct IngestReportSummaryTests {
    @Test func emptyReportSaysNothingToIngest() {
        #expect(IngestReport().summaryText == "staging is empty — nothing to ingest")
    }

    @Test func cleanReportEndsWithGreenLight() {
        var r = IngestReport()
        r.moved = ["a.jpg", "b.mov"]
        let text = r.summaryText
        #expect(text.contains("moved: 2"))
        #expect(text.contains("CLEAN — safe to delete originals from the device"))
        #expect(!text.contains("NOT CLEAN"))
    }

    @Test func dirtyReportListsLeftoversAndWithholdsGreenLight() {
        var r = IngestReport()
        r.moved = ["a.jpg"]
        r.skippedDuplicates = ["dupe.jpg"]
        r.unsupported = ["notes.txt"]
        r.fallbackDated = ["a.jpg"]
        let text = r.summaryText
        #expect(text.contains("moved: 1"))
        #expect(text.contains("dupe.jpg"))
        #expect(text.contains("notes.txt"))
        #expect(text.contains("a.jpg")) // fallback-dated listing
        #expect(text.contains("NOT CLEAN"))
    }

    @Test func downloadFailuresWithholdTheGreenLight() {
        var r = IngestReport()
        r.moved = ["a.jpg"]
        let text = r.summaryText(downloadFailures: 2)
        #expect(!text.contains("safe to delete"))
        #expect(text.contains("NOT CLEAN — 2 download(s) failed"))
    }

    @Test func zeroDownloadFailuresLeaveSummaryUntouched() {
        var r = IngestReport()
        r.moved = ["a.jpg"]
        #expect(r.summaryText(downloadFailures: 0) == r.summaryText)
    }
}
