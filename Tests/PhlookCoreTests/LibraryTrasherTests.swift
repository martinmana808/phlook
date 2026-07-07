import Testing
import Foundation
@testable import PhlookCore

struct LibraryTrasherTests {
    func makeWorld() throws -> (dir: URL, index: MediaIndex) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
        return (dir, index)
    }

    func addFile(_ dir: URL, _ name: String, _ index: MediaIndex) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try index.upsert(MediaItem(path: url.path, hash: "h", dateTaken: nil,
                                   fileType: "image", width: nil, height: nil,
                                   lastScanned: Date()))
        return url.path
    }

    @Test func deleteRemovesOnlyGivenRows() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        let b = try addFile(dir, "b.jpg", index)
        try index.delete(paths: [a])
        #expect(try index.item(forPath: a) == nil)
        #expect(try index.item(forPath: b) != nil)
        try index.delete(paths: [])   // no-op
        #expect(try index.count() == 1)
    }

    @Test func trashMovesFileAndPrunesRow() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        let outcome = LibraryTrasher.trash(paths: [a], index: index)
        #expect(outcome.trashedPaths == [a])
        #expect(outcome.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: a))   // moved to Trash
        #expect(try index.item(forPath: a) == nil)
    }

    @Test func missingFileIsPrunedAsSuccess() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        try FileManager.default.removeItem(atPath: a)          // vanished behind our back
        let outcome = LibraryTrasher.trash(paths: [a], index: index)
        #expect(outcome.trashedPaths == [a])
        #expect(try index.item(forPath: a) == nil)
    }

    @Test func partialFailureKeepsFailedRow() throws {
        let (dir, index) = try makeWorld()
        let good = try addFile(dir, "good.jpg", index)
        // A path that exists in DB but points into a read-only, un-trashable place:
        let bad = "/System/Library/CoreServices/SystemVersion.plist"
        try index.upsert(MediaItem(path: bad, hash: "h", dateTaken: nil,
                                   fileType: "image", width: nil, height: nil,
                                   lastScanned: Date()))
        let outcome = LibraryTrasher.trash(paths: [good, bad], index: index)
        #expect(outcome.trashedPaths == [good])
        #expect(outcome.failures.count == 1)
        #expect(try index.item(forPath: bad) != nil)            // row kept
    }

    @Test func indexDeleteFailureSurfacesInOutcome() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        let dbPath = dir.appendingPathComponent("t.db")

        // Break the index by replacing the db file with a directory,
        // so delete() will fail when it tries to write.
        try FileManager.default.removeItem(at: dbPath)
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: false)

        let outcome = LibraryTrasher.trash(paths: [a], index: index)
        #expect(outcome.trashedPaths == [a])           // file was trashed
        #expect(outcome.failures.count == 1)           // but index update failed
        #expect(outcome.failures[0].contains("index update failed"))
        #expect(outcome.failures[0].contains("grid until the next rescan"))
    }
}
