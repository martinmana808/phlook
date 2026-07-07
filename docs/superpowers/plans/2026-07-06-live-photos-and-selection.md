# Live Photos + Selection & Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live-photo pairs render as ONE photo item (LIVE badge, on-demand motion playback), and media can be selected (click/⌘/shift/⌘A) and moved to the macOS Trash — pair-aware.

**Architecture:** Two pure Core units (`LivePairs`, `LibraryTrasher` + `MediaIndex.delete`) carry the logic under test; `LibraryViewModel` gains pairing-aware `visibleItems` and a selection model; grid/viewer get badges, selection visuals, menus, and playback. Spec: `docs/superpowers/specs/2026-07-06-live-photos-and-selection-design.md`.

**Tech Stack:** Swift 5.10 SPM, swift-testing (never XCTest), GRDB, SwiftUI/AppKit, AVKit (existing PlayerHostView).

## Global Constraints

- Tests ONLY via `make test` / `make test-one NAME=X` (bare `swift test` finds 0). All 67 existing tests stay green, warning-free.
- macOS 14 minimum, tools 5.10 (no bump). No schema migration in this plan (pairing is computed, not stored).
- Live pair rule (exact): same `basename minus final extension`, one image + one video, video duration `> 0 && <= 6.5`.
- Files are NEVER modified by pairing; deletion uses `FileManager.trashItem` (recoverable), never `removeItem`.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: `LivePairs` (PhlookCore, pure)

**Files:**
- Create: `Sources/PhlookCore/LivePairs.swift`
- Test: `Tests/PhlookCoreTests/LivePairsTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  public struct LivePairs: Equatable {
      public static let maxMotionSeconds = 6.5
      public let hiddenVideoPaths: Set<String>
      public func videoPath(forImagePath: String) -> String?
      public static func compute(items: [MediaItem]) -> LivePairs
      public static let empty: LivePairs
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/LivePairsTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct LivePairsTests {
    func item(_ path: String, type: String, duration: Double? = nil) -> MediaItem {
        MediaItem(path: path, hash: nil, dateTaken: nil, fileType: type,
                  width: nil, height: nil, lastScanned: Date(), duration: duration)
    }

    @Test func pairsStemMatchedShortVideoWithImage() {
        let pairs = LivePairs.compute(items: [
            item("/lib/2026-07-06_12-00-00_IMG_1234.HEIC", type: "image"),
            item("/lib/2026-07-06_12-00-00_IMG_1234.MOV", type: "video", duration: 2.9),
        ])
        #expect(pairs.hiddenVideoPaths == ["/lib/2026-07-06_12-00-00_IMG_1234.MOV"])
        #expect(pairs.videoPath(forImagePath: "/lib/2026-07-06_12-00-00_IMG_1234.HEIC")
                == "/lib/2026-07-06_12-00-00_IMG_1234.MOV")
    }

    @Test func rejectsLongNilAndSentinelDurations() {
        let pairs = LivePairs.compute(items: [
            item("/a/X.HEIC", type: "image"),
            item("/a/X.MOV", type: "video", duration: 42),      // long: real video
            item("/a/Y.JPG", type: "image"),
            item("/a/Y.MOV", type: "video"),                    // nil: not yet enriched
            item("/a/Z.HEIC", type: "image"),
            item("/a/Z.MOV", type: "video", duration: -1),      // unreadable sentinel
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
        #expect(pairs.videoPath(forImagePath: "/a/X.HEIC") == nil)
    }

    @Test func requiresOneImageOneVideo() {
        let pairs = LivePairs.compute(items: [
            item("/a/A.HEIC", type: "image"),
            item("/a/A.PNG", type: "image"),                    // image+image: no pair
            item("/b/B.MOV", type: "video", duration: 2),       // lone short video: no pair
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
    }

    @Test func multiplePairsAndDottedStems() {
        let pairs = LivePairs.compute(items: [
            item("/l/one.HEIC", type: "image"),
            item("/l/one.MOV", type: "video", duration: 3),
            item("/l/archive.2024.HEIC", type: "image"),        // dot in stem
            item("/l/archive.2024.MOV", type: "video", duration: 1.5),
        ])
        #expect(pairs.hiddenVideoPaths.count == 2)
        #expect(pairs.videoPath(forImagePath: "/l/archive.2024.HEIC") == "/l/archive.2024.MOV")
    }

    @Test func differentDirectoriesDoNotPair() {
        let pairs = LivePairs.compute(items: [
            item("/one/A.HEIC", type: "image"),
            item("/two/A.MOV", type: "video", duration: 2),
        ])
        #expect(pairs.hiddenVideoPaths.isEmpty)
    }
}
```

