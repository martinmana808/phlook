# phlook-ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `phlook-ingest` CLI that renames media in `~/Pictures/PHLOOK_staging` to `YYYY-MM-DD_HH-MM-SS_OriginalName.ext` (dates from EXIF/QuickTime metadata) and moves it into `~/Pictures/PHLOOK`, never overwriting, reporting everything.

**Architecture:** Three new units in `PhlookCore` (`CaptureDate`+`CaptureDateExtractor` for metadata dates, `IngestService`+`IngestReport` for the rename/move pipeline) plus a thin executable target `phlook-ingest`. Spec: `docs/superpowers/specs/2026-07-02-phlook-ingest-design.md`.

**Tech Stack:** Swift 5.10 SPM, swift-testing (NOT XCTest — CLT-only machine), ImageIO, AVFoundation (modern async `load(_:)` API only — the deprecated sync accessors are why AVFoundation was previously deferred).

## Global Constraints

- Tests run ONLY via `make test` / `make test-one NAME=X` (bare `swift test` silently finds 0 tests on this CLT-only machine).
- Test framework is swift-testing: `import Testing`, `@Test`, `#expect`, `#require`. Never XCTest.
- macOS 14 minimum, tools version 5.10 (do not bump).
- Files are moved byte-identical — rename only, never rewrite content.
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Existing tests (11) must stay green after every task.

---

### Task 1: TestFixtures — JPEG fixtures with an embedded EXIF capture date

**Files:**
- Modify: `Sources/PhlookCore/TestSupport.swift`
- Test: `Tests/PhlookCoreTests/TestFixturesTests.swift` (create)

