# Wave 2 — Performance & Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch in seconds instead of minutes (incremental scan), bounded thumbnail memory, three grid densities, a right-edge timeline scrubber rail, and hover-scrub video previews.

**Architecture:** Core: `FileStamp`-based incremental scanning threaded through `LibraryScanner`/`MediaIndex`/`IndexingService` (migration v4), and a pure `TimelineIndex` for month buckets. App: NSCache-backed thumbnails, density state, `TimelineRail` overlay, single-player `HoverPreviewCoordinator`. Spec: `docs/superpowers/specs/2026-07-06-phlook-wave2-perf-ui-design.md`.

**Tech Stack:** Swift 5.10 SPM, swift-testing (never XCTest), GRDB, SwiftUI/AppKit, AVFoundation/AVKit.

## Global Constraints

- Tests ONLY via `make test` / `make test-one NAME=X`. All 82 existing tests stay green, warning-free.
- macOS 14 minimum, tools 5.10. Migration bump: `PRAGMA user_version` 3 → 4 (existing v2/v3 blocks untouched; version read once, sequential `if version < N` blocks).
- Incremental rule (exact): a file whose stored `file_size` and `modified_at` match the on-disk stat (mtime tolerance < 1s) is NOT re-hashed and NOT re-EXIF'd; its row is untouched. Everything else takes the full-extract path.
- Densities: micro 80pt / medium 160pt / large 240pt; persisted in UserDefaults key `gridDensity`.
- Hover previews: muted always, one active player app-wide, 350ms hover delay, videos only (nil/-1 duration and live-paired items excluded — the latter never render as videos anyway).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Incremental scan (Core; migration v4)

**Files:**
- Modify: `Sources/PhlookCore/MediaItem.swift`, `Sources/PhlookCore/MediaIndex.swift`, `Sources/PhlookCore/LibraryScanner.swift`, `Sources/PhlookCore/IndexingService.swift`
- Test: `Tests/PhlookCoreTests/IncrementalScanTests.swift` (create)

**Interfaces:**
- Produces: `MediaItem.fileSize: Int?` / `modifiedAt: Date?` (columns `file_size INTEGER`, `modified_at TEXT`, migration v4); `public struct FileStamp: Equatable { public let size: Int; public let modifiedAt: Date; public init(size:modifiedAt:) }`; `MediaIndex.allStamps() throws -> [String: FileStamp]` (rows with either field nil are omitted — they re-extract once, which is the upgrade backfill); `LibraryScanner.scan(known: [String: FileStamp]) throws -> (changed: [MediaItem], allPaths: Set<String>)`; `IndexingService.reindex()` uses it (fetch stamps → upsert only `changed` → `deleteMissing(keepingPaths: allPaths)`).
- Upsert: `fileSize`/`modifiedAt` are scan-authoritative — set unconditionally in BOTH branches (same-hash and changed-hash), unlike the enrichment fields.
- Keep the existing `scan()` (no-arg) as `scan(known: [:])` convenience so existing tests/call sites compile.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/IncrementalScanTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct IncrementalScanTests {
    func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func unchangedFileIsNotReExtracted() async throws {
        let root = try makeRoot()
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("a.jpg"), width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        // Corrupt the stored hash as a sentinel: a re-extract would overwrite it.
        let index = service.mediaIndex
        var row = try #require(try index.item(forPath: root.appendingPathComponent("a.jpg").path))
        let sentinel = "SENTINEL"
        row.hash = sentinel
        // Carry the row's stamps: a stamp-less upsert would take the
        // changed-hash branch and null them, forcing a re-extract for the
        // wrong reason.
        try index.upsert(MediaItem(path: row.path, hash: sentinel, dateTaken: row.dateTaken,
                                   fileType: row.fileType, width: row.width, height: row.height,
                                   lastScanned: row.lastScanned, duration: row.duration,
                                   fileSize: row.fileSize, modifiedAt: row.modifiedAt))

        _ = try service.reindex()   // size+mtime unchanged → must skip extraction
        let after = try #require(try index.item(forPath: row.path))
        #expect(after.hash == sentinel)
    }

    @Test func touchedFileIsReExtracted() async throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        // Rewrite with different content AND a different mtime.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try TestFixtures.writeJPEG(at: url, width: 32, height: 32)

        _ = try service.reindex()
        let after = try #require(try service.mediaIndex.item(forPath: url.path))
        #expect(after.width == 32)   // fresh extraction picked up the new dimensions
    }

    @Test func newAndRemovedFilesStillWork() throws {
        let root = try makeRoot()
        let a = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: a, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        try FileManager.default.removeItem(at: a)
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("b.jpg"), width: 16, height: 16)
        _ = try service.reindex()

        #expect(try service.mediaIndex.item(forPath: a.path) == nil)
        #expect(try service.mediaIndex.item(forPath: root.appendingPathComponent("b.jpg").path) != nil)
    }

    @Test func rowsWithoutStampsReExtractOnceThenStabilize() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()

        // Simulate a pre-v4 row: null the stamps directly.
        try service.mediaIndex.nullStampsForTesting(path: url.path)
        #expect(try service.mediaIndex.allStamps()[url.path] == nil)   // omitted when nil

        _ = try service.reindex()   // backfills stamps via full extract
        #expect(try service.mediaIndex.allStamps()[url.path] != nil)
    }

    @Test func stampsSurviveEnrichmentStyleUpsert() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16)
        let service = IndexingService(root: root)
        _ = try service.reindex()
        let index = service.mediaIndex

        var row = try #require(try index.item(forPath: url.path))
        row.duration = 5   // enrichment-style write-back keeps same hash
        try index.upsert(row)
        #expect(try index.allStamps()[url.path] != nil)
    }
}
```

Add a small test hook to `MediaIndex` (internal, clearly named):

```swift
    /// Test support: simulate a pre-v4 row.
    func nullStampsForTesting(path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE files SET file_size = NULL, modified_at = NULL WHERE path = ?",
                           arguments: [path])
        }
    }