- [ ] **Step 2: RED**

Run: `make test-one NAME=LivePairsTests`
Expected: COMPILE ERROR — `cannot find 'LivePairs' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/PhlookCore/LivePairs.swift`:

```swift
import Foundation

/// Index-level pairing of Live Photos: a still and its ~3s motion file share
/// a filename stem (ingest preserves it). Pure computation — no file or DB
/// changes; an unenriched video (nil duration) simply pairs after enrichment.
public struct LivePairs: Equatable {
    public static let maxMotionSeconds = 6.5
    public static let empty = LivePairs(hiddenVideoPaths: [], videoByImagePath: [:])

    public let hiddenVideoPaths: Set<String>
    private let videoByImagePath: [String: String]

    init(hiddenVideoPaths: Set<String>, videoByImagePath: [String: String]) {
        self.hiddenVideoPaths = hiddenVideoPaths
        self.videoByImagePath = videoByImagePath
    }

    public func videoPath(forImagePath path: String) -> String? {
        videoByImagePath[path]
    }

    /// Stem = full path minus the final extension, so pairing is per-directory
    /// and tolerates dots inside the name ("archive.2024.HEIC").
    private static func stem(_ path: String) -> String {
        (path as NSString).deletingPathExtension
    }

    public static func compute(items: [MediaItem]) -> LivePairs {
        var imageByStem: [String: String] = [:]
        for item in items where item.fileType == "image" {
            imageByStem[stem(item.path)] = item.path
        }
        var hidden: Set<String> = []
        var byImage: [String: String] = [:]
        for item in items where item.fileType == "video" {
            guard let d = item.duration, d > 0, d <= maxMotionSeconds,
                  let imagePath = imageByStem[stem(item.path)] else { continue }
            hidden.insert(item.path)
            byImage[imagePath] = item.path
        }
        return LivePairs(hiddenVideoPaths: hidden, videoByImagePath: byImage)
    }
}
```

- [ ] **Step 4: GREEN + full suite**

`make test-one NAME=LivePairsTests` — 5 PASS. `make test` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/LivePairs.swift Tests/PhlookCoreTests/LivePairsTests.swift
git commit -m "feat: LivePairs — index-level live-photo pairing by stem + short duration

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Deletion core — `MediaIndex.delete(paths:)` + `LibraryTrasher`

**Files:**
- Modify: `Sources/PhlookCore/MediaIndex.swift`
- Create: `Sources/PhlookCore/LibraryTrasher.swift`
- Test: `Tests/PhlookCoreTests/LibraryTrasherTests.swift` (create)

