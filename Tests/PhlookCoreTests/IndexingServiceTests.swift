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
        let count = try service.reindex()
        #expect(count == 2)
        let itemCount = try service.items().count
        #expect(itemCount == 2)

        // Rebuild guarantee: delete the DB, reindex, identical count.
        try FileManager.default.removeItem(at: root.appendingPathComponent("phlook.db"))
        let rebuilt = try IndexingService(root: root).reindex()
        #expect(rebuilt == 2)
    }
}