**Interfaces:**
- Produces: `TestFixtures.writeJPEG(at:width:height:captureDate:)` — new optional `captureDate: Date? = nil` last parameter; when set, the JPEG carries EXIF `DateTimeOriginal`. Existing 3-argument call sites keep compiling unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/PhlookCoreTests/TestFixturesTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct TestFixturesTests {
    @Test func jpegFixtureEmbedsExifCaptureDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dated.jpg")

        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 8
        comps.hour = 13; comps.minute = 56; comps.second = 58
        let date = try #require(Calendar.current.date(from: comps))

        try TestFixtures.writeJPEG(at: url, width: 32, height: 32, captureDate: date)

        // LibraryScanner.imageMeta reads EXIF DateTimeOriginal — reuse it as the oracle.
        let (_, _, readBack) = LibraryScanner.imageMeta(url)
        #expect(readBack == date)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-one NAME=TestFixturesTests`
Expected: COMPILE ERROR — `extra argument 'captureDate' in call`. A compile failure of the new test is the valid "red" here.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PhlookCore/TestSupport.swift`, change the `writeJPEG` signature and the `CGImageDestinationAddImage` call:

```swift
public static func writeJPEG(at url: URL, width: Int, height: Int, captureDate: Date? = nil) throws {
```

and replace the line `CGImageDestinationAddImage(dest, cgImage, nil)` with:

```swift
var properties: CFDictionary?
if let captureDate {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: captureDate)]
    properties = [kCGImagePropertyExifDictionary: exif] as CFDictionary
}
CGImageDestinationAddImage(dest, cgImage, properties)
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `make test`
Expected: all tests PASS (11 existing + 1 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/TestSupport.swift Tests/PhlookCoreTests/TestFixturesTests.swift
git commit -m "feat: JPEG test fixtures can embed EXIF capture date

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: CaptureDate — timestamp rendering and QuickTime date-string parsing (pure logic)

**Files:**
- Create: `Sources/PhlookCore/CaptureDate.swift`
- Test: `Tests/PhlookCoreTests/CaptureDateTests.swift` (create)

**Interfaces:**
- Produces:
  - `public enum DateSource: String { case exif, videoMetadata, fileCreation }`
  - `public struct CaptureDate { let date: Date; let timeZone: TimeZone; let source: DateSource; func timestampString() -> String }` — renders `yyyy-MM-dd_HH-mm-ss` wall-clock time in `timeZone`.
  - `CaptureDate.parseQuickTime(_ s: String) -> CaptureDate?` (static) — parses QuickTime `com.apple.quicktime.creationdate` strings like `"2026-03-08T13:56:58-0300"`, preserving the embedded offset so `timestampString()` shows capture-local wall time; source is `.videoMetadata`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/CaptureDateTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct CaptureDateTests {
    @Test func timestampStringRendersWallClockInGivenTimeZone() throws {
        // 2026-03-08T13:56:58-0300 == 16:56:58 UTC
        let utc = try #require(ISO8601DateFormatter().date(from: "2026-03-08T16:56:58Z"))
        let tz = try #require(TimeZone(secondsFromGMT: -3 * 3600))
        let cd = CaptureDate(date: utc, timeZone: tz, source: .videoMetadata)
        #expect(cd.timestampString() == "2026-03-08_13-56-58")
    }

    @Test func parsesQuickTimeDateWithCompactOffset() throws {
        let cd = try #require(CaptureDate.parseQuickTime("2026-03-08T13:56:58-0300"))
        #expect(cd.timestampString() == "2026-03-08_13-56-58")
        #expect(cd.source == .videoMetadata)
    }

    @Test func parsesQuickTimeDateWithColonOffsetAndZulu() throws {
        let colon = try #require(CaptureDate.parseQuickTime("2026-03-08T13:56:58-03:00"))
        #expect(colon.timestampString() == "2026-03-08_13-56-58")
        let zulu = try #require(CaptureDate.parseQuickTime("2026-03-08T16:56:58Z"))
        #expect(zulu.timestampString() == "2026-03-08_16-56-58")
    }

    @Test func rejectsGarbageQuickTimeDate() {
        #expect(CaptureDate.parseQuickTime("not a date") == nil)
        #expect(CaptureDate.parseQuickTime("") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-one NAME=CaptureDateTests`
Expected: COMPILE ERROR — `cannot find 'CaptureDate' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PhlookCore/CaptureDate.swift`:

```swift
import Foundation

public enum DateSource: String, Equatable {
    case exif, videoMetadata, fileCreation
}

/// A capture instant plus the timezone whose wall-clock time should appear
/// in the filename. EXIF dates are wall time already (parse and render in
/// the same zone); QuickTime dates carry an explicit offset we preserve.
public struct CaptureDate: Equatable {
    public let date: Date
    public let timeZone: TimeZone
    public let source: DateSource

    public init(date: Date, timeZone: TimeZone, source: DateSource) {
        self.date = date
        self.timeZone = timeZone
        self.source = source
    }

    public func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// Parses com.apple.quicktime.creationdate values, e.g.
    /// "2026-03-08T13:56:58-0300", "2026-03-08T13:56:58-03:00", "...58Z",
    /// with optional fractional seconds.
    public static func parseQuickTime(_ s: String) -> CaptureDate? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",      // -03:00 or Z
            "yyyy-MM-dd'T'HH:mm:ssZ",          // -0300
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        ]
        for fmt in formats {
            f.dateFormat = fmt
            if let date = f.date(from: s) {
                return CaptureDate(date: date, timeZone: offsetTimeZone(from: s), source: .videoMetadata)
            }
        }
        return nil
    }

    /// Extracts the trailing UTC offset from an already-validated date string.
    static func offsetTimeZone(from s: String) -> TimeZone {
        if s.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
        // Strip colons so both "-03:00" and "-0300" end in a 5-char "-0300" tail.
        let compact = s.replacingOccurrences(of: ":", with: "")
        let tail = compact.suffix(5)
        guard let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(tail.dropFirst().prefix(2)),
              let minutes = Int(tail.suffix(2)) else { return .current }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds) ?? .current
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=CaptureDateTests`
Expected: 4 tests PASS. Then `make test` — everything green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/CaptureDate.swift Tests/PhlookCoreTests/CaptureDateTests.swift
git commit -m "feat: CaptureDate — wall-clock timestamp rendering + QuickTime date parsing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: CaptureDateExtractor — per-file date resolution (EXIF → video metadata → file creation)

**Files:**
- Create: `Sources/PhlookCore/CaptureDateExtractor.swift`
- Test: `Tests/PhlookCoreTests/CaptureDateExtractorTests.swift` (create)

**Interfaces:**
- Consumes: `CaptureDate`/`DateSource` (Task 2), `TestFixtures.writeJPEG(at:width:height:captureDate:)` (Task 1), `LibraryScanner.imageExts`/`videoExts` (existing).
- Produces: `public struct CaptureDateExtractor { init(); func captureDate(for url: URL) async -> CaptureDate }` — never throws, never returns nil; worst case falls back to file-creation date with `source == .fileCreation`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/CaptureDateExtractorTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct CaptureDateExtractorTests {
    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func exifDateWinsForImages() async throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("photo.jpg")
        var comps = DateComponents()
        comps.year = 2025; comps.month = 12; comps.day = 20
        comps.hour = 0; comps.minute = 10; comps.second = 22
        let date = try #require(Calendar.current.date(from: comps))
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16, captureDate: date)

        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .exif)
        #expect(cd.timestampString() == "2025-12-20_00-10-22")
    }

    @Test func imageWithoutExifFallsBackToFileCreation() async throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("stripped.jpg")
        try TestFixtures.writeJPEG(at: url, width: 16, height: 16) // no captureDate

        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .fileCreation)
        let birth = try #require(
            (try url.resourceValues(forKeys: [.creationDateKey])).creationDate)
        #expect(abs(cd.date.timeIntervalSince(birth)) < 1)
    }

    @Test func unreadableVideoFallsBackToFileCreation() async throws {
        // A .mov that isn't a real movie: AVFoundation can't read it, so the
        // extractor must fall through to file-creation without throwing.
        let dir = try makeDir()
        let url = dir.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: url)

        let cd = await CaptureDateExtractor().captureDate(for: url)
        #expect(cd.source == .fileCreation)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-one NAME=CaptureDateExtractorTests`
