# Sidebar + Hidden Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native left sidebar (All/Photos/Videos/Live · Screenshots/Selfies · Hidden, with per-scope counts and a FROM–TO date-range slider) and Photos-parity Hidden items gated by Touch ID / password.

**Architecture:** Core: migration v5 (`hidden` flag + `kind_flags` bitmask with −1 backfill sentinel), `KindDetector` (pure rules) + a background kinds pass (video-enricher pattern), `LibraryScope` (replaces `MediaFilter`) and `DateRangeFilter` (pure). App: `NavigationSplitView` sidebar, LA-gated Hidden scope, hide/unhide menus. Spec: `docs/superpowers/specs/2026-07-07-sidebar-hidden-design.md`.

**Tech Stack:** Swift 5.10 SPM, swift-testing, GRDB, SwiftUI, ImageIO, LocalAuthentication.

## Global Constraints

- Tests ONLY via `make test` / `make test-one NAME=X`. 93 existing green, warning-free. macOS 14 / tools 5.10.
- Migration v5: version read once, sequential guarded blocks (v2/v3/v4 untouched): `hidden INTEGER NOT NULL DEFAULT 0`; `kind_flags INTEGER NOT NULL DEFAULT 0` with a one-time `UPDATE files SET kind_flags = -1` for pre-existing rows (−1 = "unknown, needs detection"; 0 = "scanned, no kinds"; bit 1 = screenshot, bit 2 = selfie). Fresh CREATE includes both columns (kind_flags DEFAULT 0 — new rows get real flags at extraction).
- Kind rules EXACT: screenshot = image AND (PNG with no TIFF Make/Model) OR EXIF UserComment == "Screenshot"; selfie = EXIF LensModel contains "front" (case-insensitive). Flags OR-combine.
- Hidden excluded from EVERY scope/count/timeline/viewer list except the Hidden scope; files never move.
- Hidden unlock: `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`; relocks when navigating to any other scope or on app quit.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Migration v5 + hidden flag plumbing (Core)

**Files:** Modify `Sources/PhlookCore/MediaItem.swift`, `Sources/PhlookCore/MediaIndex.swift`. Test: `Tests/PhlookCoreTests/HiddenFlagTests.swift` (create).

