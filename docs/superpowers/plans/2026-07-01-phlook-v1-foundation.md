# PHLOOK v1 Foundation ("Hello Grid") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app that scans the existing `~/Pictures/PHLOOK` folder, builds a rebuildable SQLite index + thumbnail cache, and renders the whole library in a fast virtualized micro-grid.

**Architecture:** Native SwiftUI/AppKit app (macOS only), no always-on backend. A headless, unit-tested core (index + scanner + thumbnail cache + indexing service) drives a thin SwiftUI grid. The index sits *beside* the files and is fully rebuildable from disk.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, GRDB.swift (SQLite), ImageIO + AVFoundation (metadata), QuickLookThumbnailing (thumbnails). Built and tested with **Swift Package Manager** (`swift build` / `swift test`) — **no full Xcode required**; the installed Command Line Tools suffice.

## Global Constraints

- **Platform:** macOS 14+, Apple Silicon. `Package.swift` declares `platforms: [.macOS(.v14)]`.
- **Build system:** Swift Package Manager only. Every build/test uses `swift build` / `swift test` — never `xcodebuild`.
- **Library root (default):** `~/Pictures/PHLOOK`.
- **Index location:** `~/Pictures/PHLOOK/phlook.db` (beside the library, rebuildable — never a source of truth).
- **Thumbnail cache:** `~/Pictures/PHLOOK/.phlook/thumbnails/`, keyed by file content hash.
- **View-only:** v1 MUST NOT modify, move, rename, or delete any original media file. Metadata is read-only.
- **DB schema compatibility:** the `files` table matches the existing `phlook.db` schema; do not drop/rename existing tables (`files`, `ocr_data`, `embeddings`).
- **No network:** the app makes zero network calls.
- **Tests generate their own fixtures** in temp directories (no committed binary fixtures), so the suite is hermetic.
- **Test framework:** **swift-testing** (`import Testing`, `struct` suites, `@Test func`, `#expect(...)`, `try #require(...)`) — NOT XCTest, which is absent from Command Line Tools. Test files also `import Foundation`.
- **Running tests:** full suite `make test`; single suite `make test-one NAME=<SuiteName>`. (These wrap `swift test` with the `-Xswiftc -F <CLT frameworks>` flag that swift-testing needs on CLT-only machines. Never rely on bare `swift test` — it silently discovers 0 tests here.) `Package.swift` + `Makefile` from Task 1 already encode this.

---

### Task 1: Swift Package scaffold that builds, tests, and launches

**Files:**
- Create: `Package.swift`
- Create: `Sources/PhlookCore/Version.swift`
- Create: `Sources/Phlook/PhlookApp.swift`
- Create: `Sources/Phlook/ContentView.swift`
- Create: `Tests/PhlookCoreTests/SmokeTests.swift`
- Modify: `.gitignore` (add `.build/`)

**Interfaces:**
- Produces: an SPM package with a `PhlookCore` library target (unit-testable, holds all logic), a `Phlook` executable target (the SwiftUI app), and a `PhlookCoreTests` test target.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Phlook",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "PhlookCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "Phlook",
            dependencies: ["PhlookCore"]
        ),
        .testTarget(
            name: "PhlookCoreTests",
            dependencies: ["PhlookCore"]
        ),
    ]
)
```

- [ ] **Step 2: Write core version + app entry**

`Sources/PhlookCore/Version.swift`:
```swift
public enum PhlookCore {
    public static let version = "0.1.0"
}
```

`Sources/Phlook/PhlookApp.swift`:
```swift
import SwiftUI

@main
struct PhlookApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
```

`Sources/Phlook/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("PHLOOK").font(.largeTitle)
    }
}
```

- [ ] **Step 3: Write the smoke test**

`Tests/PhlookCoreTests/SmokeTests.swift`:
```swift
import XCTest
@testable import PhlookCore

