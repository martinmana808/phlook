import Testing
import Foundation
@testable import PhlookCore

struct IngestServiceTests {
    struct World {
        let staging: URL
        let library: URL
        var service: IngestService { IngestService(staging: staging, library: library) }
    }

    func makeWorld() throws -> World {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = base.appendingPathComponent("staging")
        let library = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return World(staging: staging, library: library)
    }

    func fixtureDate() throws -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 4
        comps.hour = 19; comps.minute = 36; comps.second = 16
        return try #require(Calendar.current.date(from: comps))
    }

    @Test func targetNamePrefixesTimestamp() {
        #expect(IngestService.targetName(originalName: "IMG_5305.HEIC", timestamp: "2026-01-04_19-36-16")
                == "2026-01-04_19-36-16_IMG_5305.HEIC")
    }

    @Test func targetNameKeepsAlreadyConventionalNames() {
        let name = "2025-11-08_18-47-37_IMG_1.jpg"
        #expect(IngestService.targetName(originalName: name, timestamp: "2026-01-04_19-36-16") == name)
    }

    @Test func movesAndRenamesDatedImage() async throws {
        let w = try makeWorld()
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate())

        let report = try await w.service.ingest()

        #expect(report.moved == ["2026-01-04_19-36-16_IMG_1.jpg"])
        #expect(report.isClean)
        #expect(FileManager.default.fileExists(
            atPath: w.library.appendingPathComponent("2026-01-04_19-36-16_IMG_1.jpg").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.staging.path).isEmpty)
    }

    @Test func duplicateInLibraryIsSkippedAndLeftInStaging() async throws {
        let w = try makeWorld()
        let finalName = "2026-01-04_19-36-16_IMG_1.jpg"
        try Data("existing".utf8).write(to: w.library.appendingPathComponent(finalName))
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate())

        let report = try await w.service.ingest()

        #expect(report.skippedDuplicates == ["IMG_1.jpg"])
        #expect(report.moved.isEmpty)
        #expect(!report.isClean)
        // Original untouched in staging; library file NOT overwritten.
        #expect(FileManager.default.fileExists(atPath: w.staging.appendingPathComponent("IMG_1.jpg").path))
        let content = try Data(contentsOf: w.library.appendingPathComponent(finalName))
        #expect(content == Data("existing".utf8))
    }

    @Test func inBatchCollisionFirstWins() async throws {
        let w = try makeWorld()
        // Two staging files that resolve to the SAME target name: one already
        // conventional (passthrough), one renaming to that identical target.
        let clashing = "2026-01-04_19-36-16_IMG_1.jpg"
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent(clashing),
                                   width: 16, height: 16) // passthrough name
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate()) // renames to same

        let report = try await w.service.ingest()

        #expect(report.moved.count == 1)
        #expect(report.skippedDuplicates.count == 1)
        #expect(FileManager.default.fileExists(atPath: w.library.appendingPathComponent(clashing).path))
    }

    @Test func hiddenAndUnsupportedFilesAreHandled() async throws {
        let w = try makeWorld()
        try Data([0x01]).write(to: w.staging.appendingPathComponent(".osxphotos_export.db"))
        try "notes".write(to: w.staging.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)

        let report = try await w.service.ingest()

        #expect(report.unsupported == ["readme.txt"])
        #expect(report.moved.isEmpty)
        #expect(!report.isClean)
        // Hidden db never appears anywhere in the report.
        #expect(!report.leftInStaging.contains(".osxphotos_export.db"))
        #expect(FileManager.default.fileExists(atPath: w.staging.appendingPathComponent(".osxphotos_export.db").path))
    }

    @Test func emptyStagingYieldsCleanEmptyReport() async throws {
        let w = try makeWorld()
        let report = try await w.service.ingest()
        #expect(report == IngestReport())
        #expect(report.isClean)
    }

    @Test func missingStagingDirectoryThrows() async throws {
        let w = try makeWorld()
        let gone = w.staging.appendingPathComponent("nope")
        let service = IngestService(staging: gone, library: w.library)
        await #expect(throws: IngestError.stagingMissing(gone.path)) {
            _ = try await service.ingest()
        }
    }

    @Test func secondRunOverLeftoversIsIdempotent() async throws {
        let w = try makeWorld()
        try "notes".write(to: w.staging.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)
        let first = try await w.service.ingest()
        let second = try await w.service.ingest()
        #expect(first == second)
    }

    @Test func moveFailureThrowsWithPartialReportAndLeavesFileInStaging() async throws {
        let w = try makeWorld()
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate())
        // Read-only library dir forces the move to fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: w.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.library.path) }

        do {
            _ = try await w.service.ingest()
            Issue.record("Expected IngestError.moveFailed to be thrown")
        } catch let IngestError.moveFailed(file, _, partial) {
            #expect(file == "IMG_1.jpg")
            #expect(partial.moved.isEmpty)
        } catch {
            Issue.record("Expected IngestError.moveFailed, got \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: w.staging.appendingPathComponent("IMG_1.jpg").path))
    }

    @Test func onSameVolumeIsTrueForTwoTempDirectories() throws {
        let w = try makeWorld()
        #expect(IngestService.onSameVolume(w.staging, w.library))
    }

    @Test func visibleSubdirectoryIsReportedAsUnsupportedAndLeftInStaging() async throws {
        let w = try makeWorld()
        let folder = w.staging.appendingPathComponent("folder-from-airdrop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let report = try await w.service.ingest()

        #expect(report.unsupported == ["folder-from-airdrop"])
        #expect(!report.isClean)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func fallbackDatedFilesAreFlagged() async throws {
        let w = try makeWorld()
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("noexif.jpg"),
                                   width: 16, height: 16) // no captureDate
        let report = try await w.service.ingest()
        #expect(report.moved.count == 1)
        #expect(report.fallbackDated == report.moved)
        #expect(report.isClean) // fallback-dated still moves; it is informational
    }
}