Expected: COMPILE ERROR — `cannot find 'CaptureDateExtractor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PhlookCore/CaptureDateExtractor.swift`:

```swift
import Foundation
import ImageIO
import AVFoundation

/// Resolves the capture date for a media file:
/// images: EXIF DateTimeOriginal → DateTimeDigitized → TIFF DateTime;
/// videos: com.apple.quicktime.creationdate (offset-preserving) → container creationDate;
/// both:   file creation date, flagged as .fileCreation.
public struct CaptureDateExtractor {
    public init() {}

    public func captureDate(for url: URL) async -> CaptureDate {
        let ext = url.pathExtension.lowercased()
        if LibraryScanner.imageExts.contains(ext), let cd = Self.exifDate(url) {
            return cd
        }
        if LibraryScanner.videoExts.contains(ext), let cd = await Self.videoDate(url) {
            return cd
        }
        let birth = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        return CaptureDate(date: birth, timeZone: .current, source: .fileCreation)
    }

    // EXIF dates are local wall time with no zone; parse and render in the
    // same zone (.current) so the filename reproduces the wall time exactly.
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func exifDate(_ url: URL) -> CaptureDate? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
        ]
        for case let s? in candidates {
            if let date = exifFormatter.date(from: s) {
                return CaptureDate(date: date, timeZone: .current, source: .exif)
            }
        }
        return nil
    }

    static func videoDate(_ url: URL) async -> CaptureDate? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let items = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .quickTimeMetadataCreationDate)
        if let item = items.first,
           let s = try? await item.load(.stringValue), let s,
           let cd = CaptureDate.parseQuickTime(s) {
            return cd
        }
        if let item = try? await asset.load(.creationDate),
           let d = try? await item?.load(.dateValue), let d {
            return CaptureDate(date: d, timeZone: .current, source: .videoMetadata)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=CaptureDateExtractorTests`
