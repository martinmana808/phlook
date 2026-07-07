import Foundation
import ImageCaptureCore
import PhlookCore

@MainActor
final class PhoneImportController: NSObject, ObservableObject {
    enum ImportState: Equatable {
        case idle
        case connecting(device: String)
        case ready(device: String, pending: Int, onDevice: Int, imported: Int)
        case unreadable(device: String)
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
    private var inFlightFile: ICCameraFile?
    private var doneCount = 0
    private var failedNames: [String] = []
    private var downloadSeq = 0
    /// Set once the complete-content-catalog callback has fired for the current
    /// session. Guards against a session-open error being papered over by a
    /// stale "ready"/"up to date" state — and against recomputePending firing
    /// before the catalog exists.
    private var catalogReceived = false
    /// Bumped at the start of every importAllNew() run, and again by the
    /// watchdog's stall branch. A download callback that reports back with a
    /// stale generation is a straggler from an invalidated run and must not
    /// mutate the new run's state.
    private var runGeneration = 0
    private var inFlightGeneration = 0
    /// Last time we observed forward progress (a completed download or a
    /// download-progress tick). The inactivity watchdog fires off of this,
    /// not a fixed timer, so a slow-but-alive transfer isn't killed.
    private var lastActivity = Date()
    /// Debounced recompute task for live catalog changes (didAdd/didRemove
    /// item delegate callbacks). Cancelled and rescheduled on every event so a
    /// burst of item changes settles into a single recompute.
    private var recomputeDebounce: Task<Void, Never>?
    /// Diagnostic log file for hardware-test ground truth. Best-effort only —
    /// never allowed to affect import behavior.
    private let logURL: URL

    init(service: IndexingService,
         staging: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent("Pictures/PHLOOK_staging")) {
        self.service = service
        self.staging = staging
        self.logURL = staging.appendingPathComponent(".phlook-import.log")
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
        guard case .ready(let device, let pending, _, _) = state, pending > 0, camera != nil else { return }
        runGeneration += 1
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        downloadQueue = pendingFiles
        doneCount = 0
        failedNames = []
        lastActivity = Date()
        state = .importing(device: device, done: 0, total: downloadQueue.count)
        downloadNext()
    }

    func dismissResult() {
        guard case .error = state, let camera, !catalogReceived else {
            if camera != nil { recomputePending() } else { state = .idle }
            return
        }
        // Session-open (or catalog-never-arrived) error: retry by re-requesting
        // the session rather than silently falling back to a stale "ready".
        state = .connecting(device: camera.name ?? "iPhone")
        camera.requestOpenSession()
    }

    /// Cancel an in-progress import. Whatever already landed in staging stays
    /// recorded/ingested — only the not-yet-downloaded remainder is dropped,
    /// labeled distinctly from a device-disconnect remainder.
    func cancelImport() {
        guard case .importing = state else { return }
        log("cancel requested")
        runGeneration += 1   // invalidate any straggler download callback
        var remainder = downloadQueue.map { $0.name ?? "?" }
        if let name = inFlightFile?.name { remainder.insert(name, at: 0) }
        failedNames.append(contentsOf: remainder.map { "\($0) — cancelled" })
        downloadQueue = []
        inFlightFile = nil
        finishImport()
    }

    // MARK: - Internals

    private func descriptor(for file: ICCameraFile) -> CameraItemDescriptor {
        CameraItemDescriptor(name: file.name ?? "unknown",
                             creationDate: file.creationDate,
                             fileSize: Int(file.fileSize))
    }