**Interfaces:**
- Produces: `MediaIndex.delete(paths: [String]) throws`;
  ```swift
  public struct TrashOutcome: Equatable {
      public let trashedPaths: [String]     // gone from library (incl. already-missing pruned)
      public let failures: [String]         // "name — reason", still present
  }
  public enum LibraryTrasher {
      public static func trash(paths: [String], index: MediaIndex) -> TrashOutcome
  }
  ```
  Semantics: per path — file exists? `FileManager.trashItem` (failure → failures, row kept) : treat as prune (success). All successes' rows deleted via one `index.delete(paths:)` call at the end.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/LibraryTrasherTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct LibraryTrasherTests {
    func makeWorld() throws -> (dir: URL, index: MediaIndex) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = try MediaIndex(dbPath: dir.appendingPathComponent("t.db").path)
        return (dir, index)
    }

    func addFile(_ dir: URL, _ name: String, _ index: MediaIndex) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try index.upsert(MediaItem(path: url.path, hash: "h", dateTaken: nil,
                                   fileType: "image", width: nil, height: nil,
                                   lastScanned: Date()))
        return url.path
    }

    @Test func deleteRemovesOnlyGivenRows() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        let b = try addFile(dir, "b.jpg", index)
        try index.delete(paths: [a])
        #expect(try index.item(forPath: a) == nil)
        #expect(try index.item(forPath: b) != nil)
        try index.delete(paths: [])   // no-op
        #expect(try index.count() == 1)
    }

    @Test func trashMovesFileAndPrunesRow() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        let outcome = LibraryTrasher.trash(paths: [a], index: index)
        #expect(outcome.trashedPaths == [a])
        #expect(outcome.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: a))   // moved to Trash
        #expect(try index.item(forPath: a) == nil)
    }

    @Test func missingFileIsPrunedAsSuccess() throws {
        let (dir, index) = try makeWorld()
        let a = try addFile(dir, "a.jpg", index)
        try FileManager.default.removeItem(atPath: a)          // vanished behind our back
        let outcome = LibraryTrasher.trash(paths: [a], index: index)
        #expect(outcome.trashedPaths == [a])
        #expect(try index.item(forPath: a) == nil)
    }

    @Test func partialFailureKeepsFailedRow() throws {
        let (dir, index) = try makeWorld()
        let good = try addFile(dir, "good.jpg", index)
        // A path that exists in DB but points into a read-only, un-trashable place:
        let bad = "/System/Library/CoreServices/SystemVersion.plist"
        try index.upsert(MediaItem(path: bad, hash: "h", dateTaken: nil,
                                   fileType: "image", width: nil, height: nil,
                                   lastScanned: Date()))
        let outcome = LibraryTrasher.trash(paths: [good, bad], index: index)
        #expect(outcome.trashedPaths == [good])
        #expect(outcome.failures.count == 1)
        #expect(try index.item(forPath: bad) != nil)            // row kept
    }
}
```

- [ ] **Step 2: RED**

`make test-one NAME=LibraryTrasherTests` — COMPILE ERROR (`no member 'delete'`).

- [ ] **Step 3: Implement**

Add to `Sources/PhlookCore/MediaIndex.swift`:

```swift
    /// Remove rows for the given paths. Chunked to stay under SQLite's
    /// parameter limit on large selections.
    public func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            for chunk in stride(from: 0, to: paths.count, by: 500).map({
                Array(paths[$0..<min($0 + 500, paths.count)])
            }) {
                let placeholders = repeatElement("?", count: chunk.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM files WHERE path IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
        }
    }
```

Create `Sources/PhlookCore/LibraryTrasher.swift`:

```swift
import Foundation

public struct TrashOutcome: Equatable {
    public let trashedPaths: [String]
    public let failures: [String]
}

/// Moves library files to the macOS Trash (recoverable) and prunes their
/// index rows. Per-file failures never abort the batch. A path whose file is
/// already missing is pruned as a success — the row was stale.
public enum LibraryTrasher {
    public static func trash(paths: [String], index: MediaIndex) -> TrashOutcome {
        let fm = FileManager.default
        var trashed: [String] = []
        var failures: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if !fm.fileExists(atPath: path) {
                trashed.append(path)                    // stale row: prune
                continue
            }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.append(path)
            } catch {
                failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        try? index.delete(paths: trashed)
        return TrashOutcome(trashedPaths: trashed, failures: failures)
    }
}
```

- [ ] **Step 4: GREEN + full suite**

`make test-one NAME=LibraryTrasherTests` — 4 PASS. `make test` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/MediaIndex.swift Sources/PhlookCore/LibraryTrasher.swift Tests/PhlookCoreTests/LibraryTrasherTests.swift
git commit -m "feat: MediaIndex.delete + LibraryTrasher — recoverable Trash-based deletion core

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: VM pairing + selection model; grid badges, selection visuals, delete menu

**Files:**
- Modify: `Sources/Phlook/LibraryViewModel.swift`
- Modify: `Sources/Phlook/MicroGridView.swift`
- Modify: `Sources/Phlook/ContentView.swift`

**Interfaces:**
- Consumes: `LivePairs` (T1), `LibraryTrasher`/`TrashOutcome` (T2).
- Produces (T4 relies on): `vm.livePairs: LivePairs`, `vm.selectedPaths: Set<String>`, `vm.select(_ item: MediaItem, commandKey: Bool, shiftKey: Bool)`, `vm.selectAllVisible()`, `vm.clearSelection()`, `vm.requestTrash(_ items: [MediaItem])` → sets `vm.pendingTrash: [MediaItem]?` (confirmation state), `vm.confirmTrash()`, `vm.trashFailures: [String]?` (alert state), `vm.isLive(_ item: MediaItem) -> Bool`.

No unit tests (app target). Build + Core regression + smoke notes.

- [ ] **Step 1: LibraryViewModel changes**

Read the current file, then apply:

1. New published state:
```swift
    @Published private(set) var livePairs: LivePairs = .empty
    @Published var selectedPaths: Set<String> = []
    @Published var pendingTrash: [MediaItem]?     // confirmation dialog payload
    @Published var trashFailures: [String]?       // post-delete failure alert
    private var selectionAnchorPath: String?
