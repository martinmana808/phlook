import Foundation
import CryptoKit

/// Streaming SHA256 of a whole file, read in 4 MB chunks so large videos
/// never load fully into memory. Lowercase hex; nil if the file is unreadable.
public enum FileHasher {
    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
