# PHLOOK Viewer & Video Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Video duration badges + chronological video dates in the grid, a full-window viewer (images + video playback) with prev/next navigation and a metadata sidebar, and a right-click menu.

**Architecture:** PhlookCore gains the testable logic (schema migration, `VideoMetadataEnricher`, `DurationFormatter`, `ViewerMath`, `MediaDetails`, a real generated `.mov` test fixture); the Phlook app target gains thin SwiftUI views (grid additions, `ViewerView` overlay, `DetailsSidebar`) driven by `LibraryViewModel`. Spec: `docs/superpowers/specs/2026-07-06-phlook-viewer-design.md`.

**Tech Stack:** Swift 5.10 SPM, swift-testing (NOT XCTest), GRDB, ImageIO, AVFoundation (modern async `load(_:)` only), AVKit, SwiftUI/AppKit.

## Global Constraints

- Tests run ONLY via `make test` / `make test-one NAME=X` (bare `swift test` finds 0 tests on this CLT-only machine).
- swift-testing only: `import Testing`, `@Test`, `#expect`, `#require`. Never XCTest.
- macOS 14 minimum, swift-tools-version 5.10 (do not bump).
- AVFoundation: modern async `load(_:)` API only — deprecated sync accessors produce warnings, and test output must stay warning-free.
- Duration sentinel: `-1` means "tried, unreadable" — excluded from enrichment queries, never shown in UI.
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- All existing tests (35) must stay green after every task.
- App-target (UI) tasks have no unit tests (no UI test infra) — they are verified by `swift build`, `make test` (regressions), and a manual smoke checklist via `make app`.

---

### Task 1: Schema — `duration` column, migration, enrichment-preserving upsert

**Files:**
- Modify: `Sources/PhlookCore/MediaItem.swift`
- Modify: `Sources/PhlookCore/MediaIndex.swift`
- Test: `Tests/PhlookCoreTests/MediaIndexMigrationTests.swift` (create)

**Interfaces:**
- Consumes: existing `MediaItem`, `MediaIndex`.
- Produces: `MediaItem.duration: Double?` (new stored property, last init param, default nil); `MediaIndex` databases (new and pre-existing) have a `duration REAL` column; `upsert` preserves existing `duration`/`dateTaken`/`width`/`height` when the incoming item has nil for them.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/MediaIndexMigrationTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import PhlookCore

struct MediaIndexMigrationTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
    }

    func makeItem(path: String = "/x/a.mov", duration: Double? = nil,
                  dateTaken: Date? = nil, width: Int? = nil, height: Int? = nil) -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: dateTaken, fileType: "video",
                  width: width, height: height, lastScanned: Date(), duration: duration)
    }

    @Test func freshDatabaseStoresDuration() throws {
        let index = try MediaIndex(dbPath: tempDBPath())
        try index.upsert(makeItem(duration: 12.5))
        let item = try #require(try index.item(forPath: "/x/a.mov"))
        #expect(item.duration == 12.5)
    }

    @Test func preExistingDatabaseGainsDurationColumn() throws {
        // Simulate a v1 database created before the duration column existed.
        let path = tempDBPath()
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT UNIQUE NOT NULL,
                    hash TEXT,
                    date_taken TEXT,
                    file_type TEXT,
                    width INTEGER,
                    height INTEGER,
                    last_scanned TEXT
                );
            """)
            try db.execute(sql: """
                INSERT INTO files (path, hash, file_type, last_scanned)
                VALUES ('/old/row.jpg', 'h', 'image', '2026-01-01T00:00:00Z')
            """)
        }
        try queue.close()

        let index = try MediaIndex(dbPath: path)   // migration must ALTER, not fail
        let old = try #require(try index.item(forPath: "/old/row.jpg"))
        #expect(old.duration == nil)               // old row survives, duration nil
        try index.upsert(makeItem(duration: 3.0))  // new column is writable
        #expect(try #require(try index.item(forPath: "/x/a.mov")).duration == 3.0)
    }

    @Test func migrationIsIdempotent() throws {
        let path = tempDBPath()
        _ = try MediaIndex(dbPath: path)
        _ = try MediaIndex(dbPath: path)   // second open must not throw
    }

    @Test func upsertPreservesEnrichedFieldsAgainstNilScan() throws {
        let index = try MediaIndex(dbPath: tempDBPath())
        let enrichedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try index.upsert(makeItem(duration: 30.0, dateTaken: enrichedDate, width: 1920, height: 1080))
        // Next scan pass knows nothing about video metadata — all nil:
        try index.upsert(makeItem())
        let item = try #require(try index.item(forPath: "/x/a.mov"))
        #expect(item.duration == 30.0)
        #expect(item.dateTaken == enrichedDate)
        #expect(item.width == 1920)
        #expect(item.height == 1080)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-one NAME=MediaIndexMigrationTests`
Expected: COMPILE ERROR — `extra argument 'duration' in call` (MediaItem has no duration yet).

- [ ] **Step 3: Implement**

In `Sources/PhlookCore/MediaItem.swift` — add the property, coding key, and init param (duration LAST with default so existing call sites compile):

```swift
public struct MediaItem: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var path: String
    public var hash: String?
    public var dateTaken: Date?
    public var fileType: String   // "image" | "video"
    public var width: Int?
    public var height: Int?
    public var lastScanned: Date
    public var duration: Double?  // seconds; nil = unknown; -1 = unreadable sentinel

    public static let databaseTableName = "files"

    public enum Columns {
        public static let path = Column("path")
        public static let dateTaken = Column("date_taken")
    }

    enum CodingKeys: String, CodingKey {
        case id, path, hash
        case dateTaken = "date_taken"
        case fileType = "file_type"
        case width, height
        case lastScanned = "last_scanned"
        case duration
    }

    public init(id: Int64? = nil, path: String, hash: String?, dateTaken: Date?,
                fileType: String, width: Int?, height: Int?, lastScanned: Date,
                duration: Double? = nil) {
        self.id = id; self.path = path; self.hash = hash; self.dateTaken = dateTaken
        self.fileType = fileType; self.width = width; self.height = height
        self.lastScanned = lastScanned; self.duration = duration
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

In `Sources/PhlookCore/MediaIndex.swift` — replace `migrate()` (fresh table includes the column; old tables get ALTERed) and update `upsert`:

```swift
    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT UNIQUE NOT NULL,
                    hash TEXT,
                    date_taken TEXT,
                    file_type TEXT,
                    width INTEGER,
                    height INTEGER,
                    last_scanned TEXT,
                    duration REAL
                );
            """)
            // Databases created before the duration column existed:
            let columns = try db.columns(in: "files").map(\.name)
            if !columns.contains("duration") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN duration REAL")
            }
        }
    }