```

- [ ] **Step 2: RED**

`make test-one NAME=IncrementalScanTests` — COMPILE ERROR (`no member 'allStamps'` / `nullStampsForTesting`).

- [ ] **Step 3: Implement**

1. `MediaItem`: add `public var fileSize: Int?` and `public var modifiedAt: Date?`; CodingKeys `fileSize = "file_size"`, `modifiedAt = "modified_at"`; init params (after `duration`, defaults nil).
2. `MediaIndex.migrate()` — after the `< 3` block:
```swift
            if version < 4 {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN file_size INTEGER")
                try db.execute(sql: "ALTER TABLE files ADD COLUMN modified_at TEXT")
                try db.execute(sql: "PRAGMA user_version = 4")
            }
```
Also add both columns to the fresh `CREATE TABLE IF NOT EXISTS files` statement. IMPORTANT: guard the ALTERs the same way the duration column is guarded (introspect `db.columns(in: "files")`) so a fresh DB (already has the columns from CREATE) doesn't fail the ALTER — or simpler: run the introspection-guarded ALTER for each column inside the `< 4` block.
3. `MediaIndex.upsert`: same-hash branch adds `existing.fileSize = item.fileSize ?? existing.fileSize` and `existing.modifiedAt = item.modifiedAt ?? existing.modifiedAt` (nil-coalescing is sufficient: scan items always carry stamps, and enrichment write-backs carry the row's own non-nil values); the changed-hash branch takes the incoming values verbatim like its other fields.
4. `FileStamp` + `allStamps()` in MediaIndex:
```swift
public struct FileStamp: Equatable {
    public let size: Int
    public let modifiedAt: Date
    public init(size: Int, modifiedAt: Date) { self.size = size; self.modifiedAt = modifiedAt }

    public func matches(size: Int, modifiedAt: Date) -> Bool {
        self.size == size && abs(self.modifiedAt.timeIntervalSince(modifiedAt)) < 1.0
    }
}
```
```swift
    /// path → stamp for rows that have both fields (pre-v4 rows are omitted
    /// so they take the full-extract path once, which backfills them).
    public func allStamps() throws -> [String: FileStamp] {
        try dbQueue.read { db in
            var result: [String: FileStamp] = [:]
            let rows = try Row.fetchAll(db, sql:
                "SELECT path, file_size, modified_at FROM files WHERE file_size IS NOT NULL AND modified_at IS NOT NULL")
            for row in rows {
                let path: String = row["path"]
                let size: Int = row["file_size"]
                if let date = row["modified_at"] as Date? {
                    result[path] = FileStamp(size: size, modifiedAt: date)
                }
            }
            return result
        }
    }
