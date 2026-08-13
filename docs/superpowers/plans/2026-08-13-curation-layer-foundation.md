# Curation Layer — Foundation Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the archived library navigable and let the user pull originals back — DB v9 (`curated`, `protected`, `ssd_rel_path`), sidebar scopes + item badges for archive state, "Claim full size", and a "Protect" flag the shrink pass honors.

**Architecture:** Extends the shipped Phase 1 archive pipeline. All state lives on the existing `files` table via a v9 migration; scope predicates are pure functions on `MediaItem`; claim/protect are `IndexingService` methods reusing `SSDArchiveTarget`; SwiftUI wiring stays thin over tested core logic.

**Tech Stack:** Swift 5.9+, GRDB (SQLite), swift-testing (`import Testing`, `@Test`, `#expect`), SwiftUI/AppKit.

## Global Constraints

- **This is Phase 2, slice 1.** It builds on Phase 1 (on `main`): `MediaItem` already has `archivedHash`, `archivedAt`, `smallPath`; `MediaIndex` has migrations through v8, `archive_config(marker_id, ssd_label)`, `markArchived`, `setSmallPath`, `itemsNeedingArchiving` (`archived_hash IS NULL`), `itemsPendingArchiveOrShrink` (`archived_hash IS NULL OR small_path IS NULL`), `archiveCounts`, `deleteMissing` (already exempts `archived_hash IS NOT NULL` rows). `ArchiveService.run` is the per-file pipeline; `SSDArchiveTarget` resolves the drive; `MediaItem.bestLocalURL()` picks the local file to display.
- **Migration pattern:** follow the existing `PRAGMA user_version` gate + idempotent `ALTER TABLE ADD COLUMN` style in `Sources/PhlookCore/MediaIndex.swift`. Next gate is **9**.
- **`upsert` must never overwrite** `curated`/`protected`/`ssd_rel_path` (like `hidden`/`archived_hash` — only dedicated setters write them), so a rescan can't reset user intent.
- **Semantics (pure DB predicates):**
  - Not backed up = `archived_hash IS NULL`.
  - Compressed (10%) = `archived_hash IS NOT NULL AND small_path IS NOT NULL AND protected = 0`.
  - Full size / Protected = `protected = 1`.
- **Protect** = keep full-res locally, never shrink/reclaim. A protected item may still be **backed up** to the SSD, but is never shrunk or reclaimed.
- **Claim full size** = copy the master from the SSD back to the local path, set `protected = 1`, and remove the local 10% proxy. Copy-down only; nothing deleted from the SSD.
- **Deferred to slice 2 (NOT in this plan):** curation delete→`curated` flag, the "Not curated" view, `db_version`/`synced_at` versioned DB sync, disaster recovery. Do not add `curated`-based filtering or the sync columns here beyond the `curated` column itself (added now, defaulted 1, unused by UI in this slice).
- **Tests:** swift-testing; each builds a world in `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`. Run one with `swift test --filter <TypeName>`.

---

### Task 1: DB v9 columns + `MediaItem` fields

**Files:**
- Modify: `Sources/PhlookCore/MediaItem.swift`
- Modify: `Sources/PhlookCore/MediaIndex.swift` (CREATE TABLE + v9 gate)
- Test: `Tests/PhlookCoreTests/CurationColumnsTests.swift`

**Interfaces:**
- Produces: `MediaItem.curated: Bool` (default true), `MediaItem.protected: Bool` (default false), `MediaItem.ssdRelPath: String?`. Columns `curated INTEGER NOT NULL DEFAULT 1`, `protected INTEGER NOT NULL DEFAULT 0`, `ssd_rel_path TEXT`. `upsert` leaves all three untouched.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PhlookCore

struct CurationColumnsTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    @Test func curationFieldsDefaultAndSurviveUpsert() throws {
        let index = try newIndex()
        var item = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                             fileType: "image", width: nil, height: nil, lastScanned: Date())
        // defaults on a fresh item
        #expect(item.curated == true)
        #expect(item.protected == false)
        item.protected = true
        item.ssdRelPath = "PHLOOK/a.heic"
        try index.upsert(item)

        // a plain rescan (no curation fields set) must NOT reset them
        let rescan = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                               fileType: "image", width: nil, height: nil, lastScanned: Date())
        try index.upsert(rescan)

        let got = try index.item(forPath: "/x/a.heic")
        #expect(got?.protected == true)
        #expect(got?.curated == true)
        #expect(got?.ssdRelPath == "PHLOOK/a.heic")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CurationColumnsTests`