```

2. In `refreshItems(_:)` (and `rebuildVisible()`): compute pairs BEFORE filtering, hide motion halves, prune stale selection:
```swift
    private func refreshItems(_ new: [MediaItem]) {
        let openPath = currentItem?.path
        items = new
        livePairs = LivePairs.compute(items: new)
        rebuildVisible()
        selectedPaths = selectedPaths.filter { p in visibleItems.contains { $0.path == p } }
        if let openPath {
            viewerIndex = ViewerMath.resolveIndex(path: openPath, in: visibleItems)
        }
    }

    private func rebuildVisible() {
        let unhidden = items.filter { !livePairs.hiddenVideoPaths.contains($0.path) }
        visibleItems = filter == .all ? unhidden : unhidden.filter { filter.matches($0) }
    }
```
(Also call `livePairs = LivePairs.compute(items: items)` is NOT needed in `filter.didSet` — pairs depend on items only; `rebuildVisible()` already reads them.)

3. Selection + trash API:
```swift
    func isLive(_ item: MediaItem) -> Bool {
        item.fileType == "image" && livePairs.videoPath(forImagePath: item.path) != nil
    }

    func select(_ item: MediaItem, commandKey: Bool, shiftKey: Bool) {
        if shiftKey, let anchor = selectionAnchorPath,
           let a = visibleItems.firstIndex(where: { $0.path == anchor }),
           let b = visibleItems.firstIndex(where: { $0.path == item.path }) {
            let range = min(a, b)...max(a, b)
            selectedPaths.formUnion(visibleItems[range].map(\.path))
        } else if commandKey {
            if selectedPaths.contains(item.path) { selectedPaths.remove(item.path) }
            else { selectedPaths.insert(item.path) }
            selectionAnchorPath = item.path
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
    }

    func selectAllVisible() { selectedPaths = Set(visibleItems.map(\.path)) }
    func clearSelection() { selectedPaths = []; selectionAnchorPath = nil }

    /// Right-click delete: if the clicked item isn't in the selection, the
    /// selection becomes just that item (Photos behavior) before confirming.
    func requestTrash(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        pendingTrash = items
    }

    func confirmTrash() {
        guard let targets = pendingTrash else { return }
        pendingTrash = nil
        // Expand live pairs: trashing the still takes the motion file with it.
        var paths: [String] = []
        for item in targets {
            paths.append(item.path)
            if let motion = livePairs.videoPath(forImagePath: item.path) {
                paths.append(motion)
            }
        }
        let service = self.service
        Task.detached {
            let index = service.mediaIndex
            let outcome = LibraryTrasher.trash(paths: paths, index: index)
            let fresh = (try? service.items()) ?? []
            await MainActor.run {
                self.refreshItems(fresh)
                self.clearSelection()
                if !outcome.failures.isEmpty { self.trashFailures = outcome.failures }
            }
        }
    }
```
`IndexingService` currently keeps its `index` private — add ONE passthrough in `Sources/PhlookCore/IndexingService.swift`:
```swift
    /// The backing index, for read/delete operations owned by the UI layer.
    public var mediaIndex: MediaIndex { index }
```
(and change `private let index` to `private let index: MediaIndex` unchanged — only the accessor is new).

- [ ] **Step 2: ThumbCell + grid**

In `Sources/Phlook/MicroGridView.swift`:

1. `ThumbCell` gains selection + LIVE visuals. Duration badge/▶ only for NON-live videos (paired motion never renders anyway; the still shows LIVE instead):
```swift
        .overlay(alignment: .topLeading) {
            if vm.isLive(item) {
                Image(systemName: "livephoto")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .overlay {
            if vm.selectedPaths.contains(item.path) {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if vm.selectedPaths.contains(item.path) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(3)
            }
        }
```
2. Single-click selection BEFORE the double-click gesture (SwiftUI: attach a simultaneous single TapGesture reading modifiers):
```swift
        .gesture(TapGesture(count: 2).onEnded { vm.openViewer(item) })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            let flags = NSEvent.modifierFlags
            vm.select(item, commandKey: flags.contains(.command), shiftKey: flags.contains(.shift))
        })
```
3. Context menu — replace the current one:
```swift
        .contextMenu {
            Button("Open") { vm.openViewer(item) }
            Button("View Details") { vm.detailsItem = item }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Divider()
            Button(trashTitle, role: .destructive) {
                if !vm.selectedPaths.contains(item.path) {
                    vm.select(item, commandKey: false, shiftKey: false)
                }
                let targets = vm.visibleItems.filter { vm.selectedPaths.contains($0.path) }
                vm.requestTrash(targets.isEmpty ? [item] : targets)
            }
        }
```
with a computed helper in ThumbCell:
```swift
    private var trashTitle: String {
        let n = vm.selectedPaths.contains(item.path) ? max(vm.selectedPaths.count, 1) : 1
        return n > 1 ? "Move \(n) Items to Trash" : "Move to Trash"
    }
```
4. Grid-level keyboard: in `MicroGridView.body`'s outer VStack add:
```swift
        .background(GridKeyCatcher(vm: vm))
```
and at file bottom:
```swift
/// Grid-scoped key handling: ⌘A select-all, Esc clear, Delete → trash selection.
/// Local NSEvent monitor active only while the viewer is closed.
private struct GridKeyCatcher: NSViewRepresentable {
    let vm: LibraryViewModel

    func makeNSView(context: Context) -> NSView { KeyView(vm: vm) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyView: NSView {
        let vm: LibraryViewModel
        private var monitor: Any?

        init(vm: LibraryViewModel) {
            self.vm = vm
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.vm.viewerIndex == nil else { return event }
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "a" {
                    self.vm.selectAllVisible(); return nil
                }
                switch event.keyCode {
                case 53:          // Esc
                    guard !self.vm.selectedPaths.isEmpty else { return event }
                    self.vm.clearSelection(); return nil
                case 51, 117:     // Delete / Forward-delete
                    let targets = self.vm.visibleItems.filter { self.vm.selectedPaths.contains($0.path) }
                    guard !targets.isEmpty else { return event }
                    self.vm.requestTrash(targets); return nil
                default:
                    return event
                }
            }
        }

        required init?(coder: NSCoder) { fatalError() }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
```
(`GridKeyCatcher.KeyView` methods run on the main thread — annotate the class `@MainActor` if the compiler demands it.)

- [ ] **Step 3: ContentView — confirmation + failure alert**

Append to ContentView's modifier chain (after the existing sheets):
```swift
        .confirmationDialog(
            "Move \(vm.pendingTrash?.count ?? 0) item(s) to Trash?",
            isPresented: Binding(get: { vm.pendingTrash != nil },
                                 set: { if !$0 { vm.pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { vm.confirmTrash() }
            Button("Cancel", role: .cancel) { vm.pendingTrash = nil }
        } message: {
            Text("You can restore them from the Trash.")
        }
        .alert("Some items could not be moved to Trash",
               isPresented: Binding(get: { vm.trashFailures != nil },
                                    set: { if !$0 { vm.trashFailures = nil } })) {
            Button("OK") { vm.trashFailures = nil }
        } message: {
            Text((vm.trashFailures ?? []).joined(separator: "\n"))
        }
```

- [ ] **Step 4: Build + regression + launch check**

`swift build 2>&1 | tail -3` → complete; `make test` → all green (Core has one new accessor only); `make app && open ./Phlook.app`, 15s, pgrep, quit. Note in report: LIVE badges should appear on real pairs after launch (the library has stem-matched HEIC/MOV pairs from today's 212-file import).

- [ ] **Step 5: Commit**

```bash
git add Sources/Phlook/LibraryViewModel.swift Sources/Phlook/MicroGridView.swift Sources/Phlook/ContentView.swift Sources/PhlookCore/IndexingService.swift
git commit -m "feat: live-pair hiding + LIVE badges; selection model; pair-aware Move to Trash

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Viewer — LIVE playback, Delete key, live-aware details

**Files:**
- Modify: `Sources/Phlook/ViewerView.swift`
- Modify: `Sources/Phlook/ViewerInputMonitor.swift`
- Modify: `Sources/Phlook/DetailsSidebar.swift`

**Interfaces:**
- Consumes: `vm.isLive(_:)`, `vm.livePairs.videoPath(forImagePath:)`, `vm.requestTrash(_:)` (T3), existing `PlayerHostView`.

- [ ] **Step 1: ViewerInputMonitor — Delete key**

Add `var onDelete: () -> Void = {}` and in the keyDown switch, cases `51, 117` → `self.onDelete(); return nil` (before the default).

- [ ] **Step 2: ViewerView — LIVE control + playback + delete wiring**

1. State: `@State private var livePlayer: AVPlayer?`.
2. In `media`, when `livePlayer` is non-nil show it INSTEAD of the still:
```swift
        } else if let livePlayer {
            PlayerHostView(player: livePlayer)
        } else if let image {
```
3. Top bar: before the ⓘ button, when `vm.currentItem.map(vm.isLive) == true`:
```swift
                if let item = vm.currentItem, vm.isLive(item) {
                    Button {
                        playLive(for: item)
                    } label: {
                        Label("LIVE", systemImage: "livephoto")
                            .foregroundStyle(.white)
                    }
                }
```
4. Playback helper (plays once, returns to the still):
```swift
    private func playLive(for item: MediaItem) {
        guard let motion = vm.livePairs.videoPath(forImagePath: item.path) else { return }
        let player = AVPlayer(url: URL(fileURLWithPath: motion))
        livePlayer = player
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { _ in
            Task { @MainActor in self.livePlayer = nil }
        }
        player.play()
    }
```
5. Reset `livePlayer = nil` (and pause it) at the top of `loadCurrent()` alongside the existing player/image resets.
6. `onAppear`: `monitor.onDelete = { if let item = vm.currentItem { vm.requestTrash([item]) } }` — the confirmation dialog is already global in ContentView; after `confirmTrash()`, the existing `refreshItems` re-resolution advances/closes the viewer (path gone → index re-resolves to nil → closes; acceptable v1: viewer closes after delete).
7. If the compiler flags the notification closure capturing `self` (struct), hoist to a small `@State` holder or use the block-token API and remove it in `loadCurrent` — keep behavior: motion plays once, still returns.

- [ ] **Step 3: DetailsSidebar / DetailsRows — live kind + motion path**

In `DetailsRows` nothing changes. In `DetailsSidebar` and `DetailsModal`, after the Kind row, when the item is live add (pass `motionPath: String?` in as a new optional parameter defaulting nil; T3's call sites updated):
```swift
            if let motionPath {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Photo motion").font(.caption).foregroundStyle(.secondary)
                    Text((motionPath as NSString).lastPathComponent).font(.caption2)
                    Button("Show Motion File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: motionPath)])
                    }.controlSize(.small)
                }
            }
```
Call sites: `DetailsSidebar(item: item, motionPath: vm.livePairs.videoPath(forImagePath: item.path), onClose: …)` (ViewerView) and similarly in ContentView's `DetailsModal`. Kind text: when motionPath != nil, display kind as `"Live Photo (\(details.kind))"` — do this in the views, not MediaDetails (Core stays pairing-agnostic).

- [ ] **Step 4: Build + regression + launch check**

`swift build` → complete; `make test` → all green; `make app && open ./Phlook.app`, 15s, pgrep, quit.

- [ ] **Step 5: Commit**

```bash
git add Sources/Phlook/ViewerView.swift Sources/Phlook/ViewerInputMonitor.swift Sources/Phlook/DetailsSidebar.swift Sources/Phlook/ContentView.swift
git commit -m "feat: viewer LIVE playback, Delete-key trash, live-aware details

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Human smoke checklist (after all tasks)

1. Grid: motion halves of live pairs are gone; their stills show the LIVE glyph; video count in the Videos filter drops accordingly.
2. Click / ⌘-click / shift-click / ⌘A / Esc selection behavior; selection ring + checkmark.
3. Right-click an unselected cell → "Move to Trash" targets just it; with a multi-selection → "Move N Items to Trash"; confirmation appears; Finder Trash contains the files (both halves for a live pair); grid updates.
4. Viewer on a live still: LIVE button plays motion once with sound, returns to still; Delete key trashes (confirm) and closes; reopen grid intact.
5. `make test` — all green.