```
(If GRDB's Date decoding from the TEXT column needs help, decode as String and parse with the same formatter GRDB used to store — verify with a quick test iteration; MediaItem's Codable dates already round-trip through this table, so `row["modified_at"] as Date?` is expected to work.)
5. `LibraryScanner`: restructure `scan()` into:
```swift
    public func scan(known: [String: FileStamp] = [:]) throws -> (changed: [MediaItem], allPaths: Set<String>) {
        var changed: [MediaItem] = []
        var allPaths: Set<String> = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return ([], []) }
        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            let isImage = Self.imageExts.contains(ext)
            let isVideo = Self.videoExts.contains(ext)
            guard isImage || isVideo else { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            allPaths.insert(url.path)
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate ?? Date.distantPast
            if let stamp = known[url.path], stamp.matches(size: size, modifiedAt: mtime) {
                continue   // unchanged: row stays untouched
            }
            let (w, h, taken): (Int?, Int?, Date?) = isImage ? Self.imageMeta(url) : (nil, nil, nil)
            changed.append(MediaItem(
                path: url.path, hash: Self.quickHash(url),
                dateTaken: isImage ? (taken ?? values.creationDate) : nil,
                fileType: isImage ? "image" : "video",
                width: w, height: h, lastScanned: Date(),
                duration: nil, fileSize: size, modifiedAt: mtime))
        }
        return (changed, allPaths)
    }
```
NOTE the video `dateTaken: nil` rule from the earlier fix MUST be preserved exactly as shown. Keep a compatibility wrapper `public func scan() throws -> [MediaItem] { try scan(known: [:]).changed }` if existing tests call it.
6. `IndexingService.reindex()`:
```swift
    @discardableResult
    public func reindex() throws -> Int {
        let known = (try? index.allStamps()) ?? [:]
        let (changed, allPaths) = try LibraryScanner(root: root).scan(known: known)
        for item in changed where FileManager.default.fileExists(atPath: item.path) {
            try index.upsert(item)
        }
        try index.deleteMissing(keepingPaths: allPaths)
        return try index.count()
    }
```

- [ ] **Step 4: GREEN + full suite**

`make test-one NAME=IncrementalScanTests` — 5 PASS. `make test` — ALL green (LibraryScanner/IndexingService/Ingest tests must survive the refactor; fix compatibility shims, never test expectations, unless an expectation is genuinely about the old always-rescan behavior — report any such change).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/ Tests/PhlookCoreTests/IncrementalScanTests.swift
git commit -m "feat: incremental scan — unchanged files skip hashing/EXIF via size+mtime stamps (v4)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Thumbnail memory cap (app)

**Files:** Modify `Sources/Phlook/LibraryViewModel.swift`.

- [ ] **Step 1: Implement**

In `LibraryViewModel`:
```swift
    private let thumbCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2_000
        return cache
    }()

    func thumbnail(for item: MediaItem, size: Int = 160) async -> NSImage? {
        let key = "\(item.path)#\(size)" as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: CGFloat(size)) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }
```
(Adjust the `thumbnailURL(for:size:)` size argument type to whatever it actually takes — read the file.)

- [ ] **Step 2: Build + tests + commit**

`swift build` clean; `make test` green.
```bash
git add Sources/Phlook/LibraryViewModel.swift
git commit -m "feat: NSCache-backed thumbnails — bounded memory over 17k-cell scrolls

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Grid densities (app)

**Files:** Modify `Sources/Phlook/LibraryViewModel.swift`, `Sources/Phlook/MicroGridView.swift`.

- [ ] **Step 1: Density model in the VM**

```swift
enum GridDensity: Int, CaseIterable, Identifiable {
    case micro = 80, medium = 160, large = 240
    var id: Int { rawValue }
    var symbol: String {
        switch self {
        case .micro: "square.grid.4x3.fill"
        case .medium: "square.grid.3x2"
        case .large: "square.grid.2x2"
        }
    }
}
```
VM:
```swift
    @Published var density: GridDensity = GridDensity(
        rawValue: UserDefaults.standard.integer(forKey: "gridDensity")) ?? .micro {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "gridDensity") }
    }
    func stepDensity(_ delta: Int) {
        let all = GridDensity.allCases
        if let i = all.firstIndex(of: density) {
            density = all[ViewerMath.clamp(i + delta, count: all.count)]
        }
    }
```
(UserDefaults.integer returns 0 when unset → rawValue 0 → init fails → `?? .micro`. Correct.)

