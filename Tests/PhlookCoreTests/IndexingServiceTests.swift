import Testing
import Foundation
@testable import PhlookCore

struct IndexingServiceTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("a.jpg"), width: 32, height: 32)
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("b.jpg"), width: 48, height: 24)
        return root
    }

    @Test func reindexPopulatesAndRebuilds() throws {
        let root = try makeRoot()
        let service = IndexingService(root: root)
        #expect(try service.reindex() == 2)
        func signature(_ s: IndexingService) throws -> [String] {
            try s.items().map { "\($0.path)|\($0.hash ?? "")|\($0.fileType)|\($0.width ?? -1)x\($0.height ?? -1)" }.sorted()
        }
        let before = try signature(service)
        #expect(before.count == 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("phlook.db"))
        let rebuilt = IndexingService(root: root)
        #expect(try rebuilt.reindex() == 2)
        #expect(try signature(rebuilt) == before)
    }

    @Test func initDoesNotCrashOnMissingRoot() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("PHLOOK")
        let service = IndexingService(root: missing)   // must not crash
        #expect(try service.reindex() == 0)
    }
}
