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
    private var downloadSeq = 0

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
        downloadSeq += 1
        let seq = downloadSeq
        let stalledName = file.name ?? "?"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)   // 3 min per file
            guard let self, self.downloadSeq == seq,
                  case .importing = self.state else { return }
            self.state = .error(message: "Download stalled on '\(stalledName)'. Reconnect the iPhone and try again — already-imported items will be skipped.")
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
            self.downloadSeq += 1
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
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
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