- [ ] **Step 2: Grid uses it**

`MicroGridView`: replace the fixed 80s:
```swift
    private var columns: [GridItem] {
        let side = CGFloat(vm.density.rawValue)
        return [GridItem(.adaptive(minimum: side, maximum: side), spacing: 2)]
    }
```
`ThumbCell` gains `let side: CGFloat` (diffable — pass `CGFloat(vm.density.rawValue)`), uses `.frame(width: side, height: side)`, requests `vm.thumbnail(for: item, size: Int(side * 2))`, and scales badge fonts: duration text `side >= 160 ? .caption : .caption2`, play glyph size `side >= 160 ? 12 : 9`.
Density picker in `filterBar` next to the filter:
```swift
            Picker("Density", selection: $vm.density) {
                ForEach(GridDensity.allCases) { d in
                    Image(systemName: d.symbol).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
```
Keyboard: in `GridKeyCatcher` (respecting the existing suspension guards), handle ⌘+ (`charactersIgnoringModifiers` "=" or "+") → `vm.stepDensity(+1)` and ⌘− ("-") → `vm.stepDensity(-1)`, swallow.

- [ ] **Step 3: Build + tests + smoke note + commit**

`swift build` clean; `make test` green; `make app && open ./Phlook.app` launch check.
```bash
git add Sources/Phlook/
git commit -m "feat: grid densities — micro/medium/large with ⌘± and persisted choice

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Timeline scrubber rail

**Files:**
- Create: `Sources/PhlookCore/TimelineIndex.swift`, `Sources/Phlook/TimelineRail.swift`
- Modify: `Sources/Phlook/MicroGridView.swift`
- Test: `Tests/PhlookCoreTests/TimelineIndexTests.swift` (create)

**Interfaces:**
- Produces (Core):
  ```swift
  public struct TimelineBucket: Equatable {
      public let monthStart: Date?      // nil = the trailing "Undated" bucket
      public let label: String          // "Mar 2026" / "Undated"
      public let firstItemPath: String
      public let count: Int
      public let isYearStart: Bool      // first bucket of its year in the list
  }
  public enum TimelineIndex {
      /// Buckets in the exact order of `items` (assumed date-desc with nil
      /// dates last — the grid's order). Consecutive same-month runs merge.
      public static func compute(items: [MediaItem]) -> [TimelineBucket]
  }
  ```

- [ ] **Step 1: Failing tests**

Create `Tests/PhlookCoreTests/TimelineIndexTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct TimelineIndexTests {
    func item(_ path: String, _ iso: String?) -> MediaItem {
        let date = iso.flatMap { ISO8601DateFormatter().date(from: $0) }
        return MediaItem(path: path, hash: nil, dateTaken: date, fileType: "image",
                         width: nil, height: nil, lastScanned: Date())
    }

    @Test func bucketsByMonthInInputOrderWithCounts() {
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/b", "2026-03-01T10:00:00Z"),
            item("/c", "2026-01-05T10:00:00Z"),
            item("/d", "2025-12-31T10:00:00Z"),
        ])
        #expect(buckets.count == 3)
        #expect(buckets[0].count == 2)
        #expect(buckets[0].firstItemPath == "/a")
        #expect(buckets[1].firstItemPath == "/c")
        #expect(buckets[2].firstItemPath == "/d")
    }

    @Test func yearStartsAreFlagged() {
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/b", "2026-01-05T10:00:00Z"),
            item("/c", "2025-12-31T10:00:00Z"),
        ])
        #expect(buckets[0].isYearStart)          // first 2026 bucket
        #expect(!buckets[1].isYearStart)
        #expect(buckets[2].isYearStart)          // first 2025 bucket
    }

    @Test func undatedItemsFormTrailingBucket() {
        let buckets = TimelineIndex.compute(items: [
            item("/a", "2026-03-20T10:00:00Z"),
            item("/x", nil),
            item("/y", nil),
        ])
        #expect(buckets.last?.monthStart == nil)
        #expect(buckets.last?.label == "Undated")
        #expect(buckets.last?.count == 2)
        #expect(buckets.last?.firstItemPath == "/x")
    }

    @Test func emptyInputYieldsNoBuckets() {
        #expect(TimelineIndex.compute(items: []).isEmpty)
    }
}
```

- [ ] **Step 2: RED**, then **Step 3: Implement**

`Sources/PhlookCore/TimelineIndex.swift`:

```swift
import Foundation

