import Testing
import Foundation
@testable import PhlookCore

struct ArchiveServiceTests {
    // A fake encoder: writes a tiny stand-in file, records calls, can be told to throw.
    final class FakeEncoder: SmallVersionEncoding {
        var shouldThrow = false
        private(set) var calls: [String] = []
        func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL {
            calls.append(original.lastPathComponent)
            if shouldThrow { throw SmallVersionError.encodeFailed }
            try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
            let out = proxyDir.appendingPathComponent(original.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(fileType == "video" ? "mp4" : "jpg")
            try Data("small".utf8).write(to: out)
            return out
        }
    }

    struct World {
        let lib: URL; let ssd: URL; let proxy: URL
        let index: MediaIndex; let service: ArchiveService; let encoder: FakeEncoder
        let target: ArchiveTarget
    }

    private func makeWorld() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = root.appendingPathComponent("lib")
        let ssd = root.appendingPathComponent("ssd")
        let proxy = root.appendingPathComponent("proxy")
        for d in [lib, ssd.appendingPathComponent("PHLOOK"), proxy] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let index = try MediaIndex(dbPath: root.appendingPathComponent("t.db").path)
        let encoder = FakeEncoder()
        let service = ArchiveService(index: index, encoder: encoder, proxyDir: proxy)
        try SSDArchiveTarget.setUp(volumeRoot: ssd, markerID: "m")
        let target = ArchiveTarget(volumeRoot: ssd, markerID: "m")
        return World(lib: lib, ssd: ssd, proxy: proxy, index: index, service: service, encoder: encoder, target: target)
    }

    private func addOriginal(_ w: World, _ name: String, _ bytes: String, type: String) throws -> MediaItem {
        let url = w.lib.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        let item = MediaItem(path: url.path, hash: "scan", dateTaken: nil, fileType: type,
                             width: nil, height: nil, lastScanned: Date(), fileSize: bytes.count)
        try w.index.upsert(item)
        return try w.index.item(forPath: url.path)!
    }

    @Test func happyPathReachesAllThreeStatesInOrder() throws {
        let w = try makeWorld()
        let item = try addOriginal(w, "a.heic", "ORIGINALBYTES", type: "image")
        let report = w.service.run(target: w.target, items: [item], isCancelled: { false })

        #expect(report.archived == 1)
        #expect(report.shrunk == 1)
        #expect(report.reclaimed == 1)
        #expect(report.failures.isEmpty)

        // SSD master exists and matches; proxy exists; local original gone; row survives with state.
        let master = w.ssd.appendingPathComponent("PHLOOK/a.heic")
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(!FileManager.default.fileExists(atPath: item.path))       // reclaimed
        let row = try w.index.item(forPath: item.path)
        #expect(row?.archivedHash == FileHasher.sha256(of: master))
        #expect(row?.smallPath == w.proxy.appendingPathComponent("a.jpg").path)
    }

    @Test func corruptCopyFailsVerifyAndKeepsOriginal() throws {
        let w = try makeWorld()
        let item = try addOriginal(w, "f.heic", "GOODBYTES", type: "image")
        // A copy that lands WRONG bytes at the destination (simulated disk/USB corruption).
        let corrupting = ArchiveService(index: w.index, encoder: w.encoder, proxyDir: w.proxy,
                                        copyFile: { _, dst in try Data("CORRUPT".utf8).write(to: dst) })
        let report = corrupting.run(target: w.target, items: [item], isCancelled: { false })

        #expect(report.archived == 0)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: item.path))            // original KEPT
        #expect(try w.index.item(forPath: item.path)?.archivedHash == nil)    // not marked archived
        // No partial or final file left behind at the SSD destination:
        #expect(!FileManager.default.fileExists(atPath: w.ssd.appendingPathComponent("PHLOOK/f.heic").path))
        #expect(!FileManager.default.fileExists(atPath: w.ssd.appendingPathComponent("PHLOOK/f.heic.phlook-partial").path))
    }

    @Test func hashMismatchOnReadBackKeepsOriginalAndClearsPartial() throws {
        // Pre-places a DIFFERENT-content file at the final destination path so the
        // collision-detection branch (dest exists, hash differs from original) fires;
        // this exercises skippedCollisions, not the copy-verify guard.
        let w = try makeWorld()
        let item = try addOriginal(w, "b.mov", "VIDEOBYTES", type: "video")
        // Put a colliding file with different content at the destination:
        let dest = w.ssd.appendingPathComponent("PHLOOK/b.mov")
        try Data("DIFFERENT".utf8).write(to: dest)

        let report = w.service.run(target: w.target, items: [item], isCancelled: { false })
        #expect(report.archived == 0)
        #expect(report.skippedCollisions == ["b.mov"])        // different hash at dest ⇒ collision
        #expect(FileManager.default.fileExists(atPath: item.path))   // original kept
        #expect(try w.index.item(forPath: item.path)?.archivedHash == nil)
    }