Expected: 3 tests PASS. Then `make test` — everything green. (The happy-path AVAsset read is covered by the manual smoke test in Task 5 — no binary video fixture is committed, per spec.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/CaptureDateExtractor.swift Tests/PhlookCoreTests/CaptureDateExtractorTests.swift
git commit -m "feat: CaptureDateExtractor — EXIF/QuickTime capture dates with file-creation fallback

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: IngestService — rename, collide-safe move, report

**Files:**
- Create: `Sources/PhlookCore/IngestService.swift`
- Test: `Tests/PhlookCoreTests/IngestServiceTests.swift` (create)

**Interfaces:**
- Consumes: `CaptureDateExtractor.captureDate(for:) async -> CaptureDate` (Task 3), `LibraryScanner.imageExts`/`videoExts` (existing).
- Produces:
  - `public struct IngestReport: Equatable` with `moved: [String]`, `skippedDuplicates: [String]`, `fallbackDated: [String]`, `unsupported: [String]`, computed `leftInStaging: [String]` and `isClean: Bool`.
  - `public enum IngestError: Error, Equatable { case stagingMissing(String) }`
  - `public struct IngestService { init(staging: URL, library: URL); func ingest() async throws -> IngestReport }`
  - `IngestService.targetName(originalName: String, timestamp: String) -> String` (static, internal) — prefixes unless the name already matches the convention.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/IngestServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct IngestServiceTests {
    struct World {
        let staging: URL
        let library: URL
        var service: IngestService { IngestService(staging: staging, library: library) }
    }

    func makeWorld() throws -> World {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = base.appendingPathComponent("staging")
        let library = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return World(staging: staging, library: library)
    }

    func fixtureDate() throws -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 4
        comps.hour = 19; comps.minute = 36; comps.second = 16
        return try #require(Calendar.current.date(from: comps))
    }

    @Test func targetNamePrefixesTimestamp() {
        #expect(IngestService.targetName(originalName: "IMG_5305.HEIC", timestamp: "2026-01-04_19-36-16")
                == "2026-01-04_19-36-16_IMG_5305.HEIC")
    }

    @Test func targetNameKeepsAlreadyConventionalNames() {
        let name = "2025-11-08_18-47-37_IMG_1.jpg"
        #expect(IngestService.targetName(originalName: name, timestamp: "2026-01-04_19-36-16") == name)
    }

    @Test func movesAndRenamesDatedImage() async throws {
        let w = try makeWorld()
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate())

        let report = try await w.service.ingest()

        #expect(report.moved == ["2026-01-04_19-36-16_IMG_1.jpg"])
        #expect(report.isClean)
        #expect(FileManager.default.fileExists(
            atPath: w.library.appendingPathComponent("2026-01-04_19-36-16_IMG_1.jpg").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.staging.path).isEmpty)
    }

    @Test func duplicateInLibraryIsSkippedAndLeftInStaging() async throws {
        let w = try makeWorld()
        let finalName = "2026-01-04_19-36-16_IMG_1.jpg"
        try Data("existing".utf8).write(to: w.library.appendingPathComponent(finalName))
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate())

        let report = try await w.service.ingest()

        #expect(report.skippedDuplicates == ["IMG_1.jpg"])
        #expect(report.moved.isEmpty)
        #expect(!report.isClean)
        // Original untouched in staging; library file NOT overwritten.
        #expect(FileManager.default.fileExists(atPath: w.staging.appendingPathComponent("IMG_1.jpg").path))
        let content = try Data(contentsOf: w.library.appendingPathComponent(finalName))
        #expect(content == Data("existing".utf8))
    }

    @Test func inBatchCollisionFirstWins() async throws {
        let w = try makeWorld()
        // Two staging files that resolve to the SAME target name: one already
        // conventional (passthrough), one renaming to that identical target.
        let clashing = "2026-01-04_19-36-16_IMG_1.jpg"
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent(clashing),
                                   width: 16, height: 16) // passthrough name
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate()) // renames to same

        let report = try await w.service.ingest()

        #expect(report.moved.count == 1)
        #expect(report.skippedDuplicates.count == 1)
        #expect(FileManager.default.fileExists(atPath: w.library.appendingPathComponent(clashing).path))
    }

    @Test func hiddenAndUnsupportedFilesAreHandled() async throws {
        let w = try makeWorld()
        try Data([0x01]).write(to: w.staging.appendingPathComponent(".osxphotos_export.db"))
        try "notes".write(to: w.staging.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)

        let report = try await w.service.ingest()

        #expect(report.unsupported == ["readme.txt"])
        #expect(report.moved.isEmpty)
        #expect(!report.isClean)
        // Hidden db never appears anywhere in the report.
        #expect(!report.leftInStaging.contains(".osxphotos_export.db"))
        #expect(FileManager.default.fileExists(atPath: w.staging.appendingPathComponent(".osxphotos_export.db").path))
    }

    @Test func emptyStagingYieldsCleanEmptyReport() async throws {
        let w = try makeWorld()
        let report = try await w.service.ingest()
        #expect(report == IngestReport())
        #expect(report.isClean)
    }

    @Test func missingStagingDirectoryThrows() async throws {
        let w = try makeWorld()
        let gone = w.staging.appendingPathComponent("nope")
        let service = IngestService(staging: gone, library: w.library)
        await #expect(throws: IngestError.stagingMissing(gone.path)) {
            _ = try await service.ingest()
        }
    }

    @Test func secondRunOverLeftoversIsIdempotent() async throws {
        let w = try makeWorld()
        try "notes".write(to: w.staging.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)
        let first = try await w.service.ingest()
        let second = try await w.service.ingest()
        #expect(first == second)
    }

    @Test func moveFailureThrowsWithPartialReportAndLeavesFileInStaging() async throws {
        let w = try makeWorld()
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("IMG_1.jpg"),
                                   width: 16, height: 16, captureDate: fixtureDate())
        // Read-only library dir forces the move to fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: w.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.library.path) }

        await #expect { _ = try await w.service.ingest() } throws: { error in
            guard case let IngestError.moveFailed(file, _, partial) = error else { return false }
            return file == "IMG_1.jpg" && partial.moved.isEmpty
        }
        #expect(FileManager.default.fileExists(atPath: w.staging.appendingPathComponent("IMG_1.jpg").path))
    }

    @Test func fallbackDatedFilesAreFlagged() async throws {
        let w = try makeWorld()
        try TestFixtures.writeJPEG(at: w.staging.appendingPathComponent("noexif.jpg"),
                                   width: 16, height: 16) // no captureDate
        let report = try await w.service.ingest()
        #expect(report.moved.count == 1)
        #expect(report.fallbackDated == report.moved)
        #expect(report.isClean) // fallback-dated still moves; it is informational
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-one NAME=IngestServiceTests`
Expected: COMPILE ERROR — `cannot find 'IngestService' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PhlookCore/IngestService.swift`:

```swift
import Foundation

public struct IngestReport: Equatable {
    public var moved: [String] = []             // final filenames now in the library
    public var skippedDuplicates: [String] = [] // original names, left in staging
    public var fallbackDated: [String] = []     // subset of moved: dated by file creation
    public var unsupported: [String] = []       // original names, left in staging

    public init() {}

    public var leftInStaging: [String] { skippedDuplicates + unsupported }
    public var isClean: Bool { skippedDuplicates.isEmpty && unsupported.isEmpty }
}

public enum IngestError: Error, Equatable {
    case stagingMissing(String)
    /// A move failed mid-batch: which file, why, and everything that had
    /// already succeeded (already-moved files STAY moved; re-running is safe).
    case moveFailed(file: String, reason: String, partial: IngestReport)
}

/// Moves supported media from a staging folder into the library, renaming to
/// YYYY-MM-DD_HH-MM-SS_OriginalName.ext. Invariant: every enumerated file is
/// either moved into the library or still in staging and named in the report.
/// Never overwrites. Content is never rewritten — same-volume rename only.
public struct IngestService {
    public let staging: URL
    public let library: URL
    private let extractor = CaptureDateExtractor()

    public init(staging: URL, library: URL) {
        self.staging = staging
        self.library = library
    }

    static func targetName(originalName: String, timestamp: String) -> String {
        let conventionPrefix = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_"#
        if originalName.range(of: conventionPrefix, options: .regularExpression) != nil {
            return originalName
        }
        return "\(timestamp)_\(originalName)"
    }

    public func ingest() async throws -> IngestReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: staging.path, isDirectory: &isDir), isDir.boolValue else {
            throw IngestError.stagingMissing(staging.path)
        }
        try fm.createDirectory(at: library, withIntermediateDirectories: true)

        // Shallow, hidden-skipping, sorted for deterministic first-wins.
        let entries = try fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var report = IngestReport()
        var claimed = Set<String>()

        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let original = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard LibraryScanner.imageExts.contains(ext) || LibraryScanner.videoExts.contains(ext) else {
                report.unsupported.append(original)
                continue
            }
            let capture = await extractor.captureDate(for: url)
            let name = Self.targetName(originalName: original, timestamp: capture.timestampString())
            let dest = library.appendingPathComponent(name)
            if claimed.contains(name) || fm.fileExists(atPath: dest.path) {
                report.skippedDuplicates.append(original)
                continue
            }
            do {
                try fm.moveItem(at: url, to: dest)
            } catch {
                throw IngestError.moveFailed(
                    file: original, reason: "\(error)", partial: report)
            }
            claimed.insert(name)
            report.moved.append(name)
            if capture.source == .fileCreation {
                report.fallbackDated.append(name)
            }
        }
        return report
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=IngestServiceTests`
Expected: 11 tests PASS. Then `make test` — everything green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/IngestService.swift Tests/PhlookCoreTests/IngestServiceTests.swift
git commit -m "feat: IngestService — collide-safe rename/move from staging into library with full report

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: phlook-ingest CLI — report text, executable target, Makefile, smoke test

**Files:**
- Create: `Sources/PhlookCore/IngestReport+Summary.swift`
- Create: `Sources/phlook-ingest/PhlookIngestMain.swift`
- Modify: `Package.swift` (add executable target)
- Modify: `Makefile` (add `ingest` target)
- Test: `Tests/PhlookCoreTests/IngestReportSummaryTests.swift` (create)

**Interfaces:**
- Consumes: `IngestService` / `IngestReport` (Task 4).
- Produces: `IngestReport.summaryText: String` (public, in PhlookCore, unit-tested); the `phlook-ingest` executable (defaults `~/Pictures/PHLOOK_staging` → `~/Pictures/PHLOOK`, positional overrides `phlook-ingest [staging] [library]`; exit 0 clean / 1 leftovers / 2 hard error); `make ingest`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/IngestReportSummaryTests.swift`:

