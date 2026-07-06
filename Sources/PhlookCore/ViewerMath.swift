import Foundation

public enum ViewerMath {
    public static func clamp(_ i: Int, count: Int) -> Int {
        max(0, min(count - 1, i))
    }

    public static func positionString(index: Int, count: Int) -> String {
        "\(index + 1) of \(count)"
    }

    public static func resolveIndex(path: String, in items: [MediaItem]) -> Int? {
        items.firstIndex { $0.path == path }
    }
}