**Interfaces produced:** `MediaItem.hidden: Bool` (default false) + `kindFlags: Int` (default 0) with CodingKeys `hidden` / `kind_flags`, init params (after `modifiedAt`, defaults `hidden: Bool = false, kindFlags: Int = 0`); migration v5 per Global Constraints; `MediaIndex.setHidden(paths: [String], hidden: Bool) throws` (chunked like `delete`); upsert: same-hash branch PRESERVES `hidden` and `kindFlags` when incoming is default (scan items don't know them: preserve existing.hidden always — scanner never unhides; kindFlags: take incoming when incoming != 0 || existing == -1, else preserve — SIMPLER RULE, use this: `existing.hidden` NEVER overwritten by upsert (only setHidden touches it); `existing.kindFlags = item.kindFlags != 0 ? item.kindFlags : (existing.kindFlags == -1 ? item.kindFlags : existing.kindFlags)`); changed-hash branch: keep `hidden` (user intent survives file replacement), take incoming kindFlags verbatim.

Tests (write first, RED via compile error, then GREEN):
```swift
import Testing
import Foundation
@testable import PhlookCore

struct HiddenFlagTests {
    func makeIndex() throws -> MediaIndex {
        try MediaIndex(dbPath: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path)
    }
    func mkItem(_ path: String, kindFlags: Int = 0) -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: nil, fileType: "image",
                  width: nil, height: nil, lastScanned: Date(), kindFlags: kindFlags)
    }

    @Test func setHiddenRoundTrip() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg")); try index.upsert(mkItem("/b.jpg"))
        try index.setHidden(paths: ["/a.jpg"], hidden: true)
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden)
        #expect(try #require(try index.item(forPath: "/b.jpg")).hidden == false)
        try index.setHidden(paths: ["/a.jpg"], hidden: false)
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden == false)
    }

    @Test func rescanNeverUnhides() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg"))
        try index.setHidden(paths: ["/a.jpg"], hidden: true)
        try index.upsert(mkItem("/a.jpg"))          // same-hash scan pass
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden)
        var changed = mkItem("/a.jpg"); changed.hash = "different"
        try index.upsert(changed)                    // changed-hash pass
        #expect(try #require(try index.item(forPath: "/a.jpg")).hidden)
    }

    @Test func kindFlagsPreservedAgainstZeroScan() throws {
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg", kindFlags: 1))   // detected screenshot
        try index.upsert(mkItem("/a.jpg", kindFlags: 0))   // later same-hash scan, no info
        #expect(try #require(try index.item(forPath: "/a.jpg")).kindFlags == 1)
    }

    @Test func preexistingRowsGetUnknownSentinel() throws {
        // Fresh index: insert, then simulate pre-v5 by forcing -1, verify query surfaces it.
        let index = try makeIndex()
        try index.upsert(mkItem("/a.jpg"))
        try index.setKindFlagsForTesting(path: "/a.jpg", flags: -1)
        #expect(try index.kindsNeedingDetection().map(\.path) == ["/a.jpg"])
    }
}
```
Also add internal `setKindFlagsForTesting(path:flags:)` and `public func kindsNeedingDetection() throws -> [MediaItem]` (`WHERE kind_flags = -1 AND file_type = 'image'` — videos are never screenshots/selfies, set them 0 in the migration: `UPDATE files SET kind_flags = -1` then `UPDATE files SET kind_flags = 0 WHERE file_type = 'video'`).

Commit: `feat: hidden flag + kind_flags schema (v5) — rescan-proof hide, detection sentinel` + trailer.

---

### Task 2: KindDetector + fixtures + scanner wiring + backfill pass (Core)

**Files:** Create `Sources/PhlookCore/KindDetector.swift`; modify `Sources/PhlookCore/TestSupport.swift` (writeJPEG gains optional `tiffMake: String? = nil`, `lensModel: String? = nil`, `userComment: String? = nil` — embedded via kCGImagePropertyTIFFDictionary[Make] / ExifAux or Exif LensModel `kCGImagePropertyExifLensModel` / `kCGImagePropertyExifUserComment`), `Sources/PhlookCore/LibraryScanner.swift` (imageMeta also returns kind flags; full-extract sets `kindFlags`), `Sources/PhlookCore/IndexingService.swift` (add `detectKinds() async -> Int` mirroring `enrichVideos`, processing `kindsNeedingDetection()` in background: read flags via KindDetector, upsert). Test: `Tests/PhlookCoreTests/KindDetectorTests.swift`.

**Interfaces produced:**
```swift
public struct KindFlags: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let screenshot = KindFlags(rawValue: 1)
    public static let selfie = KindFlags(rawValue: 2)
}
public enum KindDetector {
    /// Reads image properties (ImageIO) and applies the spec rules.
    public static func flags(forImageAt url: URL) -> KindFlags
}
```
Scanner: for images, `kindFlags: KindDetector.flags(forImageAt: url).rawValue` in the full-extract path (cheap: reuse the CGImageSource already opened in imageMeta — refactor imageMeta to also return the properties dict or fold detection into it; do NOT open the file twice).

Tests: PNG fixture without Make/Model → screenshot flag; JPEG with tiffMake "Apple" + PNG ext? (screenshot rule is PNG-specific: write PNG fixture — extend TestFixtures with `writePNG(at:width:height:tiffMake:...)` or a `format:` param on writeJPEG; implementer's choice, keep it small); JPEG with lensModel "iPhone 14 Pro front TrueDepth camera" → selfie; JPEG with userComment "Screenshot" → screenshot; plain JPEG → []; combined flags OR. Plus: `detectKinds` integration test: insert -1 row pointing at a fixture file → run → flags set, second run returns 0.

Commit: `feat: KindDetector — screenshots/selfies from metadata + background backfill` + trailer.

---

### Task 3: LibraryScope + DateRangeFilter + VM rewire (Core + app)

**Files:** Create `Sources/PhlookCore/LibraryScope.swift`, `Sources/PhlookCore/DateRangeFilter.swift`; modify `Sources/Phlook/LibraryViewModel.swift`; delete the `MediaFilter` enum (replaced). Test: `Tests/PhlookCoreTests/LibraryScopeTests.swift`.

**Interfaces produced (Core):**
```swift
public enum LibraryScope: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos", live = "Live Photos"
    case screenshots = "Screenshots", selfies = "Selfies", hidden = "Hidden"
    public var id: String { rawValue }
    /// livePairs needed for .live and .photos (live stills count as photos).
    public func matches(_ item: MediaItem, livePairs: LivePairs) -> Bool
}
```
Semantics: every scope EXCEPT `.hidden` requires `!item.hidden`; `.hidden` requires `item.hidden`. `.all` = everything unhidden. `.photos` = images. `.videos` = videos. `.live` = images with a live pair. `.screenshots`/`.selfies` = flag bit set (kindFlags > 0 check via KindFlags contains). Hidden-paired-motion note: hidden exclusion composes with the existing hiddenVideoPaths filter in rebuildVisible (unchanged).

```swift
public struct DateRangeFilter: Equatable {
    public var lower: Date?   // nil = unbounded
    public var upper: Date?
    public func matches(_ item: MediaItem) -> Bool  // nil dateTaken passes only when both bounds nil
    public var isActive: Bool
}
```
VM rewire: `@Published var scope: LibraryScope = .all` (didSet: closeViewer, clearSelection, relock hidden if leaving `.hidden`, rebuildVisible); `@Published var dateRange = DateRangeFilter()` (didSet rebuildVisible); `rebuildVisible()` = items → drop hiddenVideoPaths → scope.matches → dateRange.matches; `@Published private(set) var scopeCounts: [LibraryScope: Int]` recomputed with timeline in refreshItems (single pass); hide/unhide: `func setHidden(_ items: [MediaItem], hidden: Bool)` → service.mediaIndex.setHidden + refresh; also kick `service.detectKinds()` in `load()` after enrichVideos (same pattern, refresh if > 0). Remove `MediaFilter`; keep a computed shim only if the grid still references it (it won't after Task 4). ContentView/MicroGridView compile: Task 4 does the UI — to keep THIS task buildable, temporarily map the old segmented Picker to a reduced set (`.all/.photos/.videos`) via scope. Tests: scope matrix (hidden exclusion everywhere, live counts as photo, flags), DateRangeFilter bounds/nil-date semantics.

Commit: `feat: LibraryScope + date-range filtering — hidden-aware visible pipeline` + trailer.

---

### Task 4: Sidebar UI (app)

**Files:** Create `Sources/Phlook/SidebarView.swift`; modify `Sources/Phlook/ContentView.swift`, `Sources/Phlook/MicroGridView.swift`.

- `ContentView` becomes `NavigationSplitView(sidebar: { SidebarView(vm: vm) }, detail: { existing ZStack grid+viewer })`. Viewer overlay must still cover the WHOLE window: keep ViewerView inside the detail ZStack (acceptable v1: sidebar remains visible when viewer open? NO — spec says full-app-screen: put the viewer overlay OUTSIDE the NavigationSplitView in a ZStack wrapping it). Sheets/dialogs stay at top level.
- `SidebarView`: `List(selection: $vm.scope)` with Sections "Library" (All/Photos/Videos/Live Photos), "Kinds" (Screenshots/Selfies), and Hidden (lock icon; count hidden until unlocked — show count only when unlocked). Row = Label(scope.rawValue, systemImage: per-scope symbol) + Spacer + count (secondary, from vm.scopeCounts).
- Date-range slider at sidebar bottom: two `Slider`s (From/To) over month indices derived from `vm.timeline` (dated buckets), labels showing selected month names, Reset button; drives `vm.dateRange`. (Custom dual-anchor rail is a later polish; two labeled sliders are v1.)
- Remove the old filter Picker from MicroGridView's filterBar (density picker + ImportBar stay).
- Build + `make test` + launch check. Commit: `feat: left sidebar — scopes, counts, date range; filter picker retired` + trailer.

---

### Task 5: Hidden UX + LocalAuthentication gate (app)

**Files:** Create `Sources/Phlook/HiddenGate.swift`; modify `Sources/Phlook/LibraryViewModel.swift`, `Sources/Phlook/SidebarView.swift`, `Sources/Phlook/MicroGridView.swift` (context menu), `Sources/Phlook/ViewerInputMonitor.swift`/`ViewerView.swift` (⌘H in viewer optional — grid only is fine for v1), `Sources/Phlook/ContentView.swift`.

- `HiddenGate` (ObservableObject or VM state): `@Published var hiddenUnlocked = false`; `func unlock() async` → `LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "view Hidden items")` (wrap callback in continuation); relock in `scope.didSet` when leaving `.hidden` (Task 3 already stubs this — wire it).
- Sidebar Hidden row: when locked, selecting it does NOT switch scope; it triggers unlock, and on success sets `vm.scope = .hidden`. Locked state shows `lock.fill`; unlocked shows `lock.open`.
- Grid in `.hidden` scope: context menu shows "Unhide" (calls `vm.setHidden(targets, hidden: false)`) instead of "Hide". All other scopes: add "Hide N Item(s)" (⌘H via GridKeyCatcher, respecting suspension guards) above "Move to Trash", using the same selection-targeting logic as trash (right-click outside selection re-selects).
- Locked-scope defense: if `vm.scope == .hidden` while `!hiddenUnlocked` (e.g. programmatic), `visibleItems` computes empty and the grid shows the lock placeholder ("Hidden items are locked") with an Authenticate button.
- Live pairs: hiding a paired still hides both rows? Motion rows are never visible, so hiding the still row suffices; BUT unhide/hidden-scope symmetry: when hiding, ALSO setHidden the paired motion path (so `.videos` scope can never leak it if pairing breaks later); unhide restores both. Use `vm.livePairs.videoPath(forImagePath:)` expansion exactly like trash does.
- Build + `make test` + launch check (LA prompt is human-only). Commit: `feat: Hidden — hide/unhide with Touch ID-gated scope` + trailer.

---

## Human smoke (after all tasks)

1. Sidebar: scopes switch, counts sane (Photos+Videos+... vs All), Screenshots/Selfies populate after the background kinds pass (~1 pass over 10.5k images, one-time).
2. Date sliders narrow the grid; Reset restores; composes with scope.
3. Hide a few items (⌘H / menu) → gone everywhere; Hidden row locked; click → Touch ID/password → contents show; Unhide restores; navigating away relocks.
4. Viewer still full-window over everything; import bar, densities, rail, hover previews all still work.
5. `make test` green.