```swift
import Testing
@testable import PhlookCore

struct IngestReportSummaryTests {
    @Test func emptyReportSaysNothingToIngest() {
        #expect(IngestReport().summaryText == "staging is empty — nothing to ingest")
    }

    @Test func cleanReportEndsWithGreenLight() {
        var r = IngestReport()
        r.moved = ["a.jpg", "b.mov"]
        let text = r.summaryText
        #expect(text.contains("moved: 2"))
        #expect(text.contains("CLEAN — safe to delete originals from the device"))
        #expect(!text.contains("NOT CLEAN"))
    }

    @Test func dirtyReportListsLeftoversAndWithholdsGreenLight() {
        var r = IngestReport()
        r.moved = ["a.jpg"]
        r.skippedDuplicates = ["dupe.jpg"]
        r.unsupported = ["notes.txt"]
        r.fallbackDated = ["a.jpg"]
        let text = r.summaryText
        #expect(text.contains("moved: 1"))
        #expect(text.contains("dupe.jpg"))
        #expect(text.contains("notes.txt"))
        #expect(text.contains("a.jpg")) // fallback-dated listing
        #expect(text.contains("NOT CLEAN"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-one NAME=IngestReportSummaryTests`
Expected: COMPILE ERROR — `value of type 'IngestReport' has no member 'summaryText'`.