    /// Best-effort diagnostic append. Never throws into the caller — a
    /// logging failure must not affect import behavior.
    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            if fm.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL)
            }
        } catch {
            // Diagnostics are best-effort; swallow.
        }
    }

    /// Schedules a debounced recompute in response to a live catalog change
    /// (didAdd/didRemove item delegate callback). Only meaningful while we're
    /// not mid-import/finished/error — those states own their own snapshot.
    private func scheduleDebouncedRecompute() {
        switch state {
        case .ready, .connecting, .unreadable:
            break
        default:
            return
        }
        recomputeDebounce?.cancel()
        recomputeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            switch self.state {
            case .ready, .connecting, .unreadable:
                self.recomputePending()
            default:
                break
            }
        }
    }

    private func recomputePending() {
        guard let camera else { return }
        guard catalogReceived else { return }   // no catalog yet: don't claim "ready"
        let files = (camera.mediaFiles ?? camera.contents ?? [])
            .compactMap { $0 as? ICCameraFile }
        guard !files.isEmpty else {
            // An empty catalog is far more likely to be ICC handing us a
            // stale/incomplete snapshot than a phone with zero photos. Honest
            // "can't read" beats a false "up to date".
            log("recompute: empty catalog — unreadable")
            pendingFiles = []
            state = .unreadable(device: camera.name ?? "iPhone")
            return
        }
        let recorded = (try? service.importedIdentifiers(device: camera.name ?? "device")) ?? []
        let descriptors = files.map { self.descriptor(for: $0) }
        let pendingDescriptors = PhoneImportPlanner.pending(onDevice: descriptors, alreadyImported: recorded)
        let pendingIds = Set(pendingDescriptors.map(\.identifier))
        pendingFiles = files.filter { pendingIds.contains(self.descriptor(for: $0).identifier) }
        let onDevice = files.count
        let pending = pendingFiles.count
        log("recompute: onDevice=\(onDevice) recorded=\(recorded.count) pending=\(pending)")
        state = .ready(device: camera.name ?? "iPhone", pending: pending,
                       onDevice: onDevice, imported: onDevice - pending)
    }

    private func downloadNext() {
        guard case .importing(let device, _, let total) = state else { return }
        guard let file = downloadQueue.first else {
            inFlightFile = nil
            finishImport()
            return
        }
        downloadQueue.removeFirst()
        inFlightFile = file
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: staging,
        ]
        downloadSeq += 1
        let seq = downloadSeq
        inFlightGeneration = runGeneration
        lastActivity = Date()
        let stalledName = file.name ?? "?"
        log("download start: \(stalledName)")
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // poll every 30s
                guard let self, self.downloadSeq == seq,
                      case .importing = self.state else { return }
                if Date().timeIntervalSince(self.lastActivity) > 180 {
                    self.runGeneration += 1   // invalidate any in-flight callback for this file
                    self.inFlightFile = nil
                    self.log("watchdog fired: stalled on \(stalledName)")
                    self.state = .error(message: "Download stalled on '\(stalledName)'. Reconnect the iPhone and try again — already-imported items will be skipped.")
                    return
                }
            }
        }
        camera?.requestDownloadFile(
            file, options: options, downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil)
        _ = (device, total)   // silences unused warnings if the compiler complains
    }

    @objc nonisolated func didDownloadFile(_ file: ICCameraFile, error: Error?,
                                       options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            guard file === self.inFlightFile else {
                // Straggler from an abandoned request: the download itself is
                // real, so remember it — but never touch the live run's state.
                if error == nil {
                    let device = self.camera?.name ?? "device"
                    try? self.service.recordImport(device: device,
                                                   identifier: self.descriptor(for: file).identifier)
                }
                return
            }
            self.inFlightFile = nil
            let generation = self.inFlightGeneration
            self.downloadSeq += 1
            self.lastActivity = Date()
            if let error {
                self.log("download failure: \(file.name ?? "?") — \(error.localizedDescription)")
                self.failedNames.append("\(file.name ?? "?") — \(error.localizedDescription)")
            } else {
                // A completed download is real regardless of whether this run
                // has since been invalidated — record it so retry semantics
                // (never re-download an already-fetched item) stay correct.
                let device = self.camera?.name ?? "device"
                try? self.service.recordImport(device: device,
                                               identifier: self.descriptor(for: file).identifier)
                self.doneCount += 1
                self.log("download success: \(file.name ?? "?")")
            }
            guard generation == self.runGeneration, case .importing(let device, _, let total) = self.state else {
                return   // stale straggler from an invalidated run: recorded above, nothing else to do
            }
            self.state = .importing(device: device, done: self.doneCount + self.failedNames.count, total: total)
            self.downloadNext()
        }
    }

    /// Device unplugged. If we were mid-import, finish with whatever already
    /// arrived rather than vanishing the run — the user should still get a
    /// result sheet (and staging still needs ingesting).
    private func handleDeviceRemoved() {
        log("device removed: \(camera?.name ?? "?")")
        recomputeDebounce?.cancel()
        recomputeDebounce = nil
        if case .importing = state {
            runGeneration += 1   // invalidate any straggler download callback
            var remainder = downloadQueue.map { $0.name ?? "?" }
            if let name = inFlightFile?.name { remainder.insert(name, at: 0) }
            failedNames.append(contentsOf: remainder.map { "\($0) — device disconnected before download" })
            camera = nil
            downloadQueue = []
            inFlightFile = nil
            catalogReceived = false
            finishImport()
            return
        }
        camera = nil
        pendingFiles = []
        catalogReceived = false
        state = .idle
    }

    private func finishImport() {
        let staging = self.staging
        let library = service.root
        let failed = failedNames
        Task { @MainActor in
            do {
                let report = try await IngestService(staging: staging, library: library).ingest()
                self.log("finalize: moved=\(report.moved.count) skippedDuplicates=\(report.skippedDuplicates.count) unsupported=\(report.unsupported.count) failed=\(failed.count)")
                self.state = .finished(report: report, failed: failed)
                self.onLibraryChanged()
            } catch {
                self.log("finalize: ingest failed — \(error)")
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
            self.log("device added: \(device.name ?? "?")")
            self.camera = cam
            self.catalogReceived = false
            cam.delegate = self
            self.state = .connecting(device: device.name ?? "iPhone")
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.handleDeviceRemoved()
        }
    }
}

// MARK: - ICCameraDeviceDelegate (required stubs + the two that matter)

extension PhoneImportController: ICCameraDeviceDelegate {
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            self.catalogReceived = true
            let count = ((device.mediaFiles ?? device.contents ?? []) as [ICCameraItem]).count
            self.log("catalog ready: \(count) media items")
            self.recomputePending()
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in
            self.log("session opened: \(device.name ?? "?") error=\(error?.localizedDescription ?? "none")")
            // A freshly (re)opened session hasn't produced a catalog yet — never
            // trust a catalog snapshot from a prior session.
            self.catalogReceived = false
        }
        if let error {
            Task { @MainActor in
                self.state = .error(message: "Could not open session: \(error.localizedDescription). Unlock the phone, tap Trust, and reconnect.")
            }
        }
    }

    // Required protocol stubs — no behavior needed for import-all-new.
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            self.log("didAdd items: \(items.count)")
            self.scheduleDebouncedRecompute()
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor in
            self.log("didRemove items: \(items.count)")
            self.scheduleDebouncedRecompute()
        }
    }
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

extension PhoneImportController: ICCameraDeviceDownloadDelegate {
    /// Bytes are still moving: the transfer is alive even though no file has
    /// completed yet. Feeds the inactivity watchdog so a large, slow-but-alive
    /// download doesn't get killed as "stalled".
    nonisolated func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: off_t, maxBytes: off_t) {
        Task { @MainActor in
            self.lastActivity = Date()
        }
    }
}
