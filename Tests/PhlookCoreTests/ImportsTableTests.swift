import Testing
import Foundation
@testable import PhlookCore

struct ImportsTableTests {
    func makeIndex() throws -> MediaIndex {
        try MediaIndex(dbPath: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path)
    }

    @Test func recordAndQueryRoundTrip() throws {
        let index = try makeIndex()
        try index.recordImport(device: "Martin's iPhone", identifier: "IMG_1.HEIC|2026-07-06T12:00:00Z|1000")
        try index.recordImport(device: "Martin's iPhone", identifier: "IMG_2.HEIC|2026-07-06T12:01:00Z|2000")
        let ids = try index.importedIdentifiers(device: "Martin's iPhone")
        #expect(ids.count == 2)
        #expect(ids.contains("IMG_1.HEIC|2026-07-06T12:00:00Z|1000"))
    }

    @Test func recordIsIdempotent() throws {
        let index = try makeIndex()
        try index.recordImport(device: "d", identifier: "same")
        try index.recordImport(device: "d", identifier: "same")   // must not throw
        #expect(try index.importedIdentifiers(device: "d").count == 1)
    }

    @Test func devicesAreIsolated() throws {
        let index = try makeIndex()
        try index.recordImport(device: "iPhone A", identifier: "x")
        #expect(try index.importedIdentifiers(device: "iPhone B").isEmpty)
    }

    @Test func existingV2DatabaseGainsImportsTable() throws {
        // Open once (creates schema at current version), then reopen — both
        // paths must expose a working imports table.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
        _ = try MediaIndex(dbPath: path)
        let reopened = try MediaIndex(dbPath: path)
        try reopened.recordImport(device: "d", identifier: "x")
        #expect(try reopened.importedIdentifiers(device: "d") == ["x"])
    }
}