- [ ] **Step 3: Implement summaryText**

Create `Sources/PhlookCore/IngestReport+Summary.swift`:

```swift
import Foundation

public extension IngestReport {
    var summaryText: String {
        if moved.isEmpty && leftInStaging.isEmpty {
            return "staging is empty — nothing to ingest"
        }
        var lines = ["✅ moved: \(moved.count)"]
        if !fallbackDated.isEmpty {
            lines.append("⚠️  dated by file-creation fallback (\(fallbackDated.count)) — capture time unknown, check names:")
            lines += fallbackDated.map { "     \($0)" }
        }
        if !skippedDuplicates.isEmpty {
            lines.append("⚠️  skipped duplicates, left in staging (\(skippedDuplicates.count)):")
            lines += skippedDuplicates.map { "     \($0)" }
        }
        if !unsupported.isEmpty {
            lines.append("⚠️  unsupported files, left in staging (\(unsupported.count)):")
            lines += unsupported.map { "     \($0)" }
        }
        lines.append(isClean
            ? "✅ CLEAN — safe to delete originals from the device"
            : "⚠️  NOT CLEAN — review the files left in staging")
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=IngestReportSummaryTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Add the executable target**

In `Package.swift`, after the `Phlook` executable target entry, add:

```swift
        .executableTarget(
            name: "phlook-ingest",
            dependencies: ["PhlookCore"]
        ),
