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

    // MARK: - Internals

    private func descriptor(for file: ICCameraFile) -> CameraItemDescriptor {
        CameraItemDescriptor(name: file.name ?? "unknown",
                             creationDate: file.creationDate,
                             fileSize: Int(file.fileSize))
    }

    private func recomputePending() {
        guard let camera else { return }
        guard catalogReceived else { return }   // no catalog yet: don't claim "ready"
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
        inFlightFile = file
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: staging,
        ]
        downloadSeq += 1
        let seq = downloadSeq
        inFlightGeneration = runGeneration
        lastActivity = Date()
        let stalledName = file.name ?? "?"
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // poll every 30s
                guard let self, self.downloadSeq == seq,
                      case .importing = self.state else { return }
                if Date().timeIntervalSince(self.lastActivity) > 180 {
                    self.runGeneration += 1   // invalidate any in-flight callback for this file
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
            let generation = self.inFlightGeneration
            self.downloadSeq += 1
            self.lastActivity = Date()
            if self.inFlightFile === file { self.inFlightFile = nil }
            if let error {
                self.failedNames.append("\(file.name ?? "?") — \(error.localizedDescription)")
            } else {
                // A completed download is real regardless of whether this run
                // has since been invalidated — record it so retry semantics
                // (never re-download an already-fetched item) stay correct.
                let device = self.camera?.name ?? "device"
                try? self.service.recordImport(device: device,
                                               identifier: self.descriptor(for: file).identifier)
                self.doneCount += 1
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
            self.recomputePending()
        }
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
