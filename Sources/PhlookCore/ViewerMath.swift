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

    /// Zoom range for the viewer's zoom slider/pinch gesture.
    public static let minZoom: CGFloat = 1
    public static let maxZoom: CGFloat = 4

    /// Threshold (as a fraction of `maxZoom` range) past which the viewer
    /// re-decodes the current image at a higher pixel cap for sharpness.
    public static let sharpenZoomThreshold: CGFloat = 1.5

    public static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        max(minZoom, min(maxZoom, zoom))
    }

    /// Size an image (in its native aspect ratio) so it fits entirely inside
    /// `container`, preserving aspect ratio — the same math `scaledToFit`
    /// performs, exposed as a pure helper so `zoom * fitSize` can be computed
    /// without a live view hierarchy.
    public static func fitSize(image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