final class SmokeTests: XCTestCase {
    func testVersionExists() {
        XCTAssertEqual(PhlookCore.version, "0.1.0")
    }
}
```

- [ ] **Step 4: Build and test**

Run:
```bash
cd ~/Documents/Projects/phlook
echo ".build/" >> .gitignore
swift build
swift test
```
Expected: `swift build` compiles; `swift test` passes `testVersionExists`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "feat: scaffold Phlook SPM package (app + PhlookCore + tests)"
```

---

### Task 2: MediaItem model + SQLite index (GRDB)

**Files:**
- Create: `Sources/PhlookCore/MediaItem.swift`
- Create: `Sources/PhlookCore/MediaIndex.swift`
- Test: `Tests/PhlookCoreTests/MediaIndexTests.swift`

**Interfaces:**
- Produces:
  - `struct MediaItem: Codable, Equatable, FetchableRecord, PersistableRecord` with fields `id: Int64?`, `path: String`, `hash: String?`, `dateTaken: Date?`, `fileType: String`, `width: Int?`, `height: Int?`, `lastScanned: Date`; `databaseTableName == "files"`; `Columns.path`, `Columns.dateTaken`.
  - `final class MediaIndex { init(dbPath: String) throws; func upsert(_ item: MediaItem) throws; func allItems(sortedByDateDescending: Bool) throws -> [MediaItem]; func item(forPath: String) throws -> MediaItem?; func deleteMissing(keepingPaths: Set<String>) throws; func count() throws -> Int }`

- [ ] **Step 1: Write the failing test**

`Tests/PhlookCoreTests/MediaIndexTests.swift`:
```swift
import Testing
import Foundation
@testable import PhlookCore

struct MediaIndexTests {
    func makeTempIndex() throws -> MediaIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MediaIndex(dbPath: dir.appendingPathComponent("phlook.db").path)
    }

    @Test func upsertAndFetch() throws {
        let index = try makeTempIndex()
        let item = MediaItem(path: "/a/b/2024-01-02_03-04-05_IMG.heic", hash: "abc",
                             dateTaken: Date(timeIntervalSince1970: 1_700_000_000),
                             fileType: "image", width: 100, height: 200, lastScanned: Date())
        try index.upsert(item)
        let count = try index.count()
        #expect(count == 1)
        let fetched = try index.item(forPath: item.path)
        #expect(fetched?.width == 100)
    }

    @Test func upsertIsIdempotentOnPath() throws {
        let index = try makeTempIndex()
        var item = MediaItem(path: "/x.heic", hash: "1", dateTaken: nil,
                             fileType: "image", width: 1, height: 1, lastScanned: Date())
        try index.upsert(item)
        item.width = 999
        try index.upsert(item)
        let count = try index.count()
        #expect(count == 1)
        let fetched = try index.item(forPath: "/x.heic")
        #expect(fetched?.width == 999)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-one NAME=MediaIndexTests`
Expected: FAIL — `MediaIndex`/`MediaItem` undefined (compile error).

- [ ] **Step 3: Write the model**

`Sources/PhlookCore/MediaItem.swift`:
```swift
import Foundation
import GRDB

public struct MediaItem: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var path: String
    public var hash: String?
    public var dateTaken: Date?
    public var fileType: String   // "image" | "video"
    public var width: Int?
    public var height: Int?
    public var lastScanned: Date

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
    }

    public init(id: Int64? = nil, path: String, hash: String?, dateTaken: Date?,
                fileType: String, width: Int?, height: Int?, lastScanned: Date) {
        self.id = id; self.path = path; self.hash = hash; self.dateTaken = dateTaken
        self.fileType = fileType; self.width = width; self.height = height
        self.lastScanned = lastScanned
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 4: Write the index**

`Sources/PhlookCore/MediaIndex.swift`:
```swift
import Foundation
import GRDB

public final class MediaIndex {
    private let dbQueue: DatabaseQueue

