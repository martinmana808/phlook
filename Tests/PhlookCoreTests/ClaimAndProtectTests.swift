import Testing
import Foundation
@testable import PhlookCore

struct ClaimAndProtectTests {
    private func world() throws -> (root: URL, index: MediaIndex, svc: IndexingService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let svc = IndexingService(root: root.appendingPathComponent("lib"))
        return (root, svc.mediaIndex, svc)
    }

    @Test func protectedItemIsArchivedButNotShrunkOrReclaimed() throws {
        // Fake encoder that would flag if called
        final class Flag: SmallVersionEncoding {
            var called = false
            func makeSmallVersion(from o: URL, fileType: String, into d: URL) throws -> URL { called = true; return o }
        }
        let w = try world()
        let orig = w.svc.root.appendingPathComponent("p.heic")
        try Data("MASTER".utf8).write(to: orig)
        var item = MediaItem(path: orig.path, hash: "scan", dateTaken: nil, fileType: "image",
                             width: nil, height: nil, lastScanned: Date(), fileSize: 6, protected: true)
        try w.index.upsert(item)
        item = try w.index.item(forPath: orig.path)!

        let ssd = w.root.appendingPathComponent("ssd")
        try FileManager.default.createDirectory(at: ssd.appendingPathComponent("PHLOOK"), withIntermediateDirectories: true)
        try SSDArchiveTarget.setUp(volumeRoot: ssd, markerID: "m")
        let target = ArchiveTarget(volumeRoot: ssd, markerID: "m")
        let enc = Flag()
        let report = ArchiveService(index: w.index, encoder: enc, proxyDir: w.root.appendingPathComponent("proxy"))
            .run(target: target, items: [item], isCancelled: { false })

        #expect(report.archived == 1)
        #expect(report.shrunk == 0)
        #expect(report.reclaimed == 0)
        #expect(enc.called == false)                               // never shrunk
        #expect(FileManager.default.fileExists(atPath: orig.path)) // original kept (full res)
        #expect(FileManager.default.fileExists(atPath: ssd.appendingPathComponent("PHLOOK/p.heic").path)) // backed up
    }

    @Test func claimFullSizeRestoresOriginalAndProtects() throws {
        let w = try world()
        let name = "c.heic"
        let localPath = w.svc.root.appendingPathComponent(name).path
        // simulate a reclaimed item: original gone locally, master on SSD, has a 10% proxy
        let ssd = w.root.appendingPathComponent("ssd")
        try FileManager.default.createDirectory(at: ssd.appendingPathComponent("PHLOOK"), withIntermediateDirectories: true)
        let masterURL = ssd.appendingPathComponent("PHLOOK/\(name)")
        try Data("REALMASTER".utf8).write(to: masterURL)
        try SSDArchiveTarget.setUp(volumeRoot: ssd, markerID: "m")
        try w.index.setMarkerID("m", label: "ssd")   // so resolveArchiveTarget can find it via mountedVolumeRoots? see note
        let proxyDir = w.svc.proxyRoot
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let proxy = proxyDir.appendingPathComponent("c.jpg"); try Data("small".utf8).write(to: proxy)
        var item = MediaItem(path: localPath, hash: "h", dateTaken: nil, fileType: "image",
                             width: nil, height: nil, lastScanned: Date(), smallPath: proxy.path)
        // archivedHash must match the real master's sha256 for the copy-verify step to pass
        item.archivedHash = FileHasher.sha256(of: masterURL)
        try w.index.upsert(item)
        item = try w.index.item(forPath: localPath)!

        // Inject the target directly to avoid depending on mounted volumes in a test:
        let ok = try w.svc.claimFullSize(item, resolvedTarget: ArchiveTarget(volumeRoot: ssd, markerID: "m"))
        #expect(ok == true)
        #expect(FileManager.default.fileExists(atPath: localPath))          // original restored
        let row = try w.index.item(forPath: localPath)
        #expect(row?.protected == true)
        #expect(row?.smallPath == nil)
        #expect(!FileManager.default.fileExists(atPath: proxy.path))        // proxy removed
    }

    // FIX 2: if the copied master doesn't match the recorded archivedHash
    // (corrupt/partial copy), claimFullSize must NOT touch the local
    // original or proxy, must NOT mark the item claimed, and must clean up
    // its temp file. Returns false.
    @Test func claimFullSizeRejectsCorruptCopyAndLeavesOriginalsIntact() throws {
        let w = try world()
        let name = "d.heic"
        let localPath = w.svc.root.appendingPathComponent(name).path
        try Data("LOCAL-ORIGINAL".utf8).write(to: URL(fileURLWithPath: localPath))
        let ssd = w.root.appendingPathComponent("ssd")
        try FileManager.default.createDirectory(at: ssd.appendingPathComponent("PHLOOK"), withIntermediateDirectories: true)
        try Data("CORRUPT-OR-WRONG-MASTER".utf8).write(to: ssd.appendingPathComponent("PHLOOK/\(name)"))
        try SSDArchiveTarget.setUp(volumeRoot: ssd, markerID: "m")
        try w.index.setMarkerID("m", label: "ssd")
        let proxyDir = w.svc.proxyRoot
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let proxy = proxyDir.appendingPathComponent("d.jpg"); try Data("small".utf8).write(to: proxy)
        var item = MediaItem(path: localPath, hash: "h", dateTaken: nil, fileType: "image",
                             width: nil, height: nil, lastScanned: Date(), smallPath: proxy.path)
        item.archivedHash = "expected-hash-that-will-not-match"
        try w.index.upsert(item)
        item = try w.index.item(forPath: localPath)!

        let ok = try w.svc.claimFullSize(item, resolvedTarget: ArchiveTarget(volumeRoot: ssd, markerID: "m"))
        #expect(ok == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: localPath)) == Data("LOCAL-ORIGINAL".utf8)) // untouched
        let row = try w.index.item(forPath: localPath)
        #expect(row?.protected == false)          // not claimed
        #expect(row?.smallPath == proxy.path)     // proxy record untouched
        #expect(FileManager.default.fileExists(atPath: proxy.path))          // proxy not deleted
        #expect(!FileManager.default.fileExists(atPath: localPath + ".claim-partial"))  // temp cleaned up
    }
}