```

```swift
    public func upsert(_ item: MediaItem) throws {
        try dbQueue.write { db in
            if var existing = try MediaItem.filter(MediaItem.Columns.path == item.path).fetchOne(db) {
                existing.hash = item.hash
                // Enrichment-preserving: a scan pass carries nil for fields only
                // the video enricher knows; never wipe an enriched value with nil.
                existing.dateTaken = item.dateTaken ?? existing.dateTaken
                existing.width = item.width ?? existing.width
                existing.height = item.height ?? existing.height
                existing.duration = item.duration ?? existing.duration
                existing.fileType = item.fileType
                existing.lastScanned = item.lastScanned
                try existing.update(db)
            } else {
                try item.insert(db)
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=MediaIndexMigrationTests` — 4 PASS.
Then `make test` — all green (the changed upsert must not break existing MediaIndex/IndexingService tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/MediaItem.swift Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/MediaIndexMigrationTests.swift
git commit -m "feat: duration column with idempotent migration + enrichment-preserving upsert

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: DurationFormatter + generated QuickTime test fixture

**Files:**
- Create: `Sources/PhlookCore/DurationFormatter.swift`
- Modify: `Sources/PhlookCore/TestSupport.swift`
- Test: `Tests/PhlookCoreTests/DurationFormatterTests.swift` (create), `Tests/PhlookCoreTests/MovieFixtureTests.swift` (create)

**Interfaces:**
- Produces: `DurationFormatter.string(seconds: Double?) -> String?` — `0:34`, `12:05`, `1:12:05`; nil for nil/negative input. `TestFixtures.writeQuickTimeMovie(at:duration:width:height:creationDate:) async throws` — a real playable `.mov` (solid frames, H.264); optional `creationDate` string (e.g. `"2026-03-08T13:56:58-0300"`) embedded as `com.apple.quicktime.creationdate`.

- [ ] **Step 1: Write the failing formatter tests**

Create `Tests/PhlookCoreTests/DurationFormatterTests.swift`:

```swift
import Testing
@testable import PhlookCore

struct DurationFormatterTests {
    @Test func formatsSecondsOnly() { #expect(DurationFormatter.string(seconds: 34) == "0:34") }
    @Test func formatsMinutes() { #expect(DurationFormatter.string(seconds: 725) == "12:05") }
    @Test func formatsHours() { #expect(DurationFormatter.string(seconds: 4325) == "1:12:05") }
    @Test func roundsFractionalSeconds() { #expect(DurationFormatter.string(seconds: 29.6) == "0:30") }
    @Test func nilAndSentinelYieldNil() {
        #expect(DurationFormatter.string(seconds: nil) == nil)
        #expect(DurationFormatter.string(seconds: -1) == nil)
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `make test-one NAME=DurationFormatterTests`
Expected: COMPILE ERROR — `cannot find 'DurationFormatter' in scope`.

- [ ] **Step 3: Implement the formatter**

Create `Sources/PhlookCore/DurationFormatter.swift`:

```swift
import Foundation

public enum DurationFormatter {
    /// "0:34", "12:05", "1:12:05". nil for nil or negative (incl. the -1 sentinel).
    public static func string(seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
```

Run: `make test-one NAME=DurationFormatterTests` — 5 PASS.

- [ ] **Step 4: Write the failing fixture test**

Create `Tests/PhlookCoreTests/MovieFixtureTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import PhlookCore

struct MovieFixtureTests {
    @Test func fixtureMovieIsReadableWithDurationAndCreationDate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clip.mov")

        try await TestFixtures.writeQuickTimeMovie(
            at: url, duration: 1.0, width: 64, height: 48,
            creationDate: "2026-03-08T13:56:58-0300")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.35)

        // The embedded QuickTime creation date must round-trip through the
        // same extraction path the enricher uses.
        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .videoMetadata)
        #expect(cd.timestampString() == "2026-03-08_13-56-58")
    }
}
```

- [ ] **Step 5: Run to verify RED**

Run: `make test-one NAME=MovieFixtureTests`
Expected: COMPILE ERROR — `type 'TestFixtures' has no member 'writeQuickTimeMovie'`.

- [ ] **Step 6: Implement the fixture writer**

Append to `Sources/PhlookCore/TestSupport.swift` (inside `enum TestFixtures`), and add `import AVFoundation` and `import CoreVideo` at the top of the file:

```swift
    /// Writes a real, playable QuickTime movie of solid frames (H.264, 10fps).
    /// `creationDate` (e.g. "2026-03-08T13:56:58-0300") is embedded as
    /// com.apple.quicktime.creationdate when provided.
    public static func writeQuickTimeMovie(
        at url: URL, duration: Double = 1.0, width: Int = 64, height: Int = 48,
        creationDate: String? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        if let creationDate {
            let md = AVMutableMetadataItem()
            md.identifier = .quickTimeMetadataCreationDate
            md.value = creationDate as NSString
            writer.metadata = [md]
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "TestFixtures", code: 10)
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "TestFixtures", code: 11) }

        let fps = 10
        let frames = max(1, Int((duration * Double(fps)).rounded()))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pixelBuffer,
                           withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "TestFixtures", code: 12)
        }
    }
```

Note: if the metadata item needs more fields to round-trip on this SDK (some require `keySpace`/`extendedLanguageTag`), adjust minimally until the fixture test's `CaptureDateExtractor` assertion passes, and record the deviation in your report.

- [ ] **Step 7: Run to verify GREEN, then the full suite**

Run: `make test-one NAME=MovieFixtureTests` — 1 PASS.
Run: `make test` — all green, warning-free.

- [ ] **Step 8: Commit**

```bash
git add Sources/PhlookCore/DurationFormatter.swift Sources/PhlookCore/TestSupport.swift Tests/PhlookCoreTests/DurationFormatterTests.swift Tests/PhlookCoreTests/MovieFixtureTests.swift
git commit -m "feat: DurationFormatter + generated QuickTime movie test fixture

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: VideoMetadataEnricher + IndexingService post-pass

**Files:**
- Create: `Sources/PhlookCore/VideoMetadataEnricher.swift`
- Modify: `Sources/PhlookCore/MediaIndex.swift` (add `videosNeedingEnrichment()`)
- Modify: `Sources/PhlookCore/IndexingService.swift` (add `enrichVideos()`)
- Test: `Tests/PhlookCoreTests/VideoMetadataEnricherTests.swift` (create)

**Interfaces:**
- Consumes: `MediaItem.duration` (Task 1), `TestFixtures.writeQuickTimeMovie` (Task 2), `CaptureDateExtractor` (existing).
- Produces: `MediaIndex.videosNeedingEnrichment() throws -> [MediaItem]`; `VideoMetadataEnricher().enrich(index: MediaIndex) async -> Int` (count processed); `IndexingService.enrichVideos() async -> Int`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/VideoMetadataEnricherTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct VideoMetadataEnricherTests {
    func makeWorld() throws -> (dir: URL, index: MediaIndex) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try MediaIndex(dbPath: dir.appendingPathComponent("test.db").path)
        return (dir, index)
    }

    func upsertVideoRow(_ index: MediaIndex, path: String) throws {
        try index.upsert(MediaItem(path: path, hash: "h", dateTaken: nil,
                                   fileType: "video", width: nil, height: nil,
                                   lastScanned: Date()))
    }

    @Test func enrichesRealVideoWithDurationDateAndDimensions() async throws {
        let (dir, index) = try makeWorld()
        let movie = dir.appendingPathComponent("clip.mov")
        try await TestFixtures.writeQuickTimeMovie(
            at: movie, duration: 1.0, width: 64, height: 48,
            creationDate: "2026-03-08T13:56:58-0300")
        try upsertVideoRow(index, path: movie.path)

        let count = await VideoMetadataEnricher().enrich(index: index)

        #expect(count == 1)
        let item = try #require(try index.item(forPath: movie.path))
        let duration = try #require(item.duration)
        #expect(abs(duration - 1.0) < 0.35)
        #expect(item.width == 64)
        #expect(item.height == 48)
        // 13:56:58 at -0300 == 16:56:58 UTC
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let taken = try #require(item.dateTaken)
        #expect(abs(taken.timeIntervalSince(expected)) < 1)
    }

    @Test func corruptVideoGetsSentinelAndIsNotRetried() async throws {
        let (dir, index) = try makeWorld()
        let bad = dir.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: bad)
        try upsertVideoRow(index, path: bad.path)

        let first = await VideoMetadataEnricher().enrich(index: index)
        #expect(first == 1)
        #expect(try #require(try index.item(forPath: bad.path)).duration == -1)

        let second = await VideoMetadataEnricher().enrich(index: index)
        #expect(second == 0)   // sentinel excludes it from the pending query
    }

    @Test func enrichedVideoIsNotReprocessed() async throws {
        let (dir, index) = try makeWorld()
        let movie = dir.appendingPathComponent("clip.mov")
        try await TestFixtures.writeQuickTimeMovie(at: movie, duration: 1.0,
                                                   creationDate: "2026-03-08T13:56:58-0300")
        try upsertVideoRow(index, path: movie.path)
        _ = await VideoMetadataEnricher().enrich(index: index)
        let second = await VideoMetadataEnricher().enrich(index: index)
        #expect(second == 0)
    }

    @Test func imagesAreNeverPending() throws {
        let (_, index) = try makeWorld()
        try index.upsert(MediaItem(path: "/x/photo.jpg", hash: "h", dateTaken: nil,
                                   fileType: "image", width: 10, height: 10,
                                   lastScanned: Date()))
        #expect(try index.videosNeedingEnrichment().isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `make test-one NAME=VideoMetadataEnricherTests`
Expected: COMPILE ERROR — `cannot find 'VideoMetadataEnricher' in scope`.

- [ ] **Step 3: Implement**

Add to `Sources/PhlookCore/MediaIndex.swift`:

```swift
    /// Video rows the enricher still needs: never tried (duration NULL), or
    /// date missing on a readable video. The -1 unreadable sentinel is excluded.
    public func videosNeedingEnrichment() throws -> [MediaItem] {
        try dbQueue.read { db in
            try MediaItem.fetchAll(db, sql: """
                SELECT * FROM files
                WHERE file_type = 'video'
                  AND (duration IS NULL OR (date_taken IS NULL AND duration >= 0))
            """)
        }
    }
```

Create `Sources/PhlookCore/VideoMetadataEnricher.swift`:

```swift
import Foundation
import AVFoundation

/// Fills duration, capture date, and pixel dimensions for video rows the
/// scanner could not populate. Sequential by design — it runs behind the
/// indexing chip and must not saturate I/O. A per-file failure marks the row
/// with the -1 sentinel and never aborts the batch.
public struct VideoMetadataEnricher {
    public init() {}

    @discardableResult
    public func enrich(index: MediaIndex) async -> Int {
        let pending = (try? index.videosNeedingEnrichment()) ?? []
        var processed = 0
        for var item in pending {
            let url = URL(fileURLWithPath: item.path)
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.isNumeric {
                item.duration = max(0, CMTimeGetSeconds(duration))
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    item.width = Int(abs(rect.width).rounded())
                    item.height = Int(abs(rect.height).rounded())
                }
                if item.dateTaken == nil {
                    item.dateTaken = await CaptureDateExtractor().captureDate(for: url).date
                }
            } else {
                item.duration = -1   // unreadable: tried, don't retry
            }
            item.lastScanned = Date()
            try? index.upsert(item)
            processed += 1
        }
        return processed
    }
}
```

Add to `Sources/PhlookCore/IndexingService.swift`:

```swift
    /// Post-scan pass: fill video duration/date/dimensions in the background.
    @discardableResult
    public func enrichVideos() async -> Int {
        await VideoMetadataEnricher().enrich(index: index)
    }
```

- [ ] **Step 4: Run to verify GREEN, then the full suite**

Run: `make test-one NAME=VideoMetadataEnricherTests` — 4 PASS.
Run: `make test` — all green, warning-free.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/VideoMetadataEnricher.swift Sources/PhlookCore/MediaIndex.swift Sources/PhlookCore/IndexingService.swift Tests/PhlookCoreTests/VideoMetadataEnricherTests.swift
git commit -m "feat: VideoMetadataEnricher — background duration/date/dimensions for videos

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: ViewerMath + MediaDetails (pure viewer logic, PhlookCore)

**Files:**
- Create: `Sources/PhlookCore/ViewerMath.swift`
- Create: `Sources/PhlookCore/MediaDetails.swift`
- Test: `Tests/PhlookCoreTests/ViewerMathTests.swift` (create), `Tests/PhlookCoreTests/MediaDetailsTests.swift` (create)

**Interfaces:**
- Consumes: `MediaItem` (with `duration` from Task 1), `DurationFormatter` (Task 2).
- Produces: `ViewerMath.clamp(_ i: Int, count: Int) -> Int`; `ViewerMath.positionString(index: Int, count: Int) -> String` ("3 of 10", 1-based); `ViewerMath.resolveIndex(path: String, in items: [MediaItem]) -> Int?`. `MediaDetails` struct with `filename`, `dateTaken: String` ("Unknown" when nil), `dimensions: String?` ("4032 × 3024"), `duration: String?`, `fileSize: String?` (nil when file missing), `kind: String`, `path: String`; built via `MediaDetails.from(item: MediaItem) -> MediaDetails`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/ViewerMathTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct ViewerMathTests {
    func item(_ path: String) -> MediaItem {
        MediaItem(path: path, hash: nil, dateTaken: nil, fileType: "image",
                  width: nil, height: nil, lastScanned: Date())
    }

    @Test func clampStaysInsideBounds() {
        #expect(ViewerMath.clamp(-1, count: 10) == 0)
        #expect(ViewerMath.clamp(0, count: 10) == 0)
        #expect(ViewerMath.clamp(5, count: 10) == 5)
        #expect(ViewerMath.clamp(10, count: 10) == 9)
    }

    @Test func positionStringIsOneBased() {
        #expect(ViewerMath.positionString(index: 2, count: 10) == "3 of 10")
    }

    @Test func resolveIndexFindsByPathOrNil() {
        let items = [item("/a"), item("/b"), item("/c")]
        #expect(ViewerMath.resolveIndex(path: "/b", in: items) == 1)
        #expect(ViewerMath.resolveIndex(path: "/gone", in: items) == nil)
    }
}
```

Create `Tests/PhlookCoreTests/MediaDetailsTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct MediaDetailsTests {
    @Test func assemblesVideoDetailsFromRealFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("2026-03-08_13-56-58_CLIP.MOV")
        try Data(count: 2048).write(to: url)

        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let item = MediaItem(path: url.path, hash: nil, dateTaken: date, fileType: "video",
                             width: 1920, height: 1080, lastScanned: Date(), duration: 754)
        let d = MediaDetails.from(item: item)

        #expect(d.filename == "2026-03-08_13-56-58_CLIP.MOV")
        #expect(d.dimensions == "1920 × 1080")
        #expect(d.duration == "12:34")
        #expect(d.kind == "QuickTime movie")
        #expect(d.fileSize != nil)      // real 2KB file on disk
        #expect(d.path == url.path)
        #expect(d.dateTaken != "Unknown")
    }

    @Test func imageWithNoMetadataShowsUnknowns() {
        let item = MediaItem(path: "/nowhere/missing.heic", hash: nil, dateTaken: nil,
                             fileType: "image", width: nil, height: nil, lastScanned: Date())
        let d = MediaDetails.from(item: item)
        #expect(d.dateTaken == "Unknown")
        #expect(d.dimensions == nil)
        #expect(d.duration == nil)
        #expect(d.fileSize == nil)      // file doesn't exist
        #expect(d.kind == "HEIC image")
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `make test-one NAME=ViewerMathTests`
Expected: COMPILE ERROR — `cannot find 'ViewerMath' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/PhlookCore/ViewerMath.swift`:

```swift
import Foundation

public enum ViewerMath {
    public static func clamp(_ i: Int, count: Int) -> Int {
        max(0, min(count - 1, i))
    }

    public static func positionString(index: Int, count: Int) -> String {
        "\(index + 1) of \(count)"
    }

    public static func resolveIndex(path: String, in items: [MediaItem]) -> Int? {
        items.firstIndex { $0.path == path }
    }
}
```

Create `Sources/PhlookCore/MediaDetails.swift`:

```swift
import Foundation

/// Display-ready metadata for the viewer sidebar. Pure assembly — no UI.
public struct MediaDetails: Equatable {
    public let filename: String
    public let dateTaken: String    // formatted, or "Unknown"
    public let dimensions: String?  // "4032 × 3024"
    public let duration: String?    // formatted, videos only
    public let fileSize: String?    // "2.4 MB"; nil when the file is missing
    public let kind: String         // "HEIC image", "QuickTime movie", …
    public let path: String

    static let kindByExtension: [String: String] = [
        "jpg": "JPEG image", "jpeg": "JPEG image", "heic": "HEIC image",
        "heif": "HEIF image", "png": "PNG image", "tiff": "TIFF image",
        "gif": "GIF image", "webp": "WebP image", "dng": "RAW (DNG) image",
        "mov": "QuickTime movie", "mp4": "MPEG-4 movie", "m4v": "MPEG-4 movie",
        "avi": "AVI movie",
    ]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func from(item: MediaItem) -> MediaDetails {
        let url = URL(fileURLWithPath: item.path)
        let ext = url.pathExtension.lowercased()
        let kind = kindByExtension[ext]
            ?? "\(ext.uppercased()) \(item.fileType == "video" ? "movie" : "image")"

        var sizeText: String?
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.size] as? Int64 {
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        var dims: String?
        if let w = item.width, let h = item.height { dims = "\(w) × \(h)" }

        return MediaDetails(
            filename: url.lastPathComponent,
            dateTaken: item.dateTaken.map { dateFormatter.string(from: $0) } ?? "Unknown",
            dimensions: dims,
            duration: item.fileType == "video" ? DurationFormatter.string(seconds: item.duration) : nil,
            fileSize: sizeText,
            kind: kind,
            path: item.path
        )
    }
}
```

- [ ] **Step 4: Run to verify GREEN, then the full suite**

Run: `make test-one NAME=ViewerMathTests` and `make test-one NAME=MediaDetailsTests` — all PASS.
Run: `make test` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/ViewerMath.swift Sources/PhlookCore/MediaDetails.swift Tests/PhlookCoreTests/ViewerMathTests.swift Tests/PhlookCoreTests/MediaDetailsTests.swift
git commit -m "feat: ViewerMath + MediaDetails — testable viewer logic

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: View model viewer state + grid additions (badge, ▶, double-click, context menu)

**Files:**
- Modify: `Sources/Phlook/LibraryViewModel.swift`
- Modify: `Sources/Phlook/MicroGridView.swift`

**Interfaces:**
- Consumes: `ViewerMath` (Task 4), `DurationFormatter` (Task 2), `IndexingService.enrichVideos()` (Task 3).
- Produces (Task 6/7 rely on these exact members): `vm.viewerIndex: Int?`, `vm.sidebarOpen: Bool`, `vm.openViewer(_ item: MediaItem, withSidebar: Bool = false)`, `vm.closeViewer()`, `vm.step(_ delta: Int)`, `vm.currentItem: MediaItem?`.

No unit tests (app target); verification is `swift build` + `make test` regression + smoke.

- [ ] **Step 1: Update LibraryViewModel**

Replace `Sources/Phlook/LibraryViewModel.swift` with:

```swift
import SwiftUI
import PhlookCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isIndexing = false
    @Published var viewerIndex: Int?
    @Published var sidebarOpen = false
    let service: IndexingService

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/PHLOOK")
        service = IndexingService(root: root)
    }

    var currentItem: MediaItem? {
        guard let i = viewerIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    func load() {
        let service = self.service
        isIndexing = true
        Task.detached {
            // 1. Show whatever is already indexed immediately — instant on relaunch.
            let cached = (try? service.items()) ?? []
            await MainActor.run { self.refreshItems(cached) }

            // 2. Refresh the index in the background, then update the grid.
            _ = try? service.reindex()
            let fresh = (try? service.items()) ?? []
            await MainActor.run { self.refreshItems(fresh) }

            // 3. Fill video duration/date/dimensions, then refresh once more.
            let enriched = await service.enrichVideos()
            if enriched > 0 {
                let final = (try? service.items()) ?? []
                await MainActor.run { self.refreshItems(final) }
            }
            await MainActor.run { self.isIndexing = false }
        }
    }

    /// Swap the items array while keeping the open viewer anchored to the same
    /// file (re-resolved by path). If the file vanished, the viewer closes.
    private func refreshItems(_ new: [MediaItem]) {
        let openPath = currentItem?.path
        items = new
        if let openPath {
            viewerIndex = ViewerMath.resolveIndex(path: openPath, in: new)
        }
    }

    func openViewer(_ item: MediaItem, withSidebar: Bool = false) {
        viewerIndex = ViewerMath.resolveIndex(path: item.path, in: items)
        if withSidebar { sidebarOpen = true }
    }

    func closeViewer() { viewerIndex = nil }

    func step(_ delta: Int) {
        guard let i = viewerIndex, !items.isEmpty else { return }
        viewerIndex = ViewerMath.clamp(i + delta, count: items.count)
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: 160) else { return nil }
        return NSImage(contentsOf: url)
    }
}
```

- [ ] **Step 2: Update ThumbCell in MicroGridView.swift**

Replace the `ThumbCell` struct with:

```swift
struct ThumbCell: View {
    let item: MediaItem
    let vm: LibraryViewModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 80, height: 80)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if item.fileType == "video",
               let text = DurationFormatter.string(seconds: item.duration) {
                Text(text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if item.fileType == "video" {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { vm.openViewer(item) })
        .contextMenu {
            Button("Open") { vm.openViewer(item) }
            Button("View Details") { vm.openViewer(item, withSidebar: true) }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
        .task { image = await vm.thumbnail(for: item) }
    }
}
```

(`import PhlookCore` is already present in this file; `NSWorkspace` needs `import AppKit` — add it if the compiler asks.)

- [ ] **Step 3: Build + regression**

Run: `swift build 2>&1 | tail -3` — `Build complete!`
Run: `make test` — all green (nothing in Core changed).

- [ ] **Step 4: Smoke (badges + menu only — viewer arrives in Task 6)**

`make app && open ./Phlook.app`. Wait for the enrichment pass to fill some durations (first run over ~5,900 videos takes minutes; badges appear after it finishes and the grid refreshes). Verify: duration badges + ▶ on video cells; right-click shows the three items; Show in Finder works; double-click does nothing visible yet (state only) — expected until Task 6.

- [ ] **Step 5: Commit**

```bash
git add Sources/Phlook/LibraryViewModel.swift Sources/Phlook/MicroGridView.swift
git commit -m "feat: grid duration badges, video glyph, double-click + context menu, viewer state

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: ViewerView overlay — media display, playback, navigation

**Files:**
- Create: `Sources/Phlook/ViewerView.swift`
- Create: `Sources/Phlook/ViewerInputMonitor.swift`
- Modify: `Sources/Phlook/ContentView.swift`

**Interfaces:**
- Consumes: `vm.viewerIndex/currentItem/step/closeViewer/sidebarOpen` (Task 5), `ViewerMath.positionString` (Task 4).
- Produces: full-window viewer overlay; Task 7 adds the sidebar into the `sidebarHost` slot marked below.

- [ ] **Step 1: Create ViewerInputMonitor.swift**

```swift
import AppKit

/// Local event monitor active only while the viewer is open.
/// Keys: ← → navigate, Esc closes, ⌘I toggles the sidebar.
/// Trackpad: horizontal two-finger swipe navigates (threshold + debounce).
@MainActor
final class ViewerInputMonitor {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    var onEscape: () -> Void = {}
    var onToggleSidebar: () -> Void = {}

    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var lastSwipe = Date.distantPast

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "i" {
                    self.onToggleSidebar(); return nil
                }
                switch event.keyCode {
                case 123: self.onLeft(); return nil    // ←
                case 124: self.onRight(); return nil   // →
                case 53:  self.onEscape(); return nil  // Esc
                default:  return event
                }
            case .scrollWheel:
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                self.accumulatedX += event.scrollingDeltaX
                if abs(self.accumulatedX) > 60,
                   Date().timeIntervalSince(self.lastSwipe) > 0.35 {
                    // Natural scrolling: swipe left (content moves left) → next item.
                    (self.accumulatedX > 0 ? self.onLeft : self.onRight)()
                    self.lastSwipe = Date()
                    self.accumulatedX = 0
                }
                if event.phase == .ended || event.momentumPhase == .ended {
                    self.accumulatedX = 0
                }
                return nil   // viewer swallows scroll; the grid must not move underneath
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
```

- [ ] **Step 2: Create ViewerView.swift**

```swift
import SwiftUI
import AVKit
import PhlookCore

struct ViewerView: View {
    @ObservedObject var vm: LibraryViewModel
    @State private var monitor = ViewerInputMonitor()
    @State private var player: AVPlayer?
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
            chevrons
            topBar
        }
        .overlay(alignment: .trailing) { sidebarHost }   // Task 7 fills this
        .onAppear {
            monitor.onLeft = { vm.step(-1) }
            monitor.onRight = { vm.step(+1) }
            monitor.onEscape = { vm.closeViewer() }
            monitor.onToggleSidebar = { vm.sidebarOpen.toggle() }
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
            player?.pause()
        }
        .task(id: vm.viewerIndex) { await loadCurrent() }
    }

    @ViewBuilder private var sidebarHost: some View {
        EmptyView()   // replaced by DetailsSidebar in Task 7
    }

    @ViewBuilder private var media: some View {
        if missing {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.square.dashed").font(.largeTitle)
                Text("File is missing on disk").foregroundStyle(.secondary)
            }
        } else if let player {
            VideoPlayer(player: player)
        } else if let image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            ProgressView()
        }
    }

    private var chevrons: some View {
        HStack {
            Button { vm.step(-1) } label: { chevron("chevron.left") }
                .disabled(vm.viewerIndex == 0)
            Spacer()
            Button { vm.step(+1) } label: { chevron("chevron.right") }
                .disabled(vm.viewerIndex == vm.items.count - 1)
        }
        .padding(.horizontal, 16)
        .buttonStyle(.plain)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title)
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.35), in: Circle())
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 12) {
                Button { vm.closeViewer() } label: {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if let item = vm.currentItem {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .foregroundStyle(.white).lineLimit(1)
                    if let i = vm.viewerIndex {
                        Text(ViewerMath.positionString(index: i, count: vm.items.count))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                Button { vm.sidebarOpen.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(12)
            .background(.black.opacity(0.35))
            Spacer()
        }
    }

    private func loadCurrent() async {
        player?.pause()
        player = nil
        image = nil
        missing = false
        guard let item = vm.currentItem else { return }
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: item.path) else {
            missing = true
            return
        }
        if item.fileType == "video" {
            player = AVPlayer(url: url)
        } else {
            let maxPixel = (NSScreen.main.map { $0.frame.width * $0.backingScaleFactor } ?? 2560) * 2
            image = await Task.detached {
                Self.downsampledImage(at: url, maxPixel: maxPixel)
            }.value
        }
    }

    /// Decode at bounded size so 48MP HEICs don't balloon memory.
    nonisolated static func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
```

- [ ] **Step 3: Wire the overlay in ContentView.swift**

Replace `Sources/Phlook/ContentView.swift` with:

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    var body: some View {
        ZStack {
            MicroGridView(vm: vm)
            if vm.viewerIndex != nil {
                ViewerView(vm: vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.viewerIndex != nil)
        .onAppear { vm.load() }
    }
}
```

- [ ] **Step 4: Build + regression**

Run: `swift build 2>&1 | tail -3` — `Build complete!`
Run: `make test` — all green.

- [ ] **Step 5: Smoke**

`make app && open ./Phlook.app`:
- Double-click a photo → fills the window, sharp, dark backdrop; Esc and ✕ both close.
- Double-click a video → plays with native controls (scrub, volume).
- ← / → keys, chevron clicks, and two-finger horizontal swipe all navigate; first/last item clamps (chevron disables). **If swipe direction feels inverted, flip the ternary in ViewerInputMonitor's scrollWheel branch and note it in your report.**
- Navigating from a playing video stops its audio.
- "N of M" and filename correct in the top bar.

- [ ] **Step 6: Commit**

```bash
git add Sources/Phlook/ViewerView.swift Sources/Phlook/ViewerInputMonitor.swift Sources/Phlook/ContentView.swift
git commit -m "feat: full-window viewer — image display, video playback, keys/chevrons/swipe navigation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Details sidebar

**Files:**
- Create: `Sources/Phlook/DetailsSidebar.swift`
- Modify: `Sources/Phlook/ViewerView.swift` (fill the `sidebarHost` slot)

**Interfaces:**
- Consumes: `MediaDetails.from(item:)` (Task 4), `vm.sidebarOpen` (Task 5).

- [ ] **Step 1: Create DetailsSidebar.swift**

```swift
import SwiftUI
import PhlookCore

struct DetailsSidebar: View {
    let item: MediaItem
    private var details: MediaDetails { .from(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(details.filename).font(.headline).lineLimit(2)
            row("Date taken", details.dateTaken)
            if let dims = details.dimensions { row("Dimensions", dims) }
            if let dur = details.duration { row("Duration", dur) }
            if let size = details.fileSize { row("Size", size) }
            row("Kind", details.kind)
            VStack(alignment: .leading, spacing: 4) {
                Text("Path").font(.caption).foregroundStyle(.secondary)
                Text(details.path)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .lineLimit(4)
                HStack {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: details.path)])
                    }
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
```

- [ ] **Step 2: Fill the sidebarHost slot in ViewerView.swift**

Replace the `sidebarHost` computed property with:

```swift
    @ViewBuilder private var sidebarHost: some View {
        if vm.sidebarOpen, let item = vm.currentItem {
            DetailsSidebar(item: item)
                .transition(.move(edge: .trailing))
        }
    }
```

and add `.animation(.easeInOut(duration: 0.2), value: vm.sidebarOpen)` to the ViewerView's outer `ZStack` modifier chain (after the `.overlay(alignment: .trailing)` line).

- [ ] **Step 3: Build + regression**

Run: `swift build 2>&1 | tail -3` — `Build complete!`
Run: `make test` — all green.

- [ ] **Step 4: Full-feature smoke checklist**

`make app && open ./Phlook.app`:
1. Video cells show duration badges + ▶ (after enrichment completes; check the grid is now chronologically mixed — videos no longer clumped at the end).
2. Right-click → Open opens the viewer; View Details opens it with the sidebar already out; Show in Finder reveals the file.
3. In the viewer: ⓘ and ⌘I slide the sidebar in/out; contents correct for both a photo (no duration row) and a video (duration row); Copy Path puts the full path on the clipboard; sidebar stays open while navigating prev/next and updates content.
4. Esc still closes the viewer with the sidebar open.

- [ ] **Step 5: Commit**

```bash
git add Sources/Phlook/DetailsSidebar.swift Sources/Phlook/ViewerView.swift
git commit -m "feat: pull-open details sidebar with metadata, copy path, show in Finder

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification checklist (after all tasks)

- [ ] `make test` — all green (35 pre-existing + ~19 new), warning-free.
- [ ] Full smoke checklist from Task 7 Step 4 passes on the real library.
- [ ] Grid chronology: videos interleaved with photos by date after backfill.