    @Test func idempotentWhenAlreadyArchivedSameHash() throws {
        let w = try makeWorld()
        let item = try addOriginal(w, "c.heic", "SAME", type: "image")
        // Pre-place identical bytes at dest (as if a prior run already copied it).
        let dest = w.ssd.appendingPathComponent("PHLOOK/c.heic")
        try Data("SAME".utf8).write(to: dest)

        let report = w.service.run(target: w.target, items: [item], isCancelled: { false })
        #expect(report.archived == 1)                 // recognized as archived, proceeds to shrink+reclaim
        #expect(report.reclaimed == 1)
        #expect(try w.index.item(forPath: item.path)?.archivedHash == FileHasher.sha256(of: dest))
    }

    @Test func encodeFailureKeepsOriginalAfterArchival() throws {
        let w = try makeWorld()
        w.encoder.shouldThrow = true
        let item = try addOriginal(w, "d.heic", "BYTES", type: "image")
        let report = w.service.run(target: w.target, items: [item], isCancelled: { false })

        #expect(report.archived == 1)                 // SSD copy succeeded
        #expect(report.shrunk == 0)
        #expect(report.reclaimed == 0)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: item.path))   // original KEPT (invariant)
        #expect(try w.index.item(forPath: item.path)?.smallPath == nil)
    }

    @Test func cancelBeforeItemSkipsIt() throws {
        let w = try makeWorld()
        let a = try addOriginal(w, "e1.heic", "AAAA", type: "image")
        let b = try addOriginal(w, "e2.heic", "BBBB", type: "image")
        var seen = 0
        let report = w.service.run(target: w.target, items: [a, b], isCancelled: { seen += 1; return seen > 1 })
        // First item processed, second cancelled before starting.
        #expect(report.archived == 1)
        #expect(FileManager.default.fileExists(atPath: b.path))    // b untouched
    }

    @Test func reportsProgressAfterEachItem() throws {
        let w = try makeWorld()
        let a = try addOriginal(w, "p1.heic", "AAAA", type: "image")
        let b = try addOriginal(w, "p2.heic", "BBBB", type: "image")
        let c = try addOriginal(w, "p3.heic", "CCCC", type: "image")
        var progress: [(Int, Int)] = []
        let report = w.service.run(target: w.target, items: [a, b, c], isCancelled: { false }) { done, total in
            progress.append((done, total))
        }
        #expect(report.archived == 3)
        #expect(progress.map { $0.0 } == [1, 2, 3])
        #expect(progress.map { $0.1 } == [3, 3, 3])
    }

    @Test func progressStopsAtCancellationPoint() throws {
        let w = try makeWorld()
        let a = try addOriginal(w, "q1.heic", "AAAA", type: "image")
        let b = try addOriginal(w, "q2.heic", "BBBB", type: "image")
        var seen = 0
        var progress: [(Int, Int)] = []
        let report = w.service.run(target: w.target, items: [a, b], isCancelled: { seen += 1; return seen > 1 }) { done, total in
            progress.append((done, total))
        }
        #expect(report.archived == 1)
        #expect(progress.map { $0.0 } == [1])
        #expect(progress.map { $0.1 } == [2])
    }

    // FIX 3: the marker must be re-verified before each file, not just once
    // at target-resolution time — if the SSD was ejected and /Volumes/<name>
    // got recreated on the boot volume, a stale-but-still-open target must
    // not let the run copy to (and reclaim from) the wrong disk.
    @Test func markerGoneMidRunStopsWithoutArchivingAnything() throws {
        let w = try makeWorld()
        let item = try addOriginal(w, "g.heic", "GBYTES", type: "image")
        // Simulate the drive having been ejected/replaced: remove the marker.
        try FileManager.default.removeItem(at: w.ssd.appendingPathComponent(".phlook_archive"))

        let report = w.service.run(target: w.target, items: [item], isCancelled: { false })

        #expect(report.archived == 0)
        #expect(FileManager.default.fileExists(atPath: item.path))           // original untouched
        #expect(try w.index.item(forPath: item.path)?.archivedHash == nil)   // not marked archived
        #expect(report.failures.contains { $0.contains("disconnected") })
        // Nothing landed on the "SSD" (boot-volume stand-in) either.
        #expect(!FileManager.default.fileExists(atPath: w.ssd.appendingPathComponent("PHLOOK/g.heic").path))
    }
}