public struct TimelineBucket: Equatable {
    public let monthStart: Date?
    public let label: String
    public let firstItemPath: String
    public let count: Int
    public let isYearStart: Bool
}

public enum TimelineIndex {
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func compute(items: [MediaItem]) -> [TimelineBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var buckets: [TimelineBucket] = []
        var currentKey: DateComponents?
        var currentStart: Date?
        var currentFirst: String?
        var currentCount = 0
        var undatedFirst: String?
        var undatedCount = 0

        func flush() {
            if let first = currentFirst, let start = currentStart, currentCount > 0 {
                buckets.append(TimelineBucket(
                    monthStart: start, label: monthFormatter.string(from: start),
                    firstItemPath: first, count: currentCount, isYearStart: false))
            }
            currentKey = nil; currentStart = nil; currentFirst = nil; currentCount = 0
        }

        for item in items {
            guard let date = item.dateTaken else {
                if undatedFirst == nil { undatedFirst = item.path }
                undatedCount += 1
                continue
            }
            let key = calendar.dateComponents([.year, .month], from: date)
            if key != currentKey {
                flush()
                currentKey = key
                currentStart = calendar.date(from: key)
                currentFirst = item.path
            }
            currentCount += 1
        }
        flush()
        if let first = undatedFirst {
            buckets.append(TimelineBucket(monthStart: nil, label: "Undated",
                                          firstItemPath: first, count: undatedCount,
                                          isYearStart: false))
        }
        // Year flags: first dated bucket of each distinct year.
        var seenYears: Set<Int> = []
        return buckets.map { bucket in
            guard let start = bucket.monthStart else { return bucket }
            let year = calendar.component(.year, from: start)
            let isFirst = !seenYears.contains(year)
            seenYears.insert(year)
            return TimelineBucket(monthStart: bucket.monthStart, label: bucket.label,
                                  firstItemPath: bucket.firstItemPath, count: bucket.count,
                                  isYearStart: isFirst)
        }
    }
}
```

- [ ] **Step 4: GREEN + full suite**, then **Step 5: the rail view**

Create `Sources/Phlook/TimelineRail.swift`:

```swift
import SwiftUI
import PhlookCore

/// Right-edge scrubber: one tick per month (longer at year starts). Hover
/// shows the month; click/drag jumps the grid. Fades when idle.
struct TimelineRail: View {
    let buckets: [TimelineBucket]
    let onJump: (String) -> Void
    @State private var hovering = false
    @State private var hoverLabel: String?
    @State private var lastJumpedPath: String?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .trailing) {
                // Ticks, evenly distributed over the rail height.
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    Rectangle()
                        .fill(.secondary.opacity(hovering ? 0.9 : 0.4))
                        .frame(width: bucket.isYearStart ? 16 : 8, height: 1.5)
                        .position(x: geo.size.width - (bucket.isYearStart ? 10 : 6),
                                  y: yFor(index: index, height: height))
                }
                if hovering, let label = hoverLabel {
                    Text(label)
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: -28)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .onHover { hovering = $0; if !$0 { hoverLabel = nil } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let (bucket, _) = bucket(atY: value.location.y, height: height) else { return }
                        hoverLabel = bucket.label
                        if bucket.firstItemPath != lastJumpedPath {
                            lastJumpedPath = bucket.firstItemPath
                            onJump(bucket.firstItemPath)
                        }
                    }
                    .onEnded { _ in lastJumpedPath = nil }
            )
        }
        .frame(width: 36)
    }

    private func yFor(index: Int, height: CGFloat) -> CGFloat {
        guard buckets.count > 1 else { return height / 2 }
        let usable = height - 24
        return 12 + usable * CGFloat(index) / CGFloat(buckets.count - 1)
    }

    private func bucket(atY y: CGFloat, height: CGFloat) -> (TimelineBucket, Int)? {
        guard !buckets.isEmpty else { return nil }
        let usable = max(height - 24, 1)
        let fraction = min(max((y - 12) / usable, 0), 1)
        let index = min(Int(round(fraction * CGFloat(buckets.count - 1))), buckets.count - 1)
        return (buckets[index], index)
    }
}
```

Wire into `MicroGridView.content`'s grid branch:
```swift
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(...) {
                        ForEach(vm.visibleItems, id: \.path) { item in
                            ThumbCell(...)
                                .id(item.path)
                        }
                    }
                    .padding(2)
                }
                .overlay(alignment: .trailing) {
                    let buckets = TimelineIndex.compute(items: vm.visibleItems)
                    if buckets.count >= 2 {
                        TimelineRail(buckets: buckets) { path in
                            proxy.scrollTo(path, anchor: .top)
                        }
                    }
                }
            }
