# Phone Import (ImageCaptureCore) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plug in iPhone → PHLOOK shows "Import N new" → one click downloads never-imported originals to staging, ingests them, and shows the verified report. The imports table remembers item identifiers forever.

**Architecture:** Testable memory + diffing in PhlookCore (`imports` table on `MediaIndex`, `PhoneImportPlanner`); an ImageCaptureCore-driven `PhoneImportController` (ObservableObject) plus a small import bar + report sheet in the app target. Downloads reuse the existing staging → `IngestService` pipeline unchanged. Spec: `docs/superpowers/specs/2026-07-06-phone-import-design.md`.

**Tech Stack:** Swift 5.10 SPM, swift-testing, GRDB, ImageCaptureCore, SwiftUI.

## Global Constraints

- Tests ONLY via `make test` / `make test-one NAME=X` (bare `swift test` finds 0 tests). swift-testing only, never XCTest.
- macOS 14 minimum, swift-tools-version 5.10 (do not bump).
- Migration versioning uses `PRAGMA user_version`; current version is 2 — this plan bumps to 3. Never renumber existing steps.
- Identifiers recorded in the imports table must be deterministic across reconnects (composite `name|creationDateISO8601|fileSize` fallback).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- All existing tests (57) stay green, warning-free.
- ICC hardware flow cannot be exercised by agents — Tasks 3–4 are build-verified; the human smoke test with a real iPhone is the acceptance gate.

---

### Task 1: Imports memory — table, record, query (PhlookCore)

**Files:**
- Modify: `Sources/PhlookCore/MediaIndex.swift`
- Test: `Tests/PhlookCoreTests/ImportsTableTests.swift` (create)

