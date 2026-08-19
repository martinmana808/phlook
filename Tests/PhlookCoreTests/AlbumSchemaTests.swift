import Testing
import Foundation
import GRDB
@testable import PhlookCore

struct AlbumSchemaTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    @Test func schemaExistsAndCascades() throws {
        let index = try newIndex()
        try index.dbForTesting.write { db in
            try db.execute(sql: "INSERT INTO albums (name, created_at) VALUES ('Party', '2026-01-01')")
            let aid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO album_items (album_id, file_path, added_at) VALUES (?, '/x/a.jpg', '2026-01-01')", arguments: [aid])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_items") == 1)
            // ON DELETE CASCADE: deleting the album drops its items
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [aid])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_items") == 0)
        }
    }
}
