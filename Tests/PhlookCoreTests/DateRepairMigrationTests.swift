import Testing
import Foundation
import GRDB
@testable import PhlookCore

struct DateRepairMigrationTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
    }

    func makeImage(path: String, dateTaken: Date?) -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: dateTaken, fileType: "image",
                  width: 16, height: 16, lastScanned: Date())
    }

    @Test func repairsMisdatedRowFromFilenamePrefix() throws {
        let index = try MediaIndex(dbPath: tempDBPath())

        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        let wrongDate = try #require(Calendar.current.date(from: comps))

        let misdatedPath = "/x/2024-06-30_23-05-40_x.jpeg"
        try index.upsert(makeImage(path: misdatedPath, dateTaken: wrongDate))

        let matchingCD = try #require(CaptureDate.parseFilename("2024-06-30_23-05-40_x.jpeg"))
        let matchingPath = "/x/2024-06-30_23-05-40_match.jpeg"
        try index.upsert(makeImage(path: matchingPath, dateTaken: matchingCD.date))

        let nonConventionPath = "/x/IMG_1234.jpeg"
        try index.upsert(makeImage(path: nonConventionPath, dateTaken: wrongDate))

        try index.repairImageDatesFromFilenamesForTesting()

        let misdated = try #require(try index.item(forPath: misdatedPath))
        #expect(abs(misdated.dateTaken!.timeIntervalSince(matchingCD.date)) < 1)

        let matching = try #require(try index.item(forPath: matchingPath))
        #expect(matching.dateTaken == matchingCD.date)

        let nonConvention = try #require(try index.item(forPath: nonConventionPath))
        #expect(nonConvention.dateTaken == wrongDate)
    }
}