**Interfaces:**
- Produces: `MediaIndex.recordImport(device: String, identifier: String) throws` (idempotent); `MediaIndex.importedIdentifiers(device: String) throws -> Set<String>`; migration `user_version` 2 → 3 creating the `imports` table on fresh AND existing databases.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/ImportsTableTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct ImportsTableTests {
    func makeIndex() throws -> MediaIndex {
        try MediaIndex(dbPath: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path)
    }

    @Test func recordAndQueryRoundTrip() throws {
        let index = try makeIndex()
        try index.recordImport(device: "Martin's iPhone", identifier: "IMG_1.HEIC|2026-07-06T12:00:00Z|1000")
        try index.recordImport(device: "Martin's iPhone", identifier: "IMG_2.HEIC|2026-07-06T12:01:00Z|2000")
        let ids = try index.importedIdentifiers(device: "Martin's iPhone")
        #expect(ids.count == 2)
        #expect(ids.contains("IMG_1.HEIC|2026-07-06T12:00:00Z|1000"))
    }

    @Test func recordIsIdempotent() throws {
        let index = try makeIndex()
        try index.recordImport(device: "d", identifier: "same")
        try index.recordImport(device: "d", identifier: "same")   // must not throw
        #expect(try index.importedIdentifiers(device: "d").count == 1)
    }

    @Test func devicesAreIsolated() throws {
        let index = try makeIndex()
        try index.recordImport(device: "iPhone A", identifier: "x")
        #expect(try index.importedIdentifiers(device: "iPhone B").isEmpty)
    }

    @Test func existingV2DatabaseGainsImportsTable() throws {
        // Open once (creates schema at current version), then reopen — both
        // paths must expose a working imports table.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db").path
        _ = try MediaIndex(dbPath: path)
        let reopened = try MediaIndex(dbPath: path)
        try reopened.recordImport(device: "d", identifier: "x")
        #expect(try reopened.importedIdentifiers(device: "d") == ["x"])
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `make test-one NAME=ImportsTableTests`
Expected: COMPILE ERROR — `value of type 'MediaIndex' has no member 'recordImport'`.

- [ ] **Step 3: Implement**

In `Sources/PhlookCore/MediaIndex.swift`, inside `migrate()` after the `user_version < 2` block, add:

```swift
            if version < 3 {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS imports (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        device_name TEXT NOT NULL,
                        item_identifier TEXT NOT NULL,
                        imported_at TEXT NOT NULL,
                        UNIQUE(device_name, item_identifier)
                    );
                """)
                try db.execute(sql: "PRAGMA user_version = 3")
            }
```

IMPORTANT: the existing `version` constant is read once at the top of the write block; the `< 2` block sets user_version to 2 — make sure the `< 3` check uses the ORIGINAL read `version` value and still runs (i.e. both blocks execute for a v0 database). Simplest correct shape: read `version` once; `if version < 2 { … }`; `if version < 3 { … }` — each block ends by setting its own version; final state 3 either way.

Add the two methods to `MediaIndex`:

```swift
    /// Idempotent: re-recording the same (device, identifier) is a no-op.
    public func recordImport(device: String, identifier: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO imports (device_name, item_identifier, imported_at) VALUES (?, ?, ?)",
                arguments: [device, identifier, ISO8601DateFormatter().string(from: Date())])
        }
    }

    public func importedIdentifiers(device: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT item_identifier FROM imports WHERE device_name = ?",
                arguments: [device]))
        }
    }
```

- [ ] **Step 4: Run to verify GREEN, then full suite**

Run: `make test-one NAME=ImportsTableTests` — 4 PASS. Then `make test` — all green (existing migration tests must still pass; the v2 backfill test asserts date-nulling still works).

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/MediaIndex.swift Tests/PhlookCoreTests/ImportsTableTests.swift
git commit -m "feat: imports memory table — device import history survives file moves

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: PhoneImportPlanner — descriptor + pending diff (PhlookCore)

**Files:**
- Create: `Sources/PhlookCore/PhoneImportPlanner.swift`
- Test: `Tests/PhlookCoreTests/PhoneImportPlannerTests.swift` (create)

**Interfaces:**
- Consumes: `LibraryScanner.imageExts` / `videoExts` (internal statics).
- Produces:
  ```swift
  public struct CameraItemDescriptor: Equatable {
      public let name: String            // "IMG_5305.HEIC"
      public let creationDate: Date?
      public let fileSize: Int
      public init(name: String, creationDate: Date?, fileSize: Int)
      public var identifier: String      // "IMG_5305.HEIC|2026-07-06T12:00:00Z|123456" ("unknown" when date nil)
      public var isMediaFile: Bool       // extension ∈ scanner image/video sets
  }
  public enum PhoneImportPlanner {
      public static func pending(onDevice items: [CameraItemDescriptor],
                                 alreadyImported: Set<String>) -> [CameraItemDescriptor]
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PhlookCoreTests/PhoneImportPlannerTests.swift`:

```swift
import Testing
import Foundation
@testable import PhlookCore

struct PhoneImportPlannerTests {
    let date = ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z")!

    func item(_ name: String, size: Int = 100) -> CameraItemDescriptor {
        CameraItemDescriptor(name: name, creationDate: date, fileSize: size)
    }

    @Test func identifierIsDeterministicComposite() {
        let a = item("IMG_1.HEIC", size: 123)
        #expect(a.identifier == "IMG_1.HEIC|2026-07-06T12:00:00Z|123")
        #expect(a.identifier == item("IMG_1.HEIC", size: 123).identifier)
    }

    @Test func nilDateUsesUnknownPlaceholder() {
        let a = CameraItemDescriptor(name: "X.MOV", creationDate: nil, fileSize: 5)
        #expect(a.identifier == "X.MOV|unknown|5")
    }

    @Test func pendingExcludesRecordedAndNonMedia() {
        let items = [item("IMG_1.HEIC"), item("IMG_2.MOV"), item("IMG_3.AAE"), item("IMG_4.JPG")]
        let recorded: Set<String> = [item("IMG_1.HEIC").identifier]
        let pending = PhoneImportPlanner.pending(onDevice: items, alreadyImported: recorded)
        #expect(pending.map(\.name) == ["IMG_2.MOV", "IMG_4.JPG"])   // 1 recorded, AAE non-media
    }

    @Test func allRecordedMeansNothingPending() {
        let items = [item("A.JPG"), item("B.JPG")]
        let recorded = Set(items.map(\.identifier))
        #expect(PhoneImportPlanner.pending(onDevice: items, alreadyImported: recorded).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `make test-one NAME=PhoneImportPlannerTests`
Expected: COMPILE ERROR — `cannot find 'CameraItemDescriptor' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/PhlookCore/PhoneImportPlanner.swift`:

```swift
import Foundation

/// A camera-roll item as seen over ImageCaptureCore, reduced to what the
/// import memory needs. The identifier must be deterministic across
/// reconnects — name + creation date + byte size is stable for camera items.
public struct CameraItemDescriptor: Equatable {
    public let name: String
    public let creationDate: Date?
    public let fileSize: Int

    public init(name: String, creationDate: Date?, fileSize: Int) {
        self.name = name
        self.creationDate = creationDate
        self.fileSize = fileSize
    }

    private static let iso = ISO8601DateFormatter()

    public var identifier: String {
        let date = creationDate.map { Self.iso.string(from: $0) } ?? "unknown"
        return "\(name)|\(date)|\(fileSize)"
    }

    public var isMediaFile: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return LibraryScanner.imageExts.contains(ext) || LibraryScanner.videoExts.contains(ext)
    }
}

public enum PhoneImportPlanner {
    /// Device items that are media files and have never been imported,
    /// in device order.
    public static func pending(onDevice items: [CameraItemDescriptor],
                               alreadyImported: Set<String>) -> [CameraItemDescriptor] {
        items.filter { $0.isMediaFile && !alreadyImported.contains($0.identifier) }
    }
}
```

- [ ] **Step 4: GREEN + full suite**

Run: `make test-one NAME=PhoneImportPlannerTests` — 4 PASS. Then `make test` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhlookCore/PhoneImportPlanner.swift Tests/PhlookCoreTests/PhoneImportPlannerTests.swift
git commit -m "feat: PhoneImportPlanner — deterministic camera-item identity + pending diff

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: PhoneImportController — ImageCaptureCore session + download loop (app target)

**Files:**
- Create: `Sources/Phlook/PhoneImportController.swift`

**Interfaces:**
- Consumes: `MediaIndex` via a new thin accessor on `IndexingService` (add `public func recordImport(device:identifier:) throws` and `public func importedIdentifiers(device:) throws -> Set<String>` passthroughs to the private index — modify `Sources/PhlookCore/IndexingService.swift`), `PhoneImportPlanner`, `CameraItemDescriptor`, `IngestService`, `IngestReport`.
- Produces (Task 4 relies on): `PhoneImportController: NSObject, ObservableObject` with:
  ```swift
  enum ImportState: Equatable {
      case idle
      case connecting(device: String)
      case ready(device: String, pending: Int)
      case importing(device: String, done: Int, total: Int)
      case finished(report: IngestReport, failed: [String])
      case error(message: String)
  }
  @Published private(set) var state: ImportState
  func start()                       // begins device browsing; call once
  func importAllNew()                // valid in .ready with pending > 0
  func dismissResult()               // .finished/.error → back to .ready/.idle recompute
  var onLibraryChanged: () -> Void   // set by the UI; called after a finished ingest
  ```

**ICC reality check (compile-risk latitude):** ImageCaptureCore's Swift surface is old and ObjC-shaped. The skeleton below names the intended APIs; if exact signatures differ on this SDK (delegate method names, download-option keys, `ICDeviceTypeMask`/`ICDeviceLocationTypeMask` combination), adjust minimally to the real modern equivalents, keep the behavior, and record every deviation in your report. `ICCameraDeviceDelegate` has several required stub methods — implement them as empty/minimal. Do NOT use deprecated APIs where a current one exists.

- [ ] **Step 1: Implement the controller**

Create `Sources/Phlook/PhoneImportController.swift`:

```swift
import Foundation
import ImageCaptureCore
import PhlookCore

@MainActor
final class PhoneImportController: NSObject, ObservableObject {
    enum ImportState: Equatable {
        case idle
        case connecting(device: String)
        case ready(device: String, pending: Int)
        case importing(device: String, done: Int, total: Int)
        case finished(report: IngestReport, failed: [String])
        case error(message: String)
    }

    @Published private(set) var state: ImportState = .idle
    var onLibraryChanged: () -> Void = {}

    private let service: IndexingService
    private let staging: URL
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var pendingFiles: [ICCameraFile] = []
    private var downloadQueue: [ICCameraFile] = []
    private var doneCount = 0
    private var failedNames: [String] = []

    init(service: IndexingService,
         staging: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent("Pictures/PHLOOK_staging")) {
        self.service = service
        self.staging = staging
        super.init()
    }

    func start() {
        browser.delegate = self
        // Local cameras (USB). Mask combination per ICC convention.
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)
            ?? .camera
        browser.start()
    }

    func importAllNew() {
        guard case .ready(let device, let pending) = state, pending > 0, camera != nil else { return }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        downloadQueue = pendingFiles
        doneCount = 0
        failedNames = []
        state = .importing(device: device, done: 0, total: downloadQueue.count)
        downloadNext()
    }

    func dismissResult() {
        if camera != nil { recomputePending() } else { state = .idle }
    }

    // MARK: - Internals

    private func descriptor(for file: ICCameraFile) -> CameraItemDescriptor {
        CameraItemDescriptor(name: file.name ?? "unknown",
                             creationDate: file.creationDate,
                             fileSize: Int(file.fileSize))
    }

    private func recomputePending() {
        guard let camera else { return }
        let files = (camera.mediaFiles ?? camera.contents ?? [])
            .compactMap { $0 as? ICCameraFile }
        let recorded = (try? service.importedIdentifiers(device: camera.name ?? "device")) ?? []
        let descriptors = files.map { self.descriptor(for: $0) }
        let pendingDescriptors = PhoneImportPlanner.pending(onDevice: descriptors, alreadyImported: recorded)
        let pendingIds = Set(pendingDescriptors.map(\.identifier))
        pendingFiles = files.filter { pendingIds.contains(self.descriptor(for: $0).identifier) }
        state = .ready(device: camera.name ?? "iPhone", pending: pendingFiles.count)
    }

    private func downloadNext() {
        guard case .importing(let device, _, let total) = state else { return }
        guard let file = downloadQueue.first else {
            finishImport()
            return
        }
        downloadQueue.removeFirst()
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: staging,
        ]
        camera?.requestDownloadFile(
            file, options: options, downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil)
        _ = (device, total)   // silences unused warnings if the compiler complains
    }

    @objc private func didDownloadFile(_ file: ICCameraFile, error: Error?,
                                       options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            if let error {
                self.failedNames.append("\(file.name ?? "?") — \(error.localizedDescription)")
            } else {
                let device = self.camera?.name ?? "device"
                try? self.service.recordImport(device: device,
                                               identifier: self.descriptor(for: file).identifier)
                self.doneCount += 1
            }
            if case .importing(let device, _, let total) = self.state {
                self.state = .importing(device: device, done: self.doneCount, total: total)
            }
            self.downloadNext()
        }
    }

    private func finishImport() {
        let staging = self.staging
        let library = service.root
        let failed = failedNames
        Task { @MainActor in
            do {
                let report = try await IngestService(staging: staging, library: library).ingest()
                self.state = .finished(report: report, failed: failed)
                self.onLibraryChanged()
            } catch {
                self.state = .error(message: "Ingest failed: \(error)")
            }
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension PhoneImportController: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.camera == nil, let cam = device as? ICCameraDevice else { return }
            self.camera = cam
            cam.delegate = self
            self.state = .connecting(device: device.name ?? "iPhone")
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            if device === self.camera {
                self.camera = nil
                self.pendingFiles = []
                self.state = .idle
            }
        }
    }
}