```

Create `Sources/phlook-ingest/PhlookIngestMain.swift` (NOT `main.swift` — `@main` requires a differently-named file):

```swift
import Foundation
import PhlookCore

@main
struct PhlookIngestCLI {
    static func main() async {
        let args = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser
        let staging = args.count > 1
            ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            : home.appendingPathComponent("Pictures/PHLOOK_staging")
        let library = args.count > 2
            ? URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
            : home.appendingPathComponent("Pictures/PHLOOK")

        print("phlook-ingest: \(staging.path) → \(library.path)")
        do {
            let report = try await IngestService(staging: staging, library: library).ingest()
            print(report.summaryText)
            exit(report.isClean ? 0 : 1)
        } catch let IngestError.moveFailed(file, reason, partial) {
            print(partial.summaryText)
            FileHandle.standardError.write(
                Data("phlook-ingest: STOPPED — failed moving '\(file)': \(reason)\nAlready-moved files stay moved; fix the cause and re-run (safe).\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("phlook-ingest: error: \(error)\n".utf8))
            exit(2)
        }
    }
}
```

- [ ] **Step 6: Add the Makefile target**

In `Makefile`, extend `.PHONY` to `.PHONY: build test clean ingest` and append:

```makefile
# Ingest staged media into the library:
#   make ingest                      (~/Pictures/PHLOOK_staging → ~/Pictures/PHLOOK)
#   make ingest STAGING=/p LIBRARY=/q
ingest:
	swift run -c release phlook-ingest $(STAGING) $(LIBRARY)
```

(Note: recipe line must start with a TAB, matching the existing Makefile.)

- [ ] **Step 7: Build and run the full suite**

Run: `swift build 2>&1 | tail -5` — expected: `Build complete!`
Run: `make test` — expected: all tests PASS (existing 11 + ~20 new).

- [ ] **Step 8: End-to-end smoke test with a REAL photo and video**

Copy one real HEIC and one real MOV from the library into a temp staging dir, with un-conventional names, and ingest into a temp library (never touching the real one):

```bash
SMOKE=$(mktemp -d)
mkdir "$SMOKE/staging" "$SMOKE/library"
cp "$(find ~/Pictures/PHLOOK -name '*.HEIC' | head -1)" "$SMOKE/staging/IMG_TEST.HEIC"
cp "$(find ~/Pictures/PHLOOK -name '*.MOV' | head -1)" "$SMOKE/staging/CLIP_TEST.MOV"
swift run -c release phlook-ingest "$SMOKE/staging" "$SMOKE/library"
ls -la "$SMOKE/library"
```

Expected: exit 0; both files moved; each final name starts with a timestamp that MATCHES the timestamp already embedded in the source file's original library name (that's the oracle: osxphotos and phlook-ingest must agree on the capture date). The MOV must NOT appear under "file-creation fallback" — its date must come from video metadata. If the timestamps disagree or the MOV falls back, STOP and debug before committing (check the QuickTime date parsing against the real string first).

Cleanup: `rm -rf "$SMOKE"`.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Makefile Sources/phlook-ingest/ Sources/PhlookCore/IngestReport+Summary.swift Tests/PhlookCoreTests/IngestReportSummaryTests.swift
git commit -m "feat: phlook-ingest CLI + make ingest — one-command staged-media ingest

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification checklist (after all tasks)

- [ ] `make test` — all green, no warnings.
- [ ] `make ingest` against the real (empty) staging prints `staging is empty — nothing to ingest`, exit 0. (`.osxphotos_export.db` in real staging must not appear in the report.)
- [ ] Smoke-test evidence from Task 5 Step 8 recorded in the final report.