Expected: FAIL — `value of type 'MediaItem' has no member 'curated'`.

- [ ] **Step 3: Add fields to `MediaItem`**

After `public var smallPath: String?` add:
```swift
    public var curated: Bool
    public var protected: Bool
    public var ssdRelPath: String?
```
Add CodingKeys (after `case smallPath = "small_path"`):
```swift
        case curated
        case protected
        case ssdRelPath = "ssd_rel_path"
```
Extend the initializer signature (after `smallPath: String? = nil`):
```swift
                smallPath: String? = nil,
                curated: Bool = true, protected: Bool = false, ssdRelPath: String? = nil) {
```
and its body (after `self.smallPath = smallPath`):
```swift
        self.curated = curated; self.protected = protected; self.ssdRelPath = ssdRelPath
```

- [ ] **Step 4: Add columns + v9 gate in `MediaIndex`**

In the `CREATE TABLE IF NOT EXISTS files (...)` block, add before the closing `);` (after `small_path TEXT`):
```sql
                    small_path TEXT,
                    curated INTEGER NOT NULL DEFAULT 1,
                    protected INTEGER NOT NULL DEFAULT 0,
                    ssd_rel_path TEXT
```
After the `if version < 8 { ... }` block, add:
```swift
            if version < 9 {
                let cols = try db.columns(in: "files").map(\.name)
                if !cols.contains("curated") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN curated INTEGER NOT NULL DEFAULT 1")
                }
                if !cols.contains("protected") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN protected INTEGER NOT NULL DEFAULT 0")
                }
                if !cols.contains("ssd_rel_path") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN ssd_rel_path TEXT")
                }
                try db.execute(sql: "PRAGMA user_version = 9")
            }
```
> `upsert` (MediaIndex.swift) copies only named fields onto the fetched row; it never assigns `curated`/`protected`/`ssdRelPath`, so those survive a rescan. Do not add them to `upsert`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CurationColumnsTests` then `swift test --filter MediaIndexMigrationTests`
Expected: PASS both.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/MediaItem.swift Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/CurationColumnsTests.swift
git commit -m "feat: DB v9 — curated/protected/ssd_rel_path columns"
```

---

### Task 2: `MediaIndex` — protect/claim mutators + archive-state queries

**Files:**
- Modify: `Sources/PhlookCore/MediaIndex.swift`
- Test: `Tests/PhlookCoreTests/CurationQueriesTests.swift`

**Interfaces:**
- Consumes: Task 1 columns.
- Produces on `MediaIndex`:
  - `func setProtected(paths: [String], protected: Bool) throws` (chunked, like `setHidden`)
  - `func setClaimed(path: String, ssdRelPath: String) throws` — sets `protected = 1`, records `ssd_rel_path`, clears `small_path` (the item is now full-res local).
  - `func itemsToShrink() throws -> [MediaItem]` — `archived_hash IS NOT NULL AND small_path IS NULL AND protected = 0` (backed up, not yet shrunk, not protected).
  - `struct CurationCounts: Equatable { public let notBackedUp: Int; public let compressed: Int; public let fullSize: Int }` and `func curationCounts() throws -> CurationCounts`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PhlookCore

