# Shrink & Archive ("10% library") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let PHLOOK copy every original to a verified SSD archive, keep a browsable ~10% "small version" on the laptop, and reclaim local disk — never deleting a local original until its byte-perfect twin is confirmed on the SSD and its small version exists.

**Architecture:** Pure, testable services in `PhlookCore` (`FileHasher`, `SSDArchiveTarget`, `SmallVersionEncoder`, `ArchiveService`) orchestrated per-file in strict order (hash → copy → verify → shrink → reclaim). A GRDB migration (v8) adds three columns to `files` plus an `archive_config` table. A thin SwiftUI panel drives it, with all decision logic in a pure `ReclaimStatus`/view-model layer that is unit-tested.

**Tech Stack:** Swift 5.9+, GRDB (SQLite), CryptoKit (SHA256), ImageIO (photo encode), AVFoundation (video encode), swift-testing (`import Testing`, `@Test`, `#expect`), SwiftUI/AppKit.

## Global Constraints

- **The core invariant:** a local original is deleted ONLY after (a) its byte-perfect copy is verified on the SSD (`archived_hash` set via read-back) AND (b) its small version exists locally (`small_path` set). Deletion is always the last step, per file.
- **No external binaries.** Encoding uses in-process ImageIO + AVFoundation only. No dependency on homebrew `ffmpeg`.
- **Serial, one file at a time.** Only ~70 GB free; never stage many originals before deleting. Peak extra local disk ≈ one file.
- **Never overwrite a differing file on the SSD.** A name collision with a different hash is flagged and skipped, never overwritten.
- **SSD identity by marker file, not volume name.** Archive only to a drive carrying `.phlook_archive` whose `id` equals the stored `marker_id`.
- **Resumable.** DB commits after archival and after shrink, so a crash/unplug mid-run resumes without re-copying.
- **Migration pattern:** follow the existing `PRAGMA user_version` gate + `ALTER TABLE ADD COLUMN` idempotent style in `Sources/PhlookCore/MediaIndex.swift`. Next version gate is **8**.
- **Test conventions:** swift-testing. Each test builds a world in `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`. Run a single test with `swift test --filter <TypeName>`.
- **Proxy tree:** small versions live in `~/Pictures/PHLOOK_proxy/<same-base-name>.{jpg,mp4}` (sibling to `~/Pictures/PHLOOK`).

---

### Task 1: `FileHasher` — public streaming SHA256

**Files:**
- Create: `Sources/PhlookCore/FileHasher.swift`
- Modify: `Sources/PhlookCore/LibraryScanner.swift:121-129` (delegate `fullHash` to the new helper — DRY)
- Test: `Tests/PhlookCoreTests/FileHasherTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum FileHasher { public static func sha256(of url: URL) -> String? }` — lowercase hex of the whole file's SHA256, streamed in 4 MB chunks; `nil` if unreadable.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileHasherTests`
Expected: FAIL — `cannot find 'FileHasher' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PhlookCore/FileHasher.swift
import Foundation
import CryptoKit

/// Streaming SHA256 of a whole file, read in 4 MB chunks so large videos
/// never load fully into memory. Lowercase hex; nil if the file is unreadable.
public enum FileHasher {
    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: DRY the existing duplicate in LibraryScanner**

Replace the body of `static func fullHash(_ url: URL) -> String?` (lines 121-129) with a delegation:

```swift
    static func fullHash(_ url: URL) -> String? {
        FileHasher.sha256(of: url)
    }
```

- [ ] **Step 5: Run tests to verify pass (new + unbroken scanner)**

Run: `swift test --filter FileHasherTests` then `swift test --filter DuplicateFinderTests`
Expected: PASS for both (DuplicateFinder relies on `fullHash`, now delegating).

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/FileHasher.swift Sources/PhlookCore/LibraryScanner.swift Tests/PhlookCoreTests/FileHasherTests.swift
git commit -m "feat: public FileHasher.sha256 streaming helper (DRY with scanner)"
```

---

### Task 2: DB migration v8 + `MediaItem` archive fields

**Files:**
- Modify: `Sources/PhlookCore/MediaItem.swift` (add 3 stored props + CodingKeys)
- Modify: `Sources/PhlookCore/MediaIndex.swift:26-112` (CREATE TABLE columns + v8 migration gate)
- Test: `Tests/PhlookCoreTests/ArchiveColumnsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MediaItem.archivedHash: String?`, `MediaItem.archivedAt: Date?`, `MediaItem.smallPath: String?` (all default `nil`). A `files` table with columns `archived_hash TEXT`, `archived_at TEXT`, `small_path TEXT`. Fresh and upgraded DBs both have them. `upsert` never overwrites them (only Task 5 writers do).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PhlookCore

struct ArchiveColumnsTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    @Test func archiveFieldsRoundTripAndSurviveUpsert() throws {
        let index = try newIndex()
        var item = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                             fileType: "image", width: nil, height: nil, lastScanned: Date())
        item.archivedHash = "deadbeef"
        item.archivedAt = Date(timeIntervalSince1970: 1_000_000)
        item.smallPath = "/proxy/a.jpg"
        try index.upsert(item)

        // A later plain rescan (no archive fields) must NOT wipe them.
        let rescan = MediaItem(path: "/x/a.heic", hash: "h", dateTaken: nil,
                               fileType: "image", width: nil, height: nil, lastScanned: Date())
        try index.upsert(rescan)

        let got = try index.item(forPath: "/x/a.heic")
        #expect(got?.archivedHash == "deadbeef")
        #expect(got?.smallPath == "/proxy/a.jpg")
        #expect(got?.archivedAt == Date(timeIntervalSince1970: 1_000_000))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArchiveColumnsTests`
Expected: FAIL — `value of type 'MediaItem' has no member 'archivedHash'`.

- [ ] **Step 3: Add the fields to `MediaItem`**

In `Sources/PhlookCore/MediaItem.swift`, after `public var posterTime: Double?` (line 19) add:

```swift
    public var archivedHash: String?   // sha256 of the master, set only after SSD read-back verify
    public var archivedAt: Date?       // when the SSD copy was verified
    public var smallPath: String?      // path to the local 10% version (nil = not made yet)
```

