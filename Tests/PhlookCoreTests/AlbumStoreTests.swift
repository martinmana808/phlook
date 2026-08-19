import Testing
import Foundation
@testable import PhlookCore

struct AlbumStoreTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    @Test func crudAndMembership() throws {
        let i = try newIndex()
        let party = try i.createAlbum(name: "  Party  ")           // trimmed
        #expect(try i.createAlbum(name: "party") == party)          // case-insensitive existing → same id
        #expect(throws: MediaIndex.AlbumError.emptyName) { _ = try i.createAlbum(name: "   ") }

        try i.addToAlbum(party, paths: ["/a.jpg", "/b.jpg", "/a.jpg"]) // idempotent dup
        #expect(try i.albumMemberPaths(party) == ["/a.jpg", "/b.jpg"])
        #expect(try i.albums().first(where: { $0.id == party })?.count == 2)
        #expect(try i.albumIDs(forPath: "/a.jpg") == [party])

        try i.removeFromAlbum(party, paths: ["/a.jpg"])
        #expect(try i.albumMemberPaths(party) == ["/b.jpg"])

        try i.renameAlbum(id: party, to: "Fiesta")
        #expect(try i.albums().first(where: { $0.id == party })?.name == "Fiesta")

        try i.deleteAlbum(id: party)
        #expect(try i.albums().isEmpty)
        #expect(try i.albumMemberPaths(party).isEmpty)              // cascade
    }
}
