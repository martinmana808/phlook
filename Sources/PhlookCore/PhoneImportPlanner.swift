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