    public init(dbPath: String) throws {
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrate()
    }

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
                    last_scanned TEXT
                );
            """)
        }
    }

    public func upsert(_ item: MediaItem) throws {
        try dbQueue.write { db in
            if var existing = try MediaItem.filter(MediaItem.Columns.path == item.path).fetchOne(db) {
                existing.hash = item.hash
                existing.dateTaken = item.dateTaken
                existing.fileType = item.fileType
                existing.width = item.width
                existing.height = item.height
                existing.lastScanned = item.lastScanned
                try existing.update(db)
            } else {
                var new = item
                try new.insert(db)
            }
        }
    }

    public func item(forPath path: String) throws -> MediaItem? {
        try dbQueue.read { db in
            try MediaItem.filter(MediaItem.Columns.path == path).fetchOne(db)
        }
    }

    public func allItems(sortedByDateDescending desc: Bool = true) throws -> [MediaItem] {
        try dbQueue.read { db in
            let order = desc ? MediaItem.Columns.dateTaken.desc : MediaItem.Columns.dateTaken.asc
            return try MediaItem.order(order).fetchAll(db)
        }
    }

    public func deleteMissing(keepingPaths paths: Set<String>) throws {
        try dbQueue.write { db in
            for item in try MediaItem.fetchAll(db) where !paths.contains(item.path) {
                try item.delete(db)
            }
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in try MediaItem.fetchCount(db) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test-one NAME=MediaIndexTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/MediaItem.swift Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/MediaIndexTests.swift
git commit -m "feat: MediaItem model + rebuildable SQLite index"
```

---

### Task 3: LibraryScanner — find media + extract metadata

**Files:**
- Create: `Sources/PhlookCore/LibraryScanner.swift`
- Create: `Sources/PhlookCore/TestSupport.swift` (fixture helpers, compiled into the framework so tests can generate media)
- Test: `Tests/PhlookCoreTests/LibraryScannerTests.swift`

**Interfaces:**
- Consumes: `MediaItem` from Task 2.
- Produces:
  - `struct LibraryScanner { init(root: URL); func scan() throws -> [MediaItem] }` — walks `root`, one `MediaItem` per supported media file with `fileType`, `width`, `height`, `dateTaken` (EXIF/AVAsset, falling back to file creation date), and a content `hash`.
  - `public enum TestFixtures { static func writeJPEG(at url: URL, width: Int, height: Int) throws }` — writes a real JPEG so tests need no committed binaries.

- [ ] **Step 1: Write the fixture helper**

`Sources/PhlookCore/TestSupport.swift`:
```swift
import Foundation
import AppKit

public enum TestFixtures {
    public static func writeJPEG(at url: URL, width: Int, height: Int) throws {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            throw NSError(domain: "TestFixtures", code: 1)
        }
        try jpeg.write(to: url)
    }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/PhlookCoreTests/LibraryScannerTests.swift`:
```swift
import Testing
import Foundation
@testable import PhlookCore

struct LibraryScannerTests {
    func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: dir.appendingPathComponent("sample.jpg"), width: 64, height: 48)
        try "hello".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func scanFindsImageWithDimensions() throws {
        let items = try LibraryScanner(root: makeRoot()).scan()
        let image = try #require(items.first { $0.path.hasSuffix("sample.jpg") })
        #expect(image.fileType == "image")
        #expect(image.width == 64)
        #expect(image.height == 48)
        #expect(image.hash != nil)
        #expect(image.dateTaken != nil) // falls back to file creation date
    }

    @Test func scanIgnoresNonMedia() throws {
        let items = try LibraryScanner(root: makeRoot()).scan()
        #expect(!items.contains { $0.path.hasSuffix(".txt") })
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `make test-one NAME=LibraryScannerTests`
Expected: FAIL — `LibraryScanner` undefined.

- [ ] **Step 4: Write the scanner**

`Sources/PhlookCore/LibraryScanner.swift`:
```swift
import Foundation
import ImageIO
import AVFoundation
import CryptoKit

public struct LibraryScanner {
    public let root: URL
    public init(root: URL) { self.root = root }

    static let imageExts: Set<String> = ["jpg","jpeg","heic","heif","png","tiff","gif","webp","dng"]
    static let videoExts: Set<String> = ["mov","mp4","m4v","avi"]

    public func scan() throws -> [MediaItem] {
        var results: [MediaItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            let isImage = Self.imageExts.contains(ext)
            let isVideo = Self.videoExts.contains(ext)
            guard isImage || isVideo else { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            let (w, h, taken) = isImage ? Self.imageMeta(url) : Self.videoMeta(url)
            let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
            results.append(MediaItem(
                path: url.path, hash: Self.quickHash(url),
                dateTaken: taken ?? fileDate,
                fileType: isImage ? "image" : "video",
                width: w, height: h, lastScanned: Date()))
        }
        return results
    }

    static func imageMeta(_ url: URL) -> (Int?, Int?, Date?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil) }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            date = f.date(from: s)
        }
        return (w, h, date)
    }

    static func videoMeta(_ url: URL) -> (Int?, Int?, Date?) {
        let asset = AVURLAsset(url: url)
        let size = asset.tracks(withMediaType: .video).first?.naturalSize
        return (size.map { Int($0.width) }, size.map { Int($0.height) }, asset.creationDate?.dateValue)
    }

    static func quickHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1_048_576)) ?? Data()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var hasher = SHA256()
        hasher.update(data: data)
        withUnsafeBytes(of: size) { hasher.update(data: Data($0)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test-one NAME=LibraryScannerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhlookCore/LibraryScanner.swift Sources/PhlookCore/TestSupport.swift Tests/PhlookCoreTests/LibraryScannerTests.swift
git commit -m "feat: LibraryScanner extracts media metadata + quick hash"
```

---

### Task 4: ThumbnailCache — generate + cache on disk

**Files:**
- Create: `Sources/PhlookCore/ThumbnailCache.swift`
- Test: `Tests/PhlookCoreTests/ThumbnailCacheTests.swift`

**Interfaces:**
- Consumes: `MediaItem` (Task 2), `TestFixtures` (Task 3).
- Produces: `final class ThumbnailCache { init(cacheDir: URL); func thumbnailURL(for item: MediaItem, size: Int) async -> URL? }` — returns a cached PNG URL, generating via `QLThumbnailGenerator` on a miss; filename `<hash>_<size>.png`.

- [ ] **Step 1: Write the failing test**

`Tests/PhlookCoreTests/ThumbnailCacheTests.swift`:
```swift
import Testing
import Foundation
@testable import PhlookCore

struct ThumbnailCacheTests {
    @Test func generatesAndCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jpeg = root.appendingPathComponent("pic.jpg")
        try TestFixtures.writeJPEG(at: jpeg, width: 200, height: 200)

        let cache = ThumbnailCache(cacheDir: root.appendingPathComponent("thumbs"))
        let item = MediaItem(path: jpeg.path, hash: "deadbeef", dateTaken: nil,
                             fileType: "image", width: 200, height: 200, lastScanned: Date())
        let url = await cache.thumbnailURL(for: item, size: 128)
        let unwrapped = try #require(url)
        #expect(FileManager.default.fileExists(atPath: unwrapped.path))
        let again = await cache.thumbnailURL(for: item, size: 128)
        #expect(unwrapped == again)  // cache hit → same path
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-one NAME=ThumbnailCacheTests`
Expected: FAIL — `ThumbnailCache` undefined.

- [ ] **Step 3: Write the cache**

`Sources/PhlookCore/ThumbnailCache.swift`:
```swift
import Foundation
import QuickLookThumbnailing
import AppKit

public final class ThumbnailCache {
    private let cacheDir: URL
    public init(cacheDir: URL) {
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func thumbnailURL(for item: MediaItem, size: Int) async -> URL? {
        let key = "\(item.hash ?? UUID().uuidString)_\(size).png"
        let dest = cacheDir.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path),
            size: CGSize(width: size, height: size),
            scale: 2.0,
            representationTypes: .thumbnail)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let rep,
                      let tiff = rep.nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else { cont.resume(returning: nil); return }
                try? png.write(to: dest)
                cont.resume(returning: dest)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=ThumbnailCacheTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/ThumbnailCache.swift Tests/PhlookCoreTests/ThumbnailCacheTests.swift
git commit -m "feat: on-disk thumbnail cache via QuickLook"
```

---

### Task 5: IndexingService — tie scanner + index + thumbnails

**Files:**
- Create: `Sources/PhlookCore/IndexingService.swift`
- Test: `Tests/PhlookCoreTests/IndexingServiceTests.swift`

**Interfaces:**
- Consumes: `MediaIndex` (Task 2), `LibraryScanner` (Task 3), `ThumbnailCache` (Task 4), `TestFixtures` (Task 3).
- Produces: `final class IndexingService { init(root: URL); @discardableResult func reindex() throws -> Int; func items() throws -> [MediaItem]; let thumbnails: ThumbnailCache }` — `reindex()` scans, upserts every found item, prunes DB rows whose files no longer exist, returns the item count. DB + thumbnail cache live under `root`.

- [ ] **Step 1: Write the failing test**

`Tests/PhlookCoreTests/IndexingServiceTests.swift`:
```swift
import Testing
import Foundation
@testable import PhlookCore

struct IndexingServiceTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("a.jpg"), width: 32, height: 32)
        try TestFixtures.writeJPEG(at: root.appendingPathComponent("b.jpg"), width: 48, height: 24)
        return root
    }

    @Test func reindexPopulatesAndRebuilds() throws {
        let root = try makeRoot()
        let service = IndexingService(root: root)
        let count = try service.reindex()
        #expect(count == 2)
        let itemCount = try service.items().count
        #expect(itemCount == 2)

        // Rebuild guarantee: delete the DB, reindex, identical count.
        try FileManager.default.removeItem(at: root.appendingPathComponent("phlook.db"))
        let rebuilt = try IndexingService(root: root).reindex()
        #expect(rebuilt == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-one NAME=IndexingServiceTests`
Expected: FAIL — `IndexingService` undefined.

- [ ] **Step 3: Write the service**

`Sources/PhlookCore/IndexingService.swift`:
```swift
import Foundation

public final class IndexingService {
    public let root: URL
    private let index: MediaIndex
    public let thumbnails: ThumbnailCache

    public init(root: URL) {
        self.root = root
        self.index = try! MediaIndex(dbPath: root.appendingPathComponent("phlook.db").path)
        self.thumbnails = ThumbnailCache(cacheDir: root.appendingPathComponent(".phlook/thumbnails"))
    }

    @discardableResult
    public func reindex() throws -> Int {
        let scanned = try LibraryScanner(root: root).scan()
        for item in scanned { try index.upsert(item) }
        try index.deleteMissing(keepingPaths: Set(scanned.map { $0.path }))
        return try index.count()
    }

    public func items() throws -> [MediaItem] {
        try index.allItems(sortedByDateDescending: true)
    }
}
```
Note: `reindex()` will also index the `phlook.db`? No — the scanner only accepts image/video extensions, so `phlook.db` and `.phlook/` thumbnails are ignored automatically.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-one NAME=IndexingServiceTests`
Expected: PASS (including the rebuild guarantee).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/IndexingService.swift Tests/PhlookCoreTests/IndexingServiceTests.swift
git commit -m "feat: IndexingService (scan+index+prune) with rebuild guarantee"
```

---

### Task 6: Micro-grid UI — "Hello Grid"

**Files:**
- Create: `Sources/Phlook/LibraryViewModel.swift`
- Create: `Sources/Phlook/MicroGridView.swift`
- Modify: `Sources/Phlook/ContentView.swift`

**Interfaces:**
- Consumes: `IndexingService`, `MediaItem` from PhlookCore.
- Produces: a SwiftUI `LazyVGrid` in a `ScrollView` rendering each indexed item as a cached thumbnail, loaded asynchronously. No new core API.

- [ ] **Step 1: Write the view model**

`Sources/Phlook/LibraryViewModel.swift`:
```swift
import SwiftUI
import PhlookCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    let service: IndexingService

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/PHLOOK")
        service = IndexingService(root: root)
    }

    func load() {
        let service = self.service
        Task.detached {
            _ = try? service.reindex()
            let items = (try? service.items()) ?? []
            await MainActor.run { self.items = items }
        }
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        guard let url = await service.thumbnails.thumbnailURL(for: item, size: 160) else { return nil }
        return NSImage(contentsOf: url)
    }
}
```

- [ ] **Step 2: Write the grid cell + grid**

`Sources/Phlook/MicroGridView.swift`:
```swift
import SwiftUI
import PhlookCore

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
        .task { image = await vm.thumbnail(for: item) }
    }
}

struct MicroGridView: View {
    @ObservedObject var vm: LibraryViewModel
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 80), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(vm.items, id: \.path) { item in
                    ThumbCell(item: item, vm: vm)
                }
            }
            .padding(2)
        }
    }
}
```

- [ ] **Step 3: Wire it into ContentView**

`Sources/Phlook/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    var body: some View {
        MicroGridView(vm: vm)
            .onAppear { vm.load() }
    }
}
```

- [ ] **Step 4: Build and run; verify manually**

Run:
```bash
cd ~/Documents/Projects/phlook
swift build
swift run Phlook
```
Expected: a window opens and fills with thumbnails of your `~/Pictures/PHLOOK` library; scrolling is smooth. First launch is slower while thumbnails generate; later launches are cache-fast.
Notes:
- If macOS prompts for Photos/Files access to `~/Pictures`, allow it.
- If the window opens behind other apps (SPM executables don't always auto-focus), click its Dock/window to foreground it.

- [ ] **Step 5: Commit**

```bash
git add Sources/Phlook/
git commit -m "feat: Hello Grid — render PHLOOK library in micro-grid"
```

---

## Self-Review

**Spec coverage (v1 Foundation portion):**
- Rebuildable index beside library → Tasks 2, 5 (rebuild guarantee tested). ✅
- Metadata read from files (EXIF/AVAsset) → Task 3. ✅
- Scan on launch → Task 5 + Task 6 `load()`. ✅ (FSEvents live-watch → Plan 2.)
- Thumbnail cache keyed by hash → Task 4. ✅
- Virtualized micro grid → Task 6 (`LazyVGrid`). ✅
- View-only guarantee → no task writes/moves/deletes originals. ✅
- SPM-only, no Xcode → Task 1 + Global Constraints. ✅

**Placeholder scan:** none — every code step has real code; setup steps use exact commands.

**Type consistency:** `MediaItem`, `MediaIndex`, `LibraryScanner`, `ThumbnailCache`, `IndexingService`, `TestFixtures` signatures are consistent across tasks; `IndexingService.thumbnails`, `MediaItem.path`/`.hash` used consistently in Task 6.

**Deferred (documented, not gaps):**
- **Plan 2 — Views + Navigation:** Normal listing, Fullscreen detail + metadata panel, Timeline rail, view switcher, Quick Look, Show in Finder, drag-out, FSEvents live indexing, sort/filter, sidebar (All/Map/Locked).
- **Plan 3 — Ingest:** `osxphotos` "Import from Photos" (originals + `--exiftool` metadata + `--update`).