// MARK: - ICCameraDeviceDelegate (required stubs + the two that matter)

extension PhoneImportController: ICCameraDeviceDelegate {
    nonisolated func cameraDeviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.recomputePending() }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            Task { @MainActor in
                self.state = .error(message: "Could not open session: \(error.localizedDescription). Unlock the phone, tap Trust, and reconnect.")
            }
        }
    }

    // Required protocol stubs — no behavior needed for import-all-new.
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - ICCameraDeviceDownloadDelegate

extension PhoneImportController: ICCameraDeviceDownloadDelegate {}
```

Also add the two passthroughs to `Sources/PhlookCore/IndexingService.swift`:

```swift
    public func recordImport(device: String, identifier: String) throws {
        try index.recordImport(device: device, identifier: identifier)
    }

    public func importedIdentifiers(device: String) throws -> Set<String> {
        try index.importedIdentifiers(device: device)
    }
```

- [ ] **Step 2: Build + regression**

Run: `swift build 2>&1 | tail -3` — `Build complete!`. Iterate on ICC signature mismatches here (this is the expected hard part; record every deviation). Then `make test` — all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/Phlook/PhoneImportController.swift Sources/PhlookCore/IndexingService.swift
git commit -m "feat: PhoneImportController — ICC device session, new-item diff, serial download into staging

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Import bar UI + report sheet + wiring

**Files:**
- Create: `Sources/Phlook/ImportBar.swift`
- Modify: `Sources/Phlook/MicroGridView.swift` (mount the bar beside the filter)
- Modify: `Sources/Phlook/ContentView.swift` (own the controller, sheet on finished/error)

**Interfaces:**
- Consumes: `PhoneImportController.ImportState` cases exactly as defined in Task 3; `IngestReport.summaryText` (PhlookCore).

- [ ] **Step 1: Create ImportBar.swift**

```swift
import SwiftUI
import PhlookCore