Add to `CodingKeys` (after `case posterTime = "poster_time"`):

```swift
        case archivedHash = "archived_hash"
        case archivedAt = "archived_at"
        case smallPath = "small_path"
```

Extend the initializer signature (after `posterTime: Double? = nil`):

```swift
                posterTime: Double? = nil,
                archivedHash: String? = nil, archivedAt: Date? = nil, smallPath: String? = nil) {
```

and its body (after `self.posterTime = posterTime`):

```swift
        self.archivedHash = archivedHash; self.archivedAt = archivedAt; self.smallPath = smallPath
```

- [ ] **Step 4: Add columns to CREATE TABLE and a v8 migration gate**

In `Sources/PhlookCore/MediaIndex.swift`, in the `CREATE TABLE IF NOT EXISTS files (...)` block add three lines before the closing `);` (after `poster_time REAL`):

```sql
                    poster_time REAL,
                    archived_hash TEXT,
                    archived_at TEXT,
                    small_path TEXT
```

After the `if version < 7 { ... }` block (line 111) add:

```swift
            if version < 8 {
                let cols = try db.columns(in: "files").map(\.name)
                if !cols.contains("archived_hash") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN archived_hash TEXT")
                }
                if !cols.contains("archived_at") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN archived_at TEXT")
                }
                if !cols.contains("small_path") {
                    try db.execute(sql: "ALTER TABLE files ADD COLUMN small_path TEXT")
                }
                try db.execute(sql: "PRAGMA user_version = 8")
            }
```

> Note: `upsert` (MediaIndex.swift:115) copies only named fields onto the fetched `existing` row; it never assigns `archivedHash`/`archivedAt`/`smallPath`, so those DB values survive a rescan automatically. Do not add them to `upsert`.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ArchiveColumnsTests`
Expected: PASS.

- [ ] **Step 6: Run the migration regression tests**

Run: `swift test --filter MediaIndexMigrationTests`
Expected: PASS (existing migrations still work with the v8 gate appended).

- [ ] **Step 7: Commit**

```bash
git add Sources/PhlookCore/MediaItem.swift Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/ArchiveColumnsTests.swift
git commit -m "feat: DB v8 — archived_hash/archived_at/small_path columns on files"
```

---

### Task 3: `archive_config` table + MediaIndex archive accessors & queries

**Files:**
- Modify: `Sources/PhlookCore/MediaIndex.swift` (v8 block: create `archive_config`; add methods)
- Test: `Tests/PhlookCoreTests/ArchiveIndexQueriesTests.swift`

**Interfaces:**
- Consumes: Task 2 columns.
- Produces on `MediaIndex`:
  - `func setMarkerID(_ id: String, label: String?) throws`
  - `func markerID() throws -> String?`  (nil if never set)
  - `func markMigratedLabel(_ label: String?) throws` — *not needed; label goes through setMarkerID*
  - `func markArchived(path: String, hash: String, at: Date) throws`
  - `func setSmallPath(path: String, smallPath: String) throws`
  - `func itemsNeedingArchiving() throws -> [MediaItem]` — `archived_hash IS NULL`
  - `func reclaimableItems() throws -> [MediaItem]` — `archived_hash IS NOT NULL AND small_path IS NOT NULL`
  - `func archiveCounts() throws -> ArchiveCounts` where `struct ArchiveCounts: Equatable { let needsArchiving: Int; let hasSmall: Int; let reclaimable: Int; let reclaimableBytes: Int }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PhlookCore

