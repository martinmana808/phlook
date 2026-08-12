import Testing
import Foundation
@testable import PhlookCore

struct FileHasherTests {
    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func hashesKnownContentDeterministically() throws {
        let dir = try tmpDir()
        let a = dir.appendingPathComponent("a.bin")
        try Data("hello phlook".utf8).write(to: a)
        let h1 = FileHasher.sha256(of: a)
        let h2 = FileHasher.sha256(of: a)
        #expect(h1 != nil)
        #expect(h1 == h2)                 // deterministic
        #expect(h1?.count == 64)          // 32 bytes hex
    }

    @Test func differentContentDiffersAndMissingIsNil() throws {
        let dir = try tmpDir()
        let a = dir.appendingPathComponent("a.bin"); try Data("aaaa".utf8).write(to: a)
        let b = dir.appendingPathComponent("b.bin"); try Data("bbbb".utf8).write(to: b)
        #expect(FileHasher.sha256(of: a) != FileHasher.sha256(of: b))
        #expect(FileHasher.sha256(of: dir.appendingPathComponent("nope.bin")) == nil)
    }
}