struct ImportBar: View {
    @ObservedObject var importer: PhoneImportController

    var body: some View {
        switch importer.state {
        case .idle:
            EmptyView()
        case .connecting(let device):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(device) — unlock it and tap Trust…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let device, let pending):
            if pending > 0 {
                Button {
                    importer.importAllNew()
                } label: {
                    Label("Import \(pending) new from \(device)", systemImage: "iphone.and.arrow.forward")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Label("\(device): up to date", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .importing(_, let done, let total):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text("Importing \(done) of \(total)…").font(.caption)
            }
        case .finished, .error:
            EmptyView()   // presented as a sheet by ContentView
        }
    }
}

struct ImportResultSheet: View {
    let state: PhoneImportController.ImportState
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .finished(let report, let failed):
                Text("Import complete").font(.headline)
                Text(report.summaryText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if !failed.isEmpty {
                    Text("Failed downloads (still on the phone):").font(.caption).foregroundStyle(.secondary)
                    ForEach(failed, id: \.self) { Text($0).font(.caption2) }
                }
            case .error(let message):
                Text("Import problem").font(.headline)
                Text(message)
            default:
                EmptyView()
            }
            HStack { Spacer(); Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
```

- [ ] **Step 2: Mount in MicroGridView + ContentView**

In `Sources/Phlook/MicroGridView.swift`: give `MicroGridView` a new property `@ObservedObject var importer: PhoneImportController`, and change `filterBar` to an HStack containing the existing Picker plus `ImportBar(importer: importer)`:

```swift
    private var filterBar: some View {
        HStack(spacing: 16) {
            Picker("Filter", selection: $vm.filter) {
                ForEach(MediaFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            ImportBar(importer: importer)
        }
        .padding(.vertical, 8)
    }
```

In `Sources/Phlook/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    @StateObject private var importer: PhoneImportController

    init() {
        let vm = LibraryViewModel()
        _vm = StateObject(wrappedValue: vm)
        _importer = StateObject(wrappedValue: PhoneImportController(service: vm.service))
    }

    private var showResult: Bool {
        if case .finished = importer.state { return true }
        if case .error = importer.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            MicroGridView(vm: vm, importer: importer)
            if vm.viewerIndex != nil {
                ViewerView(vm: vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.viewerIndex != nil)
        .sheet(item: $vm.detailsItem) { item in
            DetailsModal(item: item) { vm.detailsItem = nil }
        }
        .sheet(isPresented: .constant(showResult)) {
            ImportResultSheet(state: importer.state) { importer.dismissResult() }
        }
        .onAppear {
            importer.onLibraryChanged = { vm.load() }
            vm.load()
            importer.start()
        }
    }
}
```

Note the `.sheet(isPresented: .constant(showResult))` shape is intentional (state-driven, dismissed only via Done → `dismissResult()`); if SwiftUI fights the constant binding on this SDK, use a `Binding(get: { showResult }, set: { if !$0 { importer.dismissResult() } })` instead.

Also check `IndexingService.root` is public (Task 3 uses `service.root` for the library path — it already is, `public let root: URL`).

- [ ] **Step 3: Build + regression + launch check**

`swift build 2>&1 | tail -3` → `Build complete!`; `make test` → all green; `make app && open ./Phlook.app`, ~15s, `pgrep Phlook` alive (no device connected: the bar simply doesn't render), quit via osascript.

- [ ] **Step 4: Commit**

```bash
git add Sources/Phlook/ImportBar.swift Sources/Phlook/MicroGridView.swift Sources/Phlook/ContentView.swift
git commit -m "feat: import bar + result sheet — one-click Import N new from iPhone

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Human acceptance smoke (after all tasks — REQUIRED, hardware)

1. Launch Phlook, plug in the iPhone (unlock + Trust if prompted).
2. Bar shows "Connecting…" then `Import N new from <name>` — N should be plausibly "everything on the phone" on first run (the imports table starts empty; prior manual imports are not in it).
3. Click Import → progress → report sheet; verify moved count, grid refresh shows the new media.
4. Unplug, replug → shows "up to date" (0 pending) — THE core promise.
5. Delete the imported items on the phone; replug → still 0 pending, nothing re-offered.