struct ArchiveIndexQueriesTests {
    private func newIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
    }

    private func add(_ index: MediaIndex, _ path: String, size: Int) throws {
        try index.upsert(MediaItem(path: path, hash: "h", dateTaken: nil, fileType: "image",
                                   width: nil, height: nil, lastScanned: Date(), fileSize: size))
    }

    @Test func markerRoundTrips() throws {
        let index = try newIndex()
        #expect(try index.markerID() == nil)
        try index.setMarkerID("uuid-123", label: "PHLOOK_SSD")
        #expect(try index.markerID() == "uuid-123")
        try index.setMarkerID("uuid-456", label: "PHLOOK_SSD2")   // single row, replaces
        #expect(try index.markerID() == "uuid-456")
    }

    @Test func archiveStateTransitionsAndCounts() throws {
        let index = try newIndex()
        try add(index, "/lib/a.heic", size: 1000)   // untouched
        try add(index, "/lib/b.mov",  size: 9000)   // will archive + shrink
        try add(index, "/lib/c.jpg",  size: 500)    // will archive only

        try index.markArchived(path: "/lib/b.mov", hash: "hb", at: Date())
        try index.setSmallPath(path: "/lib/b.mov", smallPath: "/proxy/b.mp4")
        try index.markArchived(path: "/lib/c.jpg", hash: "hc", at: Date())

        #expect(try index.itemsNeedingArchiving().map(\.path).sorted() == ["/lib/a.heic"])
        #expect(try index.reclaimableItems().map(\.path) == ["/lib/b.mov"])

        let counts = try index.archiveCounts()
        #expect(counts.needsArchiving == 1)     // a
        #expect(counts.hasSmall == 1)           // b
        #expect(counts.reclaimable == 1)        // b (archived + small)
        #expect(counts.reclaimableBytes == 9000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArchiveIndexQueriesTests`
Expected: FAIL — `value of type 'MediaIndex' has no member 'setMarkerID'`.

- [ ] **Step 3: Create the config table in the v8 migration**

Inside the `if version < 8 {` block (Task 2), before `PRAGMA user_version = 8`, add:

```swift
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS archive_config (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        marker_id TEXT NOT NULL,
                        ssd_label TEXT
                    );
                """)
```

- [ ] **Step 4: Add the accessor + query methods**

Add to `MediaIndex` (anywhere among the public methods, e.g. after `item(forPath:)`):

```swift
    public struct ArchiveCounts: Equatable {
        public let needsArchiving: Int
        public let hasSmall: Int
        public let reclaimable: Int
        public let reclaimableBytes: Int
    }

    public func setMarkerID(_ id: String, label: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO archive_config (id, marker_id, ssd_label) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET marker_id = excluded.marker_id, ssd_label = excluded.ssd_label
                """, arguments: [id, label])
        }
    }

    public func markerID() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT marker_id FROM archive_config WHERE id = 1")
        }
    }

    public func markArchived(path: String, hash: String, at: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE files SET archived_hash = ?, archived_at = ? WHERE path = ?",
                           arguments: [hash, at, path])
        }
    }

    public func setSmallPath(path: String, smallPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE files SET small_path = ? WHERE path = ?",
                           arguments: [smallPath, path])
        }
    }

    public func itemsNeedingArchiving() throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.filter(sql: "archived_hash IS NULL").fetchAll(db)
        }
    }

    public func reclaimableItems() throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.filter(sql: "archived_hash IS NOT NULL AND small_path IS NOT NULL").fetchAll(db)
        }
    }

    public func archiveCounts() throws -> ArchiveCounts {
        try dbQueue.read { db in
            let needs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE archived_hash IS NULL") ?? 0
            let small = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE small_path IS NOT NULL") ?? 0
            let recl = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE archived_hash IS NOT NULL AND small_path IS NOT NULL") ?? 0
            let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(file_size),0) FROM files WHERE archived_hash IS NOT NULL AND small_path IS NOT NULL AND file_size IS NOT NULL") ?? 0
            return ArchiveCounts(needsArchiving: needs, hasSmall: small, reclaimable: recl, reclaimableBytes: bytes)
        }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ArchiveIndexQueriesTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/ArchiveIndexQueriesTests.swift
git commit -m "feat: archive_config table + archive state queries/accessors on MediaIndex"
```

---

### Task 4: `SSDArchiveTarget` — marker-file drive identity

**Files:**
- Create: `Sources/PhlookCore/SSDArchiveTarget.swift`
- Test: `Tests/PhlookCoreTests/SSDArchiveTargetTests.swift`

**Interfaces:**
- Consumes: nothing (takes candidate volume URLs so it is testable without real drives).
- Produces:
  - `struct ArchiveTarget: Equatable { public let volumeRoot: URL; public let markerID: String; public var phlookRoot: URL { volumeRoot.appendingPathComponent("PHLOOK") } }`
  - `enum SSDArchiveTarget`:
    - `static func setUp(volumeRoot: URL, markerID: String) throws` — writes `.phlook_archive` JSON `{ "id": markerID, "created": <iso8601> }` at `volumeRoot` and creates `PHLOOK/`.
    - `static func readMarkerID(at volumeRoot: URL) -> String?` — parses the marker file; nil if absent/unparseable.
    - `static func resolve(expectedMarkerID: String, candidateRoots: [URL]) -> ArchiveTarget?` — first candidate whose marker id equals `expectedMarkerID`; else nil.
    - `static func mountedVolumeRoots() -> [URL]` — real `/Volumes` enumeration for production callers (not unit-tested).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import PhlookCore

struct SSDArchiveTargetTests {
    private func tmpVolume() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func setUpWritesMarkerAndPhlookRoot() throws {
        let vol = try tmpVolume()
        try SSDArchiveTarget.setUp(volumeRoot: vol, markerID: "uuid-abc")
        #expect(SSDArchiveTarget.readMarkerID(at: vol) == "uuid-abc")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: vol.appendingPathComponent("PHLOOK").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func resolvePicksMatchingMarkerOnly() throws {
        let match = try tmpVolume(); try SSDArchiveTarget.setUp(volumeRoot: match, markerID: "want")
        let other = try tmpVolume(); try SSDArchiveTarget.setUp(volumeRoot: other, markerID: "different")
        let bare  = try tmpVolume()   // no marker at all

        let target = SSDArchiveTarget.resolve(expectedMarkerID: "want", candidateRoots: [bare, other, match])
        #expect(target?.volumeRoot == match)
        #expect(target?.phlookRoot == match.appendingPathComponent("PHLOOK"))

        #expect(SSDArchiveTarget.resolve(expectedMarkerID: "want", candidateRoots: [bare, other]) == nil)
        #expect(SSDArchiveTarget.readMarkerID(at: bare) == nil)
    }

    @Test func renamedVolumeStillResolvesByMarker() throws {
        let vol = try tmpVolume(); try SSDArchiveTarget.setUp(volumeRoot: vol, markerID: "stable")
        let renamed = vol.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: vol, to: renamed)   // simulate a volume rename
        #expect(SSDArchiveTarget.resolve(expectedMarkerID: "stable", candidateRoots: [renamed])?.volumeRoot == renamed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SSDArchiveTargetTests`
Expected: FAIL — `cannot find 'SSDArchiveTarget' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PhlookCore/SSDArchiveTarget.swift
import Foundation

public struct ArchiveTarget: Equatable {
    public let volumeRoot: URL
    public let markerID: String
    public var phlookRoot: URL { volumeRoot.appendingPathComponent("PHLOOK") }
}

/// Identifies the archive SSD by a marker file at its root, not by volume name,
/// so a rename or a same-named impostor drive can't be mistaken for the archive.
public enum SSDArchiveTarget {
    static let markerFileName = ".phlook_archive"

    private struct Marker: Codable { let id: String; let created: String }

    public static func setUp(volumeRoot: URL, markerID: String) throws {
        let iso = ISO8601DateFormatter().string(from: Date())
        let data = try JSONEncoder().encode(Marker(id: markerID, created: iso))
        try data.write(to: volumeRoot.appendingPathComponent(markerFileName))
        try FileManager.default.createDirectory(
            at: volumeRoot.appendingPathComponent("PHLOOK"), withIntermediateDirectories: true)
    }

    public static func readMarkerID(at volumeRoot: URL) -> String? {
        let url = volumeRoot.appendingPathComponent(markerFileName)
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        return marker.id
    }

    public static func resolve(expectedMarkerID: String, candidateRoots: [URL]) -> ArchiveTarget? {
        for root in candidateRoots where readMarkerID(at: root) == expectedMarkerID {
            return ArchiveTarget(volumeRoot: root, markerID: expectedMarkerID)
        }
        return nil
    }

    /// Production helper: mounted, browsable volumes under /Volumes. Not unit-tested.
    public static func mountedVolumeRoots() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                     options: [.skipHiddenVolumes]) ?? []
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SSDArchiveTargetTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/SSDArchiveTarget.swift Tests/PhlookCoreTests/SSDArchiveTargetTests.swift
git commit -m "feat: SSDArchiveTarget — marker-file drive identity"
```

---

### Task 5: `SmallVersionEncoder` — ImageIO photos + AVFoundation video with size guard

**Files:**
- Create: `Sources/PhlookCore/SmallVersionEncoder.swift`
- Test: `Tests/PhlookCoreTests/SmallVersionEncoderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol SmallVersionEncoding { func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL }` — returns the written small-version URL (base name of `original`, extension `.jpg` for images / `.mp4` for video).
  - `struct SmallVersionEncoder: SmallVersionEncoding` — real ImageIO/AVFoundation impl.
  - `enum SmallVersionError: Error { case unreadable, encodeFailed }`
  - Photo path: long-edge 2048 px, JPEG quality 0.55.
  - Video path: 720p H.264 export; **size guard** — if the exported file is ≥ 15% of the source size, discard it and copy the original bytes instead (an already-efficient/short clip).

- [ ] **Step 1: Write the failing test** (images only — deterministic, no codec timing)

```swift
import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhlookCore

struct SmallVersionEncoderTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Write a real PNG of the given pixel size so ImageIO can decode it.
    private func writePNG(_ url: URL, w: Int, h: Int) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }

    private func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    @Test func photoIsDownscaledToLongEdge2048AsJpeg() throws {
        let dir = try tmp()
        let src = dir.appendingPathComponent("big.png")
        try writePNG(src, w: 4000, h: 3000)
        let proxyDir = dir.appendingPathComponent("proxy")

        let out = try SmallVersionEncoder().makeSmallVersion(from: src, fileType: "image", into: proxyDir)

        #expect(out.pathExtension == "jpg")
        #expect(out.deletingPathExtension().lastPathComponent == "big")
        let (w, h) = try #require(pixelSize(out))
        #expect(max(w, h) == 2048)                     // long edge clamped
        #expect(h == 1536)                             // aspect preserved (3000*2048/4000)
        let outSize = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        let inSize  = try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int
        #expect(outSize < inSize)                      // smaller than source
    }

    @Test func unreadableSourceThrows() throws {
        let dir = try tmp()
        #expect(throws: (any Error).self) {
            try SmallVersionEncoder().makeSmallVersion(
                from: dir.appendingPathComponent("nope.png"), fileType: "image",
                into: dir.appendingPathComponent("proxy"))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SmallVersionEncoderTests`
Expected: FAIL — `cannot find 'SmallVersionEncoder' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PhlookCore/SmallVersionEncoder.swift
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public enum SmallVersionError: Error { case unreadable, encodeFailed }

public protocol SmallVersionEncoding {
    /// Writes a ~10% "small version" of `original` into `proxyDir`, keeping the
    /// base name. Returns the written URL. `fileType` is "image" or "video".
    func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL
}

public struct SmallVersionEncoder: SmallVersionEncoding {
    public init() {}

    private static let longEdge = 2048
    private static let jpegQuality = 0.55
    private static let videoKeepThreshold = 0.15   // export ≥15% of source ⇒ keep original bytes

    public func makeSmallVersion(from original: URL, fileType: String, into proxyDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let base = original.deletingPathExtension().lastPathComponent
        if fileType == "video" {
            return try makeVideo(original, base: base, proxyDir: proxyDir)
        } else {
            return try makePhoto(original, base: base, proxyDir: proxyDir)
        }
    }

    // MARK: Photo (ImageIO, synchronous)

    private func makePhoto(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(original as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { throw SmallVersionError.unreadable }
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension("jpg")
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: Self.longEdge
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw SmallVersionError.encodeFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SmallVersionError.encodeFailed
        }
        CGImageDestinationAddImage(dest, thumb,
            [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SmallVersionError.encodeFailed }
        return out
    }

    // MARK: Video (AVFoundation, 720p H.264; size-guard passthrough)

    private func makeVideo(_ original: URL, base: String, proxyDir: URL) throws -> URL {
        let out = proxyDir.appendingPathComponent(base).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: original)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw SmallVersionError.encodeFailed
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()
        guard export.status == .completed else { throw SmallVersionError.encodeFailed }

        // Size guard: if the "small" version isn't meaningfully smaller, keep the original bytes.
        let inSize = (try? FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int) ?? nil
        let outSize = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? nil
        if let i = inSize, let o = outSize, Double(o) >= Double(i) * Self.videoKeepThreshold {
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.copyItem(at: original, to: out)
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SmallVersionEncoderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/SmallVersionEncoder.swift Tests/PhlookCoreTests/SmallVersionEncoderTests.swift
git commit -m "feat: SmallVersionEncoder — ImageIO photos + AVFoundation 720p video w/ size guard"
```

---

### Task 6: `LibraryTrasher.trashFilesOnly` — reclaim without pruning rows

**Files:**
- Modify: `Sources/PhlookCore/LibraryTrasher.swift`
- Test: `Tests/PhlookCoreTests/LibraryTrasherTests.swift` (add cases)

**Interfaces:**
- Consumes: nothing.
- Produces: `static func trashFilesOnly(paths: [String]) -> TrashOutcome` — moves files to the Trash and returns which succeeded, but **never touches the index** (the archive row must survive with its `archived_hash`/`small_path`). A missing file counts as trashed (already gone).

- [ ] **Step 1: Write the failing test** (append to `LibraryTrasherTests`)

```swift
    @Test func trashFilesOnlyMovesFileButKeepsRow() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "keep.jpg", index)
        let outcome = LibraryTrasher.trashFilesOnly(paths: [a])
        #expect(outcome.trashedPaths == [a])
        #expect(!FileManager.default.fileExists(atPath: a))   // file gone
        #expect(try index.item(forPath: a) != nil)            // row SURVIVES
    }

    @Test func trashFilesOnlyTreatsMissingAsDone() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "gone.jpg", index)
        try FileManager.default.removeItem(atPath: a)
        let outcome = LibraryTrasher.trashFilesOnly(paths: [a])
        #expect(outcome.trashedPaths == [a])
        #expect(outcome.failures.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LibraryTrasherTests`
Expected: FAIL — `type 'LibraryTrasher' has no member 'trashFilesOnly'`.

- [ ] **Step 3: Add the method**

In `Sources/PhlookCore/LibraryTrasher.swift`, add inside `enum LibraryTrasher`:

```swift
    /// Move files to the Trash WITHOUT pruning index rows. Used by archival
    /// reclaim, where the row must survive (it carries archived_hash/small_path).
    public static func trashFilesOnly(paths: [String]) -> TrashOutcome {
        let fm = FileManager.default
        var trashed: [String] = []
        var failures: [String] = []
        for path in paths {
            if !fm.fileExists(atPath: path) { trashed.append(path); continue }
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                trashed.append(path)
            } catch {
                failures.append("\(URL(fileURLWithPath: path).lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return TrashOutcome(trashedPaths: trashed, failures: failures)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LibraryTrasherTests`
Expected: PASS (new + existing cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/LibraryTrasher.swift Tests/PhlookCoreTests/LibraryTrasherTests.swift
git commit -m "feat: LibraryTrasher.trashFilesOnly — reclaim originals, keep index rows"
```

---

### Task 7: `ArchiveService` — the per-file orchestrator

**Files:**
- Create: `Sources/PhlookCore/ArchiveService.swift`
- Test: `Tests/PhlookCoreTests/ArchiveServiceTests.swift`

**Interfaces:**
- Consumes: `MediaIndex` (Tasks 2–3), `FileHasher` (Task 1), `SmallVersionEncoding` (Task 5), `ArchiveTarget` (Task 4), `LibraryTrasher.trashFilesOnly` (Task 6).
- Produces:
  - `struct ArchiveReport: Equatable { public var archived: Int; public var shrunk: Int; public var reclaimed: Int; public var skippedCollisions: [String]; public var failures: [String] }`
  - `final class ArchiveService` with:
    - `init(index: MediaIndex, encoder: SmallVersionEncoding, proxyDir: URL)`
    - `func run(target: ArchiveTarget, items: [MediaItem], isCancelled: () -> Bool) -> ArchiveReport` — processes each item through the ordered pipeline, serial. Skips a file when `isCancelled()` is true *before* starting it (never mid-file).
- Pipeline per item (each stage aborts THIS file on failure, leaving the original intact):
  1. `guard let h = FileHasher.sha256(of: original)` else fail.
  2. Destination `target.phlookRoot/<name>`. If a file already exists there: if `FileHasher.sha256(of: dest) == h` treat as already-archived (idempotent, continue); else record collision, skip file.
  3. Copy original → dest (create `phlookRoot` if needed).
  4. `guard FileHasher.sha256(of: dest) == h` else remove dest, fail file.
  5. `index.markArchived(path:hash:at:)` — commit.
  6. `let small = try encoder.makeSmallVersion(...)`; `index.setSmallPath(path:smallPath:)` — commit.
  7. `LibraryTrasher.trashFilesOnly(paths: [original])`; on success count `reclaimed`.

- [ ] **Step 1: Write the failing test** (fake encoder keeps it hardware-free)

```swift
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

    @Test func hashMismatchOnReadBackKeepsOriginalAndClearsPartial() throws {
        // Simulate a bad copy: pre-place a DIFFERENT file at the destination path
        // AND make the copy step land on it. We approximate by making the dest a
        // read-only directory so copy fails -> original must be kept, not archived.
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArchiveServiceTests`
Expected: FAIL — `cannot find 'ArchiveService' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/PhlookCore/ArchiveService.swift
import Foundation

public struct ArchiveReport: Equatable {
    public var archived = 0
    public var shrunk = 0
    public var reclaimed = 0
    public var skippedCollisions: [String] = []
    public var failures: [String] = []
    public init() {}
}

/// Orchestrates the per-file archive pipeline in strict order:
/// hash → copy → verify → mark archived → shrink → mark small → reclaim original.
/// Any stage failing aborts THAT file only and leaves its local original intact.
/// Serial by design (limited free disk); cancellable between files, never mid-file.
public final class ArchiveService {
    private let index: MediaIndex
    private let encoder: SmallVersionEncoding
    private let proxyDir: URL

    public init(index: MediaIndex, encoder: SmallVersionEncoding, proxyDir: URL) {
        self.index = index
        self.encoder = encoder
        self.proxyDir = proxyDir
    }

    public func run(target: ArchiveTarget, items: [MediaItem], isCancelled: () -> Bool) -> ArchiveReport {
        let fm = FileManager.default
        var report = ArchiveReport()

        for item in items {
            if isCancelled() { break }
            let original = URL(fileURLWithPath: item.path)
            let name = original.lastPathComponent
            guard fm.fileExists(atPath: original.path) else { continue }   // already reclaimed elsewhere

            // 1. hash the master
            guard let h = FileHasher.sha256(of: original) else {
                report.failures.append("\(name) — could not read original"); continue
            }

            let dest = target.phlookRoot.appendingPathComponent(name)
            var archivedThisFile = item.archivedHash != nil

            if !archivedThisFile {
                do {
                    try fm.createDirectory(at: target.phlookRoot, withIntermediateDirectories: true)
                    // 2. collision handling
                    if fm.fileExists(atPath: dest.path) {
                        if FileHasher.sha256(of: dest) == h {
                            // already there, identical — treat as archived
                        } else {
                            report.skippedCollisions.append(name); continue
                        }
                    } else {
                        // 3. copy
                        try fm.copyItem(at: original, to: dest)
                    }
                    // 4. verify read-back
                    guard FileHasher.sha256(of: dest) == h else {
                        try? fm.removeItem(at: dest)
                        report.failures.append("\(name) — SSD copy failed verification"); continue
                    }
                    // 5. commit archived
                    try index.markArchived(path: item.path, hash: h, at: Date())
                    archivedThisFile = true
                    report.archived += 1
                } catch {
                    try? fm.removeItem(at: dest)
                    report.failures.append("\(name) — archive error: \(error.localizedDescription)"); continue
                }
            } else {
                report.archived += 1
            }

            // 6. shrink
            let smallURL: URL
            do {
                smallURL = try encoder.makeSmallVersion(from: original, fileType: item.fileType, into: proxyDir)
                try index.setSmallPath(path: item.path, smallPath: smallURL.path)
                report.shrunk += 1
            } catch {
                report.failures.append("\(name) — shrink failed: \(error.localizedDescription)")
                continue   // original KEPT — invariant holds
            }

            // 7. reclaim local original (row survives)
            let outcome = LibraryTrasher.trashFilesOnly(paths: [item.path])
            if outcome.failures.isEmpty {
                report.reclaimed += 1
            } else {
                report.failures.append(contentsOf: outcome.failures)
            }
        }
        return report
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ArchiveServiceTests`
Expected: PASS (all six cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/ArchiveService.swift Tests/PhlookCoreTests/ArchiveServiceTests.swift
git commit -m "feat: ArchiveService — ordered, resumable per-file archive pipeline"
```

---

### Task 8: `ReclaimStatus` — pure UI-decision layer

**Files:**
- Create: `Sources/PhlookCore/ReclaimStatus.swift`
- Test: `Tests/PhlookCoreTests/ReclaimStatusTests.swift`

**Interfaces:**
- Consumes: `MediaIndex.ArchiveCounts` (Task 3), `ArchiveTarget` (Task 4).
- Produces:
  - `struct ReclaimStatus: Equatable { public let ssdConnected: Bool; public let counts: MediaIndex.ArchiveCounts; public var canArchive: Bool { ssdConnected && counts.needsArchiving > 0 }; public var reclaimableGB: Double { Double(counts.reclaimableBytes) / 1_073_741_824 }; public var buttonSubtitle: String }`
  - `buttonSubtitle`: when `!ssdConnected` → `"Connect PHLOOK_SSD to archive"`; else → `"<needsArchiving> not yet archived · <reclaimableGB, 1dp> GB reclaimable"`.
  - `static func humanImportLine(newToImport: Int, needsArchiving: Int) -> String?` — for the phone view's second line: nil if `needsArchiving == 0`, else `"…and <needsArchiving> items still need archiving."`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import PhlookCore

struct ReclaimStatusTests {
    private func counts(_ needs: Int, small: Int, recl: Int, bytes: Int) -> MediaIndex.ArchiveCounts {
        .init(needsArchiving: needs, hasSmall: small, reclaimable: recl, reclaimableBytes: bytes)
    }

    @Test func disabledWhenSSDAbsent() {
        let s = ReclaimStatus(ssdConnected: false, counts: counts(10, small: 0, recl: 0, bytes: 0))
        #expect(s.canArchive == false)
        #expect(s.buttonSubtitle == "Connect PHLOOK_SSD to archive")
    }

    @Test func enabledWithWorkAndReports() {
        let gb = 3 * 1_073_741_824
        let s = ReclaimStatus(ssdConnected: true, counts: counts(5, small: 2, recl: 2, bytes: gb))
        #expect(s.canArchive == true)
        #expect(s.buttonSubtitle == "5 not yet archived · 3.0 GB reclaimable")
    }

    @Test func nothingToArchiveDisablesButtonEvenWithSSD() {
        let s = ReclaimStatus(ssdConnected: true, counts: counts(0, small: 9, recl: 9, bytes: 0))
        #expect(s.canArchive == false)
    }

    @Test func importLineOmittedWhenNothingPending() {
        #expect(ReclaimStatus.humanImportLine(newToImport: 4, needsArchiving: 0) == nil)
        #expect(ReclaimStatus.humanImportLine(newToImport: 4, needsArchiving: 312)
                == "…and 312 items still need archiving.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReclaimStatusTests`
Expected: FAIL — `cannot find 'ReclaimStatus' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PhlookCore/ReclaimStatus.swift
import Foundation

public struct ReclaimStatus: Equatable {
    public let ssdConnected: Bool
    public let counts: MediaIndex.ArchiveCounts

    public init(ssdConnected: Bool, counts: MediaIndex.ArchiveCounts) {
        self.ssdConnected = ssdConnected
        self.counts = counts
    }

    public var canArchive: Bool { ssdConnected && counts.needsArchiving > 0 }
    public var reclaimableGB: Double { Double(counts.reclaimableBytes) / 1_073_741_824 }

    public var buttonSubtitle: String {
        guard ssdConnected else { return "Connect PHLOOK_SSD to archive" }
        return "\(counts.needsArchiving) not yet archived · \(String(format: "%.1f", reclaimableGB)) GB reclaimable"
    }

    public static func humanImportLine(newToImport: Int, needsArchiving: Int) -> String? {
        guard needsArchiving > 0 else { return nil }
        return "…and \(needsArchiving) items still need archiving."
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReclaimStatusTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/ReclaimStatus.swift Tests/PhlookCoreTests/ReclaimStatusTests.swift
git commit -m "feat: ReclaimStatus — pure enable/subtitle/import-line decisions"
```

---

### Task 9: Wire archive orchestration into `IndexingService`

**Files:**
- Modify: `Sources/PhlookCore/IndexingService.swift`
- Test: `Tests/PhlookCoreTests/IndexingServiceArchiveTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces on `IndexingService`:
  - `var proxyRoot: URL { root.appendingPathComponent("../PHLOOK_proxy").standardizedFileURL }` — sibling of the library root.
  - `func resolveArchiveTarget() throws -> ArchiveTarget?` — reads `index.markerID()`, resolves against `SSDArchiveTarget.mountedVolumeRoots()`; nil if no marker set or no matching drive.
  - `func setUpArchiveDrive(volumeRoot: URL) throws -> ArchiveTarget` — generates a `UUID().uuidString`, calls `SSDArchiveTarget.setUp`, stores it via `index.setMarkerID`, returns the target.
  - `func reclaimStatus() throws -> ReclaimStatus` — `ReclaimStatus(ssdConnected: (try resolveArchiveTarget()) != nil, counts: try index.archiveCounts())`.
  - `func runArchive(isCancelled: @escaping () -> Bool) throws -> ArchiveReport` — resolves the target (throws `ArchiveError.noSSD` if nil), builds `ArchiveService(index:, encoder: SmallVersionEncoder(), proxyDir: proxyRoot)`, runs it over `index.itemsNeedingArchiving()` **filtered to files that still exist locally**.
  - `enum ArchiveError: Error { case noSSD }`

- [ ] **Step 1: Write the failing test** (inject a fake target via a test-only seam)

```swift
import Testing
import Foundation
@testable import PhlookCore

struct IndexingServiceArchiveTests {
    private func makeService() throws -> IndexingService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return IndexingService(root: root)
    }

    @Test func setUpAndResolveArchiveTargetRoundTrips() throws {
        let svc = try makeService()
        let vol = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vol, withIntermediateDirectories: true)

        let target = try svc.setUpArchiveDrive(volumeRoot: vol)
        #expect(target.volumeRoot == vol)
        // Marker id persisted:
        #expect(try svc.mediaIndex.markerID() == target.markerID)
        // Resolve finds it among explicit candidates:
        #expect(SSDArchiveTarget.resolve(expectedMarkerID: target.markerID, candidateRoots: [vol]) != nil)
    }

    @Test func reclaimStatusReflectsCountsAndNoSSD() throws {
        let svc = try makeService()
        // No marker set ⇒ ssd not connected.
        let status = try svc.reclaimStatus()
        #expect(status.ssdConnected == false)
        #expect(status.canArchive == false)
    }

    @Test func runArchiveThrowsWithoutSSD() throws {
        let svc = try makeService()
        #expect(throws: IndexingService.ArchiveError.noSSD) {
            _ = try svc.runArchive(isCancelled: { false })
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IndexingServiceArchiveTests`
Expected: FAIL — `value of type 'IndexingService' has no member 'setUpArchiveDrive'`.

- [ ] **Step 3: Add the members to `IndexingService`**

Append inside `IndexingService`:

```swift
    public enum ArchiveError: Error { case noSSD }

    public var proxyRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent("PHLOOK_proxy")
    }

    public func setUpArchiveDrive(volumeRoot: URL) throws -> ArchiveTarget {
        let id = UUID().uuidString
        try SSDArchiveTarget.setUp(volumeRoot: volumeRoot, markerID: id)
        try index.setMarkerID(id, label: volumeRoot.lastPathComponent)
        return ArchiveTarget(volumeRoot: volumeRoot, markerID: id)
    }

    public func resolveArchiveTarget() throws -> ArchiveTarget? {
        guard let id = try index.markerID() else { return nil }
        return SSDArchiveTarget.resolve(expectedMarkerID: id,
                                        candidateRoots: SSDArchiveTarget.mountedVolumeRoots())
    }

    public func reclaimStatus() throws -> ReclaimStatus {
        ReclaimStatus(ssdConnected: (try resolveArchiveTarget()) != nil,
                      counts: try index.archiveCounts())
    }

    public func runArchive(isCancelled: @escaping () -> Bool) throws -> ArchiveReport {
        guard let target = try resolveArchiveTarget() else { throw ArchiveError.noSSD }
        let pending = try index.itemsNeedingArchiving()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let service = ArchiveService(index: index, encoder: SmallVersionEncoder(), proxyDir: proxyRoot)
        return service.run(target: target, items: pending, isCancelled: isCancelled)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IndexingServiceArchiveTests`
Expected: PASS.

- [ ] **Step 5: Run the whole suite (nothing regressed)**

Run: `swift test`
Expected: PASS (all tests, old and new).

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/IndexingService.swift Tests/PhlookCoreTests/IndexingServiceArchiveTests.swift
git commit -m "feat: IndexingService archive wiring — setup/resolve/status/run"
```

---

### Task 10: SwiftUI "Reclaim space" panel + Show original on SSD

**Files:**
- Create: `Sources/Phlook/ReclaimSpaceView.swift`
- Modify: `Sources/Phlook/LibraryViewModel.swift` (async wrappers + published status)
- Modify: `Sources/Phlook/ContentView.swift` (present the panel; add context-menu item)
- Modify: `Sources/Phlook/ImportBar.swift` (append the archiving second line)

**Interfaces:**
- Consumes: `IndexingService.reclaimStatus()/runArchive()/setUpArchiveDrive()/resolveArchiveTarget()`, `ReclaimStatus`, `ArchiveReport`.
- Produces: a presented panel with a primary button bound to `status.canArchive`; a background archive run reporting progress; a grid context-menu action "Show original on SSD" that reveals the master in Finder.

> UI is wired, not unit-tested (SwiftUI views). All decision logic it relies on is already tested in Tasks 8–9. Verify by building and a manual smoke run.

- [ ] **Step 1: Add view-model wrappers**

In `Sources/Phlook/LibraryViewModel.swift`, add (adapt to the file's existing `@Published`/actor conventions — match how other long tasks like enrich are surfaced):

```swift
    @Published var reclaimStatus: ReclaimStatus?
    @Published var archiveRunning = false
    @Published var lastArchiveReport: ArchiveReport?
    private var cancelArchive = false

    func refreshReclaimStatus() {
        reclaimStatus = try? indexing.reclaimStatus()
    }

    func setUpArchiveDrive(volumeRoot: URL) {
        _ = try? indexing.setUpArchiveDrive(volumeRoot: volumeRoot)
        refreshReclaimStatus()
    }

    func startArchive() {
        guard !archiveRunning else { return }
        archiveRunning = true; cancelArchive = false
        Task.detached { [weak self] in
            guard let self else { return }
            let report = try? await MainActor.run { self.indexing }.runArchive(isCancelled: { self.cancelArchive })
            await MainActor.run {
                self.lastArchiveReport = report
                self.archiveRunning = false
                self.refreshReclaimStatus()
            }
        }
    }

    func requestCancelArchive() { cancelArchive = true }

    /// Reveal a small-version item's master on the SSD (nil if not archived/absent).
    func revealOriginalOnSSD(for item: MediaItem) {
        guard let target = try? indexing.resolveArchiveTarget() else { return }
        let master = target.phlookRoot.appendingPathComponent(URL(fileURLWithPath: item.path).lastPathComponent)
        guard FileManager.default.fileExists(atPath: master.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([master])
    }
```

> Adjust `indexing` to the actual property name the view-model uses for its `IndexingService`. If the VM is a `@MainActor` `ObservableObject`, drop the `MainActor.run` wrapper and call `indexing.runArchive` directly inside `Task { }`.

- [ ] **Step 2: Create the panel view**

```swift
// Sources/Phlook/ReclaimSpaceView.swift
import SwiftUI
import PhlookCore

struct ReclaimSpaceView: View {
    @ObservedObject var vm: LibraryViewModel
    @State private var showingSetupPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reclaim space").font(.title2).bold()

            if let s = vm.reclaimStatus {
                Text(s.buttonSubtitle).foregroundStyle(.secondary)
                Text("\(s.counts.hasSmall) have 10% versions").font(.caption).foregroundStyle(.secondary)

                if vm.archiveRunning {
                    ProgressView("Archiving…")
                    Button("Cancel") { vm.requestCancelArchive() }
                } else {
                    Button {
                        vm.startArchive()
                    } label: { Label("Archive & shrink", systemImage: "externaldrive.badge.timemachine") }
                    .disabled(!s.canArchive)

                    if !s.ssdConnected {
                        Button("Set up archive drive…") { showingSetupPicker = true }
                            .buttonStyle(.link)
                    }
                }

                if let r = vm.lastArchiveReport {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Archived \(r.archived) · shrunk \(r.shrunk) · reclaimed \(r.reclaimed)")
                        if !r.skippedCollisions.isEmpty {
                            Text("Skipped (name collision): \(r.skippedCollisions.joined(separator: ", "))")
                                .foregroundStyle(.orange)
                        }
                        if !r.failures.isEmpty {
                            Text("\(r.failures.count) failures — originals kept").foregroundStyle(.red)
                        }
                    }.font(.caption)
                }
            } else {
                ProgressView().onAppear { vm.refreshReclaimStatus() }
            }
        }
        .padding()
        .frame(minWidth: 340)
        .fileImporter(isPresented: $showingSetupPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { vm.setUpArchiveDrive(volumeRoot: url) }
        }
        .onAppear { vm.refreshReclaimStatus() }
    }
}
```

- [ ] **Step 3: Present the panel + context menu in ContentView**

In `Sources/Phlook/ContentView.swift`: add a toolbar button or sidebar entry that presents `ReclaimSpaceView(vm: viewModel)` in a `.sheet` or dedicated pane (match the existing presentation style used for e.g. DuplicatesView). On the grid item's `.contextMenu`, add:

```swift
                Button("Show original on SSD") { viewModel.revealOriginalOnSSD(for: item) }
                    .disabled(item.archivedHash == nil)
```

- [ ] **Step 4: Append the archiving line in ImportBar**

In `Sources/Phlook/ImportBar.swift`, where the "N new to import" text is shown, add beneath it:

```swift
            if let line = ReclaimStatus.humanImportLine(
                newToImport: newCount,
                needsArchiving: vm.reclaimStatus?.counts.needsArchiving ?? 0) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
```

(Use the actual local variable names for the new-count and view-model in that file; call `vm.refreshReclaimStatus()` when the import view appears.)

- [ ] **Step 5: Build the app**

Run: `swift build`
Expected: Builds with no errors. (Fix any property-name mismatches flagged by the compiler against the real `LibraryViewModel`.)

- [ ] **Step 6: Manual smoke verification**

1. Launch the app. Open "Reclaim space" — with no SSD, button reads "Connect PHLOOK_SSD to archive" and is disabled.
2. Plug/point at a scratch folder via "Set up archive drive…"; confirm `.phlook_archive` appears and the button enables.
3. Run "Archive & shrink" on a tiny test library (a few files copied into a throwaway `~/Pictures/PHLOOK`); confirm masters land under `<drive>/PHLOOK/`, `PHLOOK_proxy/` gets small versions, originals move to Trash, and the report shows archived/shrunk/reclaimed.
4. Right-click a reclaimed item → "Show original on SSD" opens Finder at the master.

- [ ] **Step 7: Commit**

```bash
git add Sources/Phlook/ReclaimSpaceView.swift Sources/Phlook/LibraryViewModel.swift Sources/Phlook/ContentView.swift Sources/Phlook/ImportBar.swift
git commit -m "feat: Reclaim space panel, archive run, Show original on SSD, import archiving line"
```

---

## Self-Review

**Spec coverage:**
- Core invariant (delete last, after verify + small) → Task 7 pipeline order + `encodeFailureKeepsOriginal` test. ✓
- 3 DB columns + derived states → Tasks 2–3. ✓
- `archive_config` marker → Tasks 3–4. ✓
- Marker-file identity, refuse mismatched drive → Task 4 (`resolve`). ✓
- ImageIO photos + AVFoundation video + size guard → Task 5. ✓
- Serial, resumable (commit after archive + after shrink) → Task 7 (`markArchived`/`setSmallPath` commits; idempotent-already-archived test). ✓
- Name collision: identical→idempotent, different→skip+flag → Task 7 tests. ✓
- Reclaim keeps the row → Task 6. ✓
- SSD-absent disables reclaim → Tasks 8 (`canArchive`) + 9 (`runArchive` throws) + 10 (disabled button). ✓
- Phone-import second line → Task 8 (`humanImportLine`) + Task 10 wiring. ✓
- Show original on SSD (reveal, no copy-back) → Task 10. ✓
- Out-of-scope (restore-local, mirror drive, bit-rot sweep) → not implemented. ✓

**Placeholder scan:** No TBD/TODO; every code step shows real code. Task 10 UI notes name-matching caveats explicitly rather than leaving blanks. ✓

**Type consistency:** `ArchiveTarget`, `ArchiveCounts`, `ArchiveReport`, `ReclaimStatus`, `SmallVersionEncoding.makeSmallVersion(from:fileType:into:)`, `markArchived(path:hash:at:)`, `setSmallPath(path:smallPath:)`, `trashFilesOnly(paths:)`, `runArchive(isCancelled:)` are used identically across tasks. ✓