struct CurationQueriesTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }
    private func add(_ i: MediaIndex, _ p: String) throws {
        try i.upsert(MediaItem(path: p, hash: "h", dateTaken: nil, fileType: "image",
                               width: nil, height: nil, lastScanned: Date()))
    }

    @Test func protectAndClaimMutate() throws {
        let i = try newIndex()
        try add(i, "/lib/a.heic")
        try i.markArchived(path: "/lib/a.heic", hash: "ha", at: Date())
        try i.setSmallPath(path: "/lib/a.heic", smallPath: "/proxy/a.jpg")

        try i.setClaimed(path: "/lib/a.heic", ssdRelPath: "PHLOOK/a.heic")
        let a = try i.item(forPath: "/lib/a.heic")
        #expect(a?.protected == true)
        #expect(a?.ssdRelPath == "PHLOOK/a.heic")
        #expect(a?.smallPath == nil)          // no longer compressed

        try i.setProtected(paths: ["/lib/a.heic"], protected: false)
        #expect(try i.item(forPath: "/lib/a.heic")?.protected == false)
    }

    @Test func shrinkWorkSetExcludesProtected() throws {
        let i = try newIndex()
        try add(i, "/lib/b.mov"); try i.markArchived(path: "/lib/b.mov", hash: "hb", at: Date()) // backed up, not shrunk
        try add(i, "/lib/c.mov"); try i.markArchived(path: "/lib/c.mov", hash: "hc", at: Date())
        try i.setProtected(paths: ["/lib/c.mov"], protected: true)
        #expect(try i.itemsToShrink().map(\.path) == ["/lib/b.mov"])  // c excluded (protected)
    }

    @Test func curationCountsClassify() throws {
        let i = try newIndex()
        try add(i, "/lib/nb.heic")                                    // not backed up
        try add(i, "/lib/cp.heic"); try i.markArchived(path: "/lib/cp.heic", hash: "h1", at: Date()); try i.setSmallPath(path: "/lib/cp.heic", smallPath: "/p/cp.jpg") // compressed
        try add(i, "/lib/fs.heic"); try i.setProtected(paths: ["/lib/fs.heic"], protected: true) // full size
        let c = try i.curationCounts()
        #expect(c.notBackedUp == 1)
        #expect(c.compressed == 1)
        #expect(c.fullSize == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CurationQueriesTests`
Expected: FAIL — `value of type 'MediaIndex' has no member 'setClaimed'`.

- [ ] **Step 3: Add the methods**

```swift
    public struct CurationCounts: Equatable {
        public let notBackedUp: Int
        public let compressed: Int
        public let fullSize: Int
    }

    public func setProtected(paths: [String], protected: Bool) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            for chunk in stride(from: 0, to: paths.count, by: 500).map({
                Array(paths[$0..<min($0 + 500, paths.count)]) }) {
                let ph = repeatElement("?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "UPDATE files SET protected = ? WHERE path IN (\(ph))",
                               arguments: StatementArguments([protected] + chunk))
            }
        }
    }

    public func setClaimed(path: String, ssdRelPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE files SET protected = 1, ssd_rel_path = ?, small_path = NULL WHERE path = ?",
                           arguments: [ssdRelPath, path])
        }
    }

    public func itemsToShrink() throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.filter(sql: "archived_hash IS NOT NULL AND small_path IS NULL AND protected = 0").fetchAll(db)
        }
    }

    public func curationCounts() throws -> CurationCounts {
        try dbQueue.read { db in
            let nb = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE archived_hash IS NULL") ?? 0
            let cp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE archived_hash IS NOT NULL AND small_path IS NOT NULL AND protected = 0") ?? 0
            let fs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE protected = 1") ?? 0
            return CurationCounts(notBackedUp: nb, compressed: cp, fullSize: fs)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CurationQueriesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/CurationQueriesTests.swift
git commit -m "feat: MediaIndex protect/claim mutators + curation counts"
```

---

### Task 3: Sidebar scopes for archive state

**Files:**
- Modify: `Sources/PhlookCore/LibraryScope.swift`
- Test: `Tests/PhlookCoreTests/LibraryScopeTests.swift` (add cases)

**Interfaces:**
- Consumes: Task 1 fields.
- Produces: `LibraryScope.notBackedUp = "Not backed up"`, `.compressed = "Compressed"`, `.fullSize = "Full size"`. `matches(_:livePairs:)` returns: notBackedUp when `archivedHash == nil`; compressed when `archivedHash != nil && smallPath != nil && !protected`; fullSize when `protected`. All exclude hidden items (like other scopes).

- [ ] **Step 1: Write the failing test** (append to `LibraryScopeTests`)

```swift
    @Test func archiveStateScopes() throws {
        func item(_ path: String, archived: String? = nil, small: String? = nil, prot: Bool = false, hidden: Bool = false) -> MediaItem {
            MediaItem(path: path, hash: "h", dateTaken: nil, fileType: "image", width: nil, height: nil,
                      lastScanned: Date(), hidden: hidden, smallPath: small, protected: prot, ssdRelPath: nil).with(archivedHash: archived)
        }
        let lp = LivePairs.empty
        let nb = item("/nb", archived: nil)
        let cp = item("/cp", archived: "h", small: "/p.jpg")
        let fs = item("/fs", prot: true)
        #expect(LibraryScope.notBackedUp.matches(nb, livePairs: lp) == true)
        #expect(LibraryScope.notBackedUp.matches(cp, livePairs: lp) == false)
        #expect(LibraryScope.compressed.matches(cp, livePairs: lp) == true)
        #expect(LibraryScope.compressed.matches(fs, livePairs: lp) == false)  // protected ≠ compressed
        #expect(LibraryScope.fullSize.matches(fs, livePairs: lp) == true)
        // hidden always excluded
        #expect(LibraryScope.notBackedUp.matches(item("/h", archived: nil, hidden: true), livePairs: lp) == false)
    }
```
Add this tiny test helper near the top of `LibraryScopeTests` if not present:
```swift
    // convenience: MediaItem is a value type; set archivedHash via a copy
    // (kept in the test file to avoid touching production for a test detail)
```
And define `with(archivedHash:)` inline in the test file:
```swift
private extension MediaItem {
    func with(archivedHash: String?) -> MediaItem { var c = self; c.archivedHash = archivedHash; return c }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LibraryScopeTests`
Expected: FAIL — `type 'LibraryScope' has no member 'notBackedUp'`.

- [ ] **Step 3: Add the cases + predicates**

Add to the enum (after `.hidden`):
```swift
    case notBackedUp = "Not backed up"
    case compressed = "Compressed"
    case fullSize = "Full size"
```
In `matches`, add to the `switch self` (before the category cases):
```swift
        case .notBackedUp:
            return item.archivedHash == nil
        case .compressed:
            return item.archivedHash != nil && item.smallPath != nil && !item.protected
        case .fullSize:
            return item.protected
```
> These are inside the `guard !item.hidden else { return false }` region, so hidden items are excluded automatically.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LibraryScopeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/LibraryScope.swift Tests/PhlookCoreTests/LibraryScopeTests.swift
git commit -m "feat: sidebar scopes — Not backed up / Compressed / Full size"
```

---

### Task 4: `ArchiveService` honors protect; `IndexingService.claimFullSize`

**Files:**
- Modify: `Sources/PhlookCore/ArchiveService.swift` (skip shrink+reclaim for protected)
- Modify: `Sources/PhlookCore/IndexingService.swift` (`runArchive` work-set; `claimFullSize`)
- Test: `Tests/PhlookCoreTests/ClaimAndProtectTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2 (`setClaimed`, `itemsToShrink`, `SSDArchiveTarget`, `ArchiveService`).
- Produces:
  - `ArchiveService.run` — for an `item.protected == true` item: archive it (copy/verify/markArchived) if not already archived, then STOP (no shrink, no reclaim). Increments `report.archived` only.
  - `IndexingService.claimFullSize(_ item: MediaItem) throws -> Bool` — resolves the target (throws `ArchiveError.noSSD` if absent); computes the master URL (`item.ssdRelPath` if set, else `PHLOOK/<name>`); copies it to `item.path` (restoring the local original); calls `index.setClaimed(path:, ssdRelPath:)`; deletes the local 10% proxy if present. Returns true on success.

- [ ] **Step 1: Write the failing test**

```swift
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
        try Data("REALMASTER".utf8).write(to: ssd.appendingPathComponent("PHLOOK/\(name)"))
        try SSDArchiveTarget.setUp(volumeRoot: ssd, markerID: "m")
        try w.index.setMarkerID("m", label: "ssd")   // so resolveArchiveTarget can find it via mountedVolumeRoots? see note
        let proxyDir = w.svc.proxyRoot
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let proxy = proxyDir.appendingPathComponent("c.jpg"); try Data("small".utf8).write(to: proxy)
        var item = MediaItem(path: localPath, hash: "h", dateTaken: nil, fileType: "image",
                             width: nil, height: nil, lastScanned: Date(), smallPath: proxy.path)
        item.archivedHash = "hm"
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaimAndProtectTests`
Expected: FAIL — `value of type 'IndexingService' has no member 'claimFullSize'` and the protected path not yet handled.

- [ ] **Step 3a: Make `ArchiveService.run` honor protect**

In the per-file loop, immediately after the archive block completes and before the shrink stage, add:
```swift
            // Protected items are backed up but kept full-res: never shrunk or reclaimed.
            if item.protected { continue }
```
Place this AFTER `markArchived` (so a protected item still gets copied+verified to the SSD) and BEFORE `encoder.makeSmallVersion`. The `report.archived` increment stays; `shrunk`/`reclaimed` are skipped.

- [ ] **Step 3b: Add `claimFullSize` + widen the shrink work-set**

In `IndexingService.runArchive`, change the work-set source from `itemsPendingArchiveOrShrink()` so protected items are still ARCHIVED but not shrunk: keep passing the full pending set to `ArchiveService` (it now self-skips shrink for protected via 3a). No change needed to the query if `ArchiveService` self-skips — but ensure protected-but-unarchived items are still included so they get backed up. Leave `runArchive`'s existing `itemsPendingArchiveOrShrink()` + `fileExists` filter as-is (protected handling is inside `ArchiveService`).

Add:
```swift
    /// Restore an archived item's full-resolution master from the SSD to its
    /// local path and mark it protected (kept full-res, never re-shrunk).
    /// `resolvedTarget` is for tests; production passes nil and it resolves.
    @discardableResult
    public func claimFullSize(_ item: MediaItem, resolvedTarget: ArchiveTarget? = nil) throws -> Bool {
        guard let target = try (resolvedTarget ?? resolveArchiveTarget()) else { throw ArchiveError.noSSD }
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let master = item.ssdRelPath.map { target.volumeRoot.appendingPathComponent($0) }
            ?? target.phlookRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: master.path) else { return false }
        let dest = URL(fileURLWithPath: item.path)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: master, to: dest)
        let rel = item.ssdRelPath ?? "PHLOOK/\(name)"
        try index.setClaimed(path: item.path, ssdRelPath: rel)
        if let sp = item.smallPath { try? FileManager.default.removeItem(at: URL(fileURLWithPath: sp)) }
        return true
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaimAndProtectTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS (existing ArchiveServiceTests unaffected — none use `protected == true`).

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/ArchiveService.swift Sources/PhlookCore/IndexingService.swift Tests/PhlookCoreTests/ClaimAndProtectTests.swift
git commit -m "feat: protect (archive-not-shrink) + claimFullSize (restore master from SSD)"
```

---

### Task 5: SwiftUI — scopes in sidebar, badges, Claim/Protect actions

**Files:**
- Modify: `Sources/Phlook/SidebarView.swift` (add the three scopes to a "Storage" section)
- Modify: `Sources/Phlook/LibraryViewModel.swift` (claim/protect wrappers; scope counts)
- Modify: `Sources/Phlook/MicroGridView.swift` (badge + context-menu actions)
- Modify: `Sources/Phlook/ViewerView.swift` (a "Compressed (10%) · Claim full size" affordance)

**Interfaces:**
- Consumes: `LibraryScope.notBackedUp/.compressed/.fullSize`, `MediaIndex.curationCounts()`, `IndexingService.claimFullSize`, `MediaIndex.setProtected`.
- Produces: user-visible scopes, a "10%" badge on compressed items, right-click **Protect / Unprotect** and **Claim full size** (disabled when SSD absent), and the same claim affordance in the viewer.

> UI is wired, not unit-tested; the decision logic (scopes, counts, claim/protect) is covered by Tasks 1–4. Verify by building and a manual smoke run.

- [ ] **Step 1: Add view-model wrappers**

In `LibraryViewModel` (adapt to the file's `@MainActor`/`Task.detached` conventions — mirror `revealOriginalOnSSD`/`startArchive`):
```swift
    @Published var curationCounts: MediaIndex.CurationCounts?

    func refreshCurationCounts() { curationCounts = try? service.mediaIndex.curationCounts() }

    func setProtected(_ items: [MediaItem], _ protectedFlag: Bool) {
        try? service.mediaIndex.setProtected(paths: items.map(\.path), protected: protectedFlag)
        reload()   // use the VM's existing reload/rescan entry point
    }

    func claimFullSize(_ item: MediaItem) {
        Task.detached { [weak self] in
            guard let self else { return }
            _ = try? await MainActor.run { self.service }.claimFullSize(item)
            await MainActor.run { self.reload() }
        }
    }

    /// True when this item's local copy is the 10% version (compressed).
    func isCompressed(_ item: MediaItem) -> Bool {
        item.archivedHash != nil && item.smallPath != nil && !item.protected
    }
```
> Replace `reload()` with whatever method the VM already uses to re-fetch items after a mutation (e.g. the same one `setHidden`/`confirmTrash` calls). If `runArchive`/`claimFullSize` isn't `async`, drop the `MainActor.run` wrapper and call directly inside `Task`.

- [ ] **Step 2: Add the scopes to the sidebar**

In `SidebarView.swift`, add a "Storage" section (mirroring the existing Kinds section) listing `.notBackedUp`, `.compressed`, `.fullSize`, each with an SF Symbol (`externaldrive.badge.xmark`, `arrow.down.right.and.arrow.up.left`, `lock.doc`) and its count from `vm.curationCounts` (`notBackedUp`/`compressed`/`fullSize`). Call `vm.refreshCurationCounts()` where the sidebar refreshes other counts.

- [ ] **Step 3: Add the badge + context menu in the grid**

In `MicroGridView.swift`'s `ThumbCell`, add a small **"10%"** capsule badge (top-right, near the LIVE badge) shown when `vm.isCompressed(item)`; add a **"Full"** badge when `item.protected`. In the cell `.contextMenu`, add:
```swift
                if item.protected {
                    Button("Unprotect") { vm.setProtected([item], false) }
                } else {
                    Button("Protect (keep full size)") { vm.setProtected([item], true) }
                }
                if vm.isCompressed(item) {
                    Button("Claim full size") { vm.claimFullSize(item) }
                        .disabled((try? vm.service.resolveArchiveTarget()) == nil)
                }
```

- [ ] **Step 4: Add the viewer affordance**

In `ViewerView.swift`, when `vm.isCompressed(currentItem)`, show a small label **"Compressed (10%)"** with a button **"Claim full size"** (or **"Connect PHLOOK_SSD to restore"** when `(try? vm.service.resolveArchiveTarget()) == nil`, disabled) that calls `vm.claimFullSize(currentItem)`. Match the top-bar control styling.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: clean (fix any property-name mismatches against the real `LibraryViewModel`/`SidebarView`).

- [ ] **Step 6: Manual smoke**

1. With an archived+reclaimed library, the sidebar shows Not backed up / Compressed / Full size with counts; clicking each filters.
2. A reclaimed item shows a "10%" badge; right-click → Claim full size (SSD connected) restores the original, badge changes to "Full", item moves to the Full size scope.
3. Right-click → Protect on a not-yet-shrunk item; a subsequent Archive & shrink backs it up but leaves it full-res (never appears in Compressed).

- [ ] **Step 7: Commit**

```bash
git add Sources/Phlook/SidebarView.swift Sources/Phlook/LibraryViewModel.swift Sources/Phlook/MicroGridView.swift Sources/Phlook/ViewerView.swift
git commit -m "feat: storage sidebar scopes, 10%/Full badges, Claim/Protect actions"
```

---

## Self-Review

**Spec coverage (this slice = spec items 1–4):**
- v9 columns `curated`/`protected`/`ssd_rel_path` → Task 1. ✓ (`db_version`/`synced_at` intentionally deferred to slice 2.)
- Visibility scopes Not backed up / Compressed / Full size → Tasks 2 (counts) + 3 (predicates) + 5 (UI). ✓
- Claim full size (copy master → local, protect, drop proxy) → Tasks 2 (`setClaimed`) + 4 (`claimFullSize`) + 5 (UI). ✓
- Protect honored by shrink (archive-not-shrink) → Tasks 2 (`itemsToShrink`) + 4 (ArchiveService skip) + 5 (UI). ✓
- Deferred (curation-delete, Not-curated view, versioned sync, disaster recovery) → explicitly out of scope, slice 2. ✓

**Placeholder scan:** No TBD/TODO; every code step has real code. Task 5 flags name-adaptation points explicitly rather than leaving blanks. ✓

**Type consistency:** `curated`/`protected`/`ssdRelPath`, `setClaimed(path:ssdRelPath:)`, `setProtected(paths:protected:)`, `itemsToShrink()`, `curationCounts()`/`CurationCounts`, `claimFullSize(_:resolvedTarget:)`, scopes `.notBackedUp/.compressed/.fullSize` used identically across tasks. ✓

**Note for the executor:** Task 4 adds a `resolvedTarget` test seam to `claimFullSize`; confirm `ArchiveService.run`'s existing protected-skip placement is after `markArchived` and before shrink. Task 5's exact VM method names (`reload`, `service`) must be matched to the real `LibraryViewModel`.