```
PERFORMANCE NOTE: `TimelineIndex.compute` over 17k items on every body evaluation is wasteful — cache it in the VM: `@Published private(set) var timeline: [TimelineBucket] = []`, recomputed at the end of `refreshItems` and in `filter.didSet` (after rebuildVisible), and use `vm.timeline` in the overlay instead of computing inline. Do it that way.

- [ ] **Step 6: Build + tests + launch check + commit**

```bash
git add Sources/PhlookCore/TimelineIndex.swift Sources/Phlook/TimelineRail.swift Sources/Phlook/MicroGridView.swift Sources/Phlook/LibraryViewModel.swift Tests/PhlookCoreTests/TimelineIndexTests.swift
git commit -m "feat: timeline scrubber rail — month ticks, hover labels, drag-to-jump

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Hover-scrub video previews

**Files:**
- Create: `Sources/Phlook/HoverPreview.swift`
- Modify: `Sources/Phlook/MicroGridView.swift`

- [ ] **Step 1: Coordinator + player view**

`Sources/Phlook/HoverPreview.swift`:

```swift
import SwiftUI
import AVFoundation
import AVKit

/// One muted, looping preview player app-wide; hovering a new cell steals it.
@MainActor
final class HoverPreviewCoordinator: ObservableObject {
    static let shared = HoverPreviewCoordinator()
    @Published private(set) var activePath: String?
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pendingTask: Task<Void, Never>?

    func hoverBegan(path: String) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.start(path: path)
        }
    }

    func hoverEnded(path: String) {
        pendingTask?.cancel()
        if activePath == path { stop() }
    }

    private func start(path: String) {
        stop()
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        activePath = path
        queue.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        activePath = nil
    }
}

struct HoverPreviewPlayer: NSViewRepresentable {
    let player: AVQueuePlayer

    func makeNSView(context: Context) -> AVPlayerLayerView { AVPlayerLayerView(player: player) }
    func updateNSView(_ nsView: AVPlayerLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class AVPlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
```

- [ ] **Step 2: ThumbCell wiring**

In `ThumbCell` (MicroGridView.swift): `@ObservedObject private var hover = HoverPreviewCoordinator.shared`; in the main ZStack, above the image, when active:
```swift
            if hover.activePath == item.path, let player = hover.player {
                HoverPreviewPlayer(player: player)
            }
```
and on the cell:
```swift
        .onHover { inside in
            guard item.fileType == "video", !isLive,
                  let d = item.duration, d > 0 else { return }
            if inside { hover.hoverBegan(path: item.path) }
            else { hover.hoverEnded(path: item.path) }
        }
```
Also stop any active preview when the viewer opens: in `vm.openViewer`, call `HoverPreviewCoordinator.shared.stop()` — wire it via a closure or direct call from ThumbCell's double-tap before `openViewer` (simplest: first line of the double-tap gesture: `HoverPreviewCoordinator.shared.stop()`).

- [ ] **Step 3: Build + tests + launch check + commit**

```bash
git add Sources/Phlook/HoverPreview.swift Sources/Phlook/MicroGridView.swift
git commit -m "feat: hover-scrub video previews — single muted looping player, 350ms delay

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification checklist (after all tasks)

- [ ] `make test` — all green (82 + ~9 new).
- [ ] Launch timing evidence: second `reindex()` over the real 17k library completes in seconds (log or time it) — the headline of this wave.
- [ ] Human smoke: relaunch speed; density switching + ⌘±; rail hover/drag jumps years; hovering a video cell previews muted and stops on exit; memory stays sane scrolling far.
